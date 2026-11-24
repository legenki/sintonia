import AVFoundation
import Testing
import PresetKit
import SynthCore
@testable import WaveForge

@Suite("AudioRuntime Policy and Exporter", .serialized)
struct AudioRuntimeTests {
    @Test func audioRoutePolicyAutoPausesBinauralOnHeadphoneDisconnect() {
        #expect(AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: true, presetHasActiveBinaural: true))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: true, presetHasActiveBinaural: false))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: false, presetHasActiveBinaural: true))
    }

    @Test func audioRoutePolicyClassifiesAVAudioSessionPorts() {
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.headphones]) == .headphones)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.bluetoothA2DP]) == .headphones)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.bluetoothHFP]) == .headphones)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.bluetoothLE]) == .headphones)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.usbAudio]) == .headphones)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.builtInSpeaker]) == .speaker)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: [.airPlay]) == .other)
        #expect(AudioRoutePolicy.classifyRoute(portTypes: []) == .other)
    }

    @Test func sessionExporterProducesValidWavAndM4AWithExactDuration() async throws {
        var preset = PresetCatalog.builtInPresets[0]
        preset.durationSec = 2.0

        let wavURL = try await SessionExporter.export(preset: preset, format: .wav, sampleRate: 48_000) { _ in }
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let wavFile = try AVAudioFile(forReading: wavURL)
        #expect(wavFile.processingFormat.sampleRate == 48_000)
        #expect(wavFile.processingFormat.channelCount == 2)
        #expect(abs((Double(wavFile.length) / 48_000.0) - 2.0) < 0.05)

        let m4aURL = try await SessionExporter.export(preset: preset, format: .m4a, sampleRate: 48_000) { _ in }
        defer { try? FileManager.default.removeItem(at: m4aURL) }
        let m4aFile = try AVAudioFile(forReading: m4aURL)
        #expect(m4aFile.processingFormat.channelCount == 2)
        #expect(abs((Double(m4aFile.length) / m4aFile.processingFormat.sampleRate) - 2.0) < 0.15)
    }

    @Test func sessionExporterCleansUpTempFileOnCancellation() async throws {
        var preset = PresetCatalog.builtInPresets[0]
        preset.durationSec = 1800.0
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])

        let task = Task {
            try await SessionExporter.export(preset: preset, format: .wav, sampleRate: 48_000) { _ in }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        let leftoverWaveForgeFiles = after.subtracting(before).filter { $0.contains("WaveForge-") }
        #expect(leftoverWaveForgeFiles.isEmpty)
    }

    @MainActor
    @Test func audioEngineControllerManagesPresetSeekSkipOverridesAndBanner() {
        let first = PresetCatalog.builtInPresets[0]
        let second = PresetCatalog.builtInPresets[7]
        let controller = AudioEngineController(preset: first)

        #expect(!controller.isPlaying)
        #expect(controller.currentPreset.id == first.id)
        #expect(controller.duration == first.durationSec)
        #expect(controller.currentTime == 0.0)
        #expect(!controller.showHeadphoneBanner)

        controller.seek(to: 125.0)
        #expect(controller.currentTime == 125.0)

        controller.skip(by: 30.0)
        #expect(controller.currentTime == 155.0)

        controller.skip(by: -200.0)
        #expect(controller.currentTime == 0.0)

        let overrides = LiveOverrides(masterGain: 0.7, tonesGain: 1.2, noiseGain: 0.8, noiseSmoothnessOffset: -0.25)
        controller.updateOverrides(overrides)
        #expect(controller.liveOverrides == overrides)

        var edited = first
        edited.durationSec = 90.0
        controller.seek(to: 120.0)
        controller.applyEditedPreset(edited)
        #expect(controller.duration == 90.0)
        #expect(controller.currentTime == 90.0)

        controller.load(second)
        #expect(controller.currentPreset.id == second.id)
        #expect(controller.duration == second.durationSec)
        #expect(controller.currentTime == 0.0)
        #expect(!controller.isPlaying)
        #expect(abs(controller.dominantBeatHz - 10.0) < 0.01)
        #expect(controller.dominantBand == .alpha)
        controller.dismissHeadphoneBanner()
        #expect(!controller.showHeadphoneBanner)
    }

    @MainActor
    @Test func duplicatedBuiltInPresetRetainsLocalizedSummaryLookup() {
        var duplicated = PresetCatalog.builtInPresets[0]
        duplicated.id = UUID()
        duplicated.isBuiltIn = false
        duplicated.category = .custom
        duplicated.name = "\(duplicated.name) (Copy)"

        let summary = LibraryView.localizedSummary(for: duplicated)
        #expect(!summary.isEmpty)
        #expect(summary == String(localized: String.LocalizationValue(PresetCatalog.builtInPresets[0].summary)))
    }

    @Test func importAlertContentSurfacesStructuredBWGWarnings() throws {
        let bwgText = """
        BrainWave Generator File
        Name=Structured Warnings Test
        Voice1.Carrier=0:200
        Voice1.Beat=0:10
        """
        let result = try BWGImporter.importPreset(from: Data(bwgText.utf8), fallbackName: "Fallback")
        let outcome = PresetImportOutcome(preset: result.preset, report: result.report)
        let alert = ImportAlertContent.fromOutcome(outcome)
        #expect(alert != nil)
        // Integer interpolation is grouped per region (e.g. "1.800" for en_IT), so compare against the
        // same localized string instead of a hard-coded digit sequence.
        let expectedNotice = String(localized: "Missing duration; defaulted to \(1800)s.")
        #expect(alert?.message.contains(expectedNotice) == true)
    }
}
