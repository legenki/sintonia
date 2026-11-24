import AVFoundation
import Foundation
import PresetKit
import SynthCore

/// Supported offline audio export container and codec formats.
public enum ExportFormat: String, CaseIterable, Sendable {
    case wav
    case m4a

    /// File extension corresponding to this export format.
    public var fileExtension: String { rawValue }
}

/// Typed errors thrown by `SessionExporter.export(preset:format:sampleRate:onProgress:)`.
public enum ExportError: Error, LocalizedError, Equatable, Sendable {
    case invalidDuration
    case invalidSampleRate
    case insufficientStorage
    case audioFormatUnavailable
    case bufferAllocationFailed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return String(localized: "Session duration must be greater than zero.")
        case .invalidSampleRate:
            return String(localized: "Export sample rate must be finite and positive.")
        case .insufficientStorage:
            return String(localized: "Not enough free storage space to export this audio file.")
        case .audioFormatUnavailable:
            return String(localized: "Unable to configure 48 kHz stereo PCM audio format.")
        case .bufferAllocationFailed:
            return String(localized: "Unable to allocate offline audio render buffer.")
        case .writeFailed(let detail):
            return detail.isEmpty ? String(localized: "Export Failed") : detail
        }
    }
}

/// Offline 48 kHz stereo renderer writing WAV (24-bit Linear PCM) and M4A (256 kbps AAC-LC) files.
public enum SessionExporter {
    private static let chunkFrameCount = 4096
    private static let progressThreshold = 0.005
    private static let aacBitRate = 256_000
    private static let storageSafetyMarginBytes: Int64 = 1_048_576

    /// Renders `preset` faster than real time using an isolated `SynthRenderer`, returning the temporary file URL.
    public static func export(
        preset: Preset,
        format: ExportFormat,
        sampleRate: Double = 48_000,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()

        guard sampleRate.isFinite, sampleRate > 0.0 else {
            throw ExportError.invalidSampleRate
        }
        let snapshot = SnapshotCompiler.compile(preset)
        guard snapshot.durationSec.isFinite, snapshot.durationSec > 0.0 else {
            throw ExportError.invalidDuration
        }

        let totalFramesDouble = (snapshot.durationSec * sampleRate).rounded()
        guard totalFramesDouble.isFinite,
              totalFramesDouble >= 1.0,
              totalFramesDouble <= Double(Int64.max / 8) else {
            throw ExportError.invalidDuration
        }
        let totalFrames = Int64(totalFramesDouble)

        let tempDirectory = FileManager.default.temporaryDirectory
        try validateAvailableStorage(
            for: format,
            durationSec: snapshot.durationSec,
            totalFrames: totalFrames,
            in: tempDirectory
        )

        let outputURL = makeTemporaryFileURL(presetName: preset.name, format: format, directory: tempDirectory)

        let renderTask = Task.detached(priority: .userInitiated) {
            try performExport(
                snapshot: snapshot,
                format: format,
                sampleRate: sampleRate,
                totalFrames: totalFrames,
                outputURL: outputURL,
                onProgress: onProgress
            )
            return outputURL
        }

        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    private static func performExport(
        snapshot: SynthSnapshot,
        format: ExportFormat,
        sampleRate: Double,
        totalFrames: Int64,
        outputURL: URL,
        onProgress: @Sendable (Double) -> Void
    ) throws {
        var audioFile: AVAudioFile?
        var succeeded = false
        defer {
            // Release AVAudioFile before deleting so its file descriptor closes cleanly.
            audioFile = nil
            if !succeeded {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        try Task.checkCancellation()

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw ExportError.audioFormatUnavailable
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(chunkFrameCount)
        ), let channelData = buffer.floatChannelData else {
            throw ExportError.bufferAllocationFailed
        }

        let fileSettings = audioSettings(for: format, sampleRate: sampleRate)
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw ExportError.writeFailed("")
        }

        let renderer = SynthRenderer(sampleRate: sampleRate, snapshot: snapshot)
        renderer.setPlaying(true)

        let leftOut = channelData[0]
        let rightOut = channelData[1]
        var renderedFrames: Int64 = 0
        var lastReportedProgress = 0.0
        onProgress(0.0)

        while renderedFrames < totalFrames {
            try Task.checkCancellation()

            let framesThisChunk = Int(min(Int64(chunkFrameCount), totalFrames - renderedFrames))
            buffer.frameLength = AVAudioFrameCount(framesThisChunk)
            renderer.render(intoLeft: leftOut, intoRight: rightOut, frameCount: framesThisChunk)

            do {
                try audioFile?.write(from: buffer)
            } catch {
                throw ExportError.writeFailed("")
            }

            renderedFrames += Int64(framesThisChunk)
            let progress = min(1.0, Double(renderedFrames) / Double(totalFrames))
            if progress - lastReportedProgress >= progressThreshold || renderedFrames == totalFrames {
                lastReportedProgress = progress
                onProgress(progress)
            }
        }

        // Explicitly drop the sole AVAudioFile reference before returning so M4A moov atoms and WAV headers flush.
        audioFile = nil
        try Task.checkCancellation()
        succeeded = true
    }

    private static func audioSettings(for format: ExportFormat, sampleRate: Double) -> [String: Any] {
        switch format {
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: aacBitRate,
            ]
        }
    }

    private static func validateAvailableStorage(
        for format: ExportFormat,
        durationSec: Double,
        totalFrames: Int64,
        in directory: URL
    ) throws {
        let estimatedAudioBytes: Int64
        switch format {
        case .wav:
            estimatedAudioBytes = totalFrames * 2 * 3
        case .m4a:
            let estimatedDouble = (durationSec * Double(aacBitRate / 8)).rounded(.up)
            guard estimatedDouble.isFinite,
                  estimatedDouble >= 0.0,
                  estimatedDouble <= Double(Int64.max - storageSafetyMarginBytes) else {
                throw ExportError.invalidDuration
            }
            estimatedAudioBytes = Int64(estimatedDouble)
        }
        let requiredBytes = estimatedAudioBytes + storageSafetyMarginBytes

        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let availableImportant = values?.volumeAvailableCapacityForImportantUsage, availableImportant > 0 {
            if availableImportant < requiredBytes {
                throw ExportError.insufficientStorage
            }
        } else if let available = values?.volumeAvailableCapacity, available >= 0 {
            if Int64(available) < requiredBytes {
                throw ExportError.insufficientStorage
            }
        }
    }

    private static func makeTemporaryFileURL(
        presetName: String,
        format: ExportFormat,
        directory: URL
    ) -> URL {
        let sanitized = presetName
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let slug = collapsed.isEmpty ? "Session" : String(collapsed.prefix(40))
        let unique = String(UUID().uuidString.prefix(8))
        return directory.appendingPathComponent("Sintonia-\(slug)-\(unique).\(format.fileExtension)")
    }

    /// Removes temporary Sintonia audio export files left in `directory` from previous sessions.
    public static func cleanupStaleTemporaryExports(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if name.hasPrefix("Sintonia-"), (ext == "wav" || ext == "m4a") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
