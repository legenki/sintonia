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
        controller.dismissHeadphoneBanner()
        #expect(!controller.showHeadphoneBanner)
    }
}
