import AVFoundation
import Foundation
import PresetKit
import Synchronization
import SynthCore
import Testing
@testable import WaveForgeExport

@Suite("WaveForgeExport Policy and Exporter", .serialized)
struct WaveForgeExportTests {
    @Test func audioRoutePolicyAutoPausesBinauralOnHeadphoneDisconnect() {
        #expect(AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: true, presetHasActiveBinaural: true))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: true, presetHasActiveBinaural: false))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: false, presetHasActiveBinaural: true))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: false, presetHasActiveBinaural: false))
    }

    @Test func audioRoutePolicyClassifiesPortRawValues() {
        #expect(AudioRoutePolicy.classifyPortRawValues(["Headphones"]) == .headphones)
        #expect(AudioRoutePolicy.classifyPortRawValues(["BluetoothA2DPOutput"]) == .headphones)
        #expect(AudioRoutePolicy.classifyPortRawValues(["BluetoothHFP"]) == .headphones)
        #expect(AudioRoutePolicy.classifyPortRawValues(["BluetoothLE"]) == .headphones)
        #expect(AudioRoutePolicy.classifyPortRawValues(["USBAudio"]) == .headphones)
        #expect(AudioRoutePolicy.classifyPortRawValues(["Speaker"]) == .speaker)
        #expect(AudioRoutePolicy.classifyPortRawValues(["AirPlay"]) == .other)
        #expect(AudioRoutePolicy.classifyPortRawValues([]) == .other)
        #expect(AudioRoutePolicy.classifyPortRawValues(["Speaker", "Headphones"]) == .headphones)
    }

    @Test func audioRoutePolicyDetectsActiveBinauralVoicesRespectingMuteAndSolo() {
        var preset = PresetCatalog.builtInPresets[0]
        // Deep Focus voice 0 is binaural, voice 1 is isochronic.
        #expect(AudioRoutePolicy.hasActiveBinauralVoices(in: preset))

        preset.voices[0].isMuted = true
        #expect(!AudioRoutePolicy.hasActiveBinauralVoices(in: preset))

        preset.voices[0].isMuted = false
        preset.voices[1].isSolo = true
        #expect(!AudioRoutePolicy.hasActiveBinauralVoices(in: preset))

        preset.voices[0].isSolo = true
        #expect(AudioRoutePolicy.hasActiveBinauralVoices(in: preset))

        preset.voices[0].isEnabled = false
        #expect(!AudioRoutePolicy.hasActiveBinauralVoices(in: preset))
    }

    @Test func sessionExporterProducesValidWavAndM4AWithExactDurationAndAudio() async throws {
        var preset = PresetCatalog.builtInPresets[0]
        preset.durationSec = 2.0
        preset.fadeInSec = 0.05
        preset.fadeOutSec = 0.05

        let wavProgress = Mutex<[Double]>([])
        let wavURL = try await SessionExporter.export(preset: preset, format: .wav, sampleRate: 48_000) { progress in
            wavProgress.withLock { $0.append(progress) }
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(wavURL.lastPathComponent.hasPrefix("WaveForge-"))
        #expect(wavURL.pathExtension == "wav")

        let wavFile = try AVAudioFile(forReading: wavURL)
        #expect(wavFile.processingFormat.sampleRate == 48_000)
        #expect(wavFile.processingFormat.channelCount == 2)
        #expect(abs((Double(wavFile.length) / 48_000.0) - 2.0) < 0.05)
        #expect(try rmsAmplitude(of: wavFile) > 0.01)

        let wavReported = wavProgress.withLock { $0 }
        #expect(!wavReported.isEmpty)
        #expect(wavReported.last == 1.0)
        #expect(zip(wavReported, wavReported.dropFirst()).allSatisfy { $0 <= $1 })

        let m4aProgress = Mutex<[Double]>([])
        let m4aURL = try await SessionExporter.export(preset: preset, format: .m4a, sampleRate: 48_000) { progress in
            m4aProgress.withLock { $0.append(progress) }
        }
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        #expect(m4aURL.lastPathComponent.hasPrefix("WaveForge-"))
        #expect(m4aURL.pathExtension == "m4a")

        let m4aFile = try AVAudioFile(forReading: m4aURL)
        #expect(m4aFile.processingFormat.channelCount == 2)
        #expect(abs((Double(m4aFile.length) / m4aFile.processingFormat.sampleRate) - 2.0) < 0.15)
        #expect(try rmsAmplitude(of: m4aFile) > 0.01)

        let m4aReported = m4aProgress.withLock { $0 }
        #expect(m4aReported.last == 1.0)
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

    @Test func sessionExporterRejectsInvalidDurationWithoutLeavingTempFiles() async throws {
        var preset = PresetCatalog.builtInPresets[0]
        preset.durationSec = 0.0
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])

        do {
            _ = try await SessionExporter.export(preset: preset, format: .wav, sampleRate: 48_000) { _ in }
            Issue.record("Expected ExportError.invalidDuration")
        } catch ExportError.invalidDuration {
            // Expected
        }

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        let leftoverWaveForgeFiles = after.subtracting(before).filter { $0.contains("WaveForge-") }
        #expect(leftoverWaveForgeFiles.isEmpty)
    }

    private func rmsAmplitude(of file: AVAudioFile) throws -> Double {
        file.framePosition = 0
        let totalFrames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: totalFrames) else {
            return 0.0
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0.0
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sumSq = 0.0
        for ch in 0..<channels {
            let ptr = channelData[ch]
            for i in 0..<frames {
                let s = Double(ptr[i])
                sumSq += s * s
            }
        }
        return (sumSq / Double(frames * channels)).squareRoot()
    }
}
