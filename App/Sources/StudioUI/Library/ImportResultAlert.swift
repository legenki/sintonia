import CoreTransferable
import Foundation
import PresetKit
import SwiftUI
import SynthCore
import UniformTypeIdentifiers
import SintoniaExport

// MARK: - Registered Document Content Types

public extension UTType {
    /// Exported Sintonia JSON preset document (`com.legenki.sintonia.preset`, `.sintonia`).
    static let sintoniaPreset = UTType(exportedAs: "com.legenki.sintonia.preset", conformingTo: .json)

    /// Imported classic BrainWave Generator preset (`com.noromaa.bwg`, `.bwg`).
    static let brainWaveGenerator = UTType(importedAs: "com.noromaa.bwg", conformingTo: .data)
    /// Presets saved before the WaveForge → Sintonia rename (`.waveforge`, same JSON schema).
    static let legacyWaveForgePreset = UTType(importedAs: "com.waveforge.preset", conformingTo: .json)
}

// MARK: - Transferable `.sintonia` Document for ShareLink Export

/// `Transferable` wrapper that lazily serializes a `Preset` into a temporary `.sintonia` file
/// for system `ShareLink` export.
public struct SintoniaPresetDocument: Transferable, Sendable {
    public let preset: Preset

    public init(preset: Preset) {
        self.preset = preset
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .sintoniaPreset) { item in
            let data = try PresetCodec.encode(item.preset)
            let fileName = "\(Self.sanitizedFileName(for: item.preset.name)).sintonia"
            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SintoniaPresetExports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let destinationURL = exportDirectory.appendingPathComponent(fileName, isDirectory: false)
            try data.write(to: destinationURL, options: [.atomic])
            return SentTransferredFile(destinationURL)
        }
    }

    public static func sanitizedFileName(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()."))
        let cleaned = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return collapsed.isEmpty ? "Sintonia-Preset" : String(collapsed.prefix(80))
    }
}

// MARK: - Typed Import Errors & Pipeline

/// Typed errors surfaced cleanly in `ImportResultAlert` when importing `.bwg` or `.sintonia` files.
public enum PresetImportError: Error, LocalizedError, Equatable, Sendable {
    case unreadableFile
    case fileTooLarge
    case unsupportedFileType
    case bwg(BWGImportError)
    case unsupportedSchemaVersion(Int)
    case corruptedSintoniaFile
    case invalidPreset
    case storageFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return String(localized: "Failed to read preset file.")
        case .fileTooLarge:
            return String(localized: "Preset file is too large.")
        case .unsupportedFileType:
            return String(localized: "Unsupported file format. Please choose a .bwg or .sintonia file.")
        case .bwg(let bwgError):
            switch bwgError {
            case .emptyFile:
                return String(localized: "File is empty.")
            case .fileTooLarge:
                return String(localized: "Preset file is too large.")
            case .invalidHeader:
                return String(localized: "Unsupported or invalid BWG header.")
            case .corruptedStructure:
                return String(localized: "Preset file structure is corrupted.")
            case .noValidVoices:
                return String(localized: "No valid synthesis voices found in file.")
            }
        case .unsupportedSchemaVersion(let version):
            return String(localized: "Unsupported .sintonia schema version (\(version)).")
        case .corruptedSintoniaFile:
            return String(localized: "Preset file structure is corrupted.")
        case .invalidPreset:
            return String(localized: "Invalid preset configuration")
        case .storageFailure(let detail):
            return detail.isEmpty ? String(localized: "Failed to read preset file.") : detail
        }
    }
}

/// Result returned when a `.bwg` or `.sintonia` file is successfully imported and saved.
public struct PresetImportOutcome: Equatable, Sendable {
    public let preset: Preset
    public let report: ImportReport

    public init(preset: Preset, report: ImportReport = ImportReport()) {
        self.preset = preset
        self.report = report
    }

    /// True when legacy BWG features were skipped or sanitization warnings were recorded.
    public var hasNotices: Bool {
        !report.skippedFeatures.isEmpty || !report.warnings.isEmpty
    }
}

/// Security-scoped `.bwg` / `.sintonia` file importer shared between `LibraryView` and `SintoniaApp`.
public enum PresetImportCoordinator: Sendable {
    private static let bwgMagicHeader = Array("BrainWave Generator File".utf8)

    /// Reads a security-scoped `.bwg` or `.sintonia` file at `url`, validates and persists it
    /// into `presetStore`, and returns the saved custom `Preset` along with its `ImportReport`.
    public static func importFile(at url: URL, into presetStore: PresetStore) throws -> PresetImportOutcome {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if let isRegularFile = resourceValues?.isRegularFile, !isRegularFile {
            throw PresetImportError.unreadableFile
        }
        if let fileSize = resourceValues?.fileSize, fileSize > PresetLimits.maxImportFileBytes {
            throw PresetImportError.fileTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetImportError.unreadableFile
        }

        guard !data.isEmpty else {
            throw PresetImportError.bwg(.emptyFile)
        }
        guard data.count <= PresetLimits.maxImportFileBytes else {
            throw PresetImportError.fileTooLarge
        }

        let fallbackName = url.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "bwg" {
            return try importBWGData(data, fallbackName: fallbackName, into: presetStore)
        }
        if pathExtension == "sintonia" || pathExtension == "waveforge" {
            return try importSintoniaData(data, fallbackName: fallbackName, into: presetStore)
        }
        if looksLikeBWGHeader(data) {
            return try importBWGData(data, fallbackName: fallbackName, into: presetStore)
        }
        if pathExtension == "json" || looksLikeJSONObject(data) {
            return try importSintoniaData(data, fallbackName: fallbackName, into: presetStore)
        }

        throw PresetImportError.unsupportedFileType
    }

    /// Imports `urls` in order on a background task so file I/O and parsing never block the main actor.
    /// Each element reports either the saved outcome or the typed failure for the URL at the same index.
    public static func importFiles(
        at urls: [URL],
        into presetStore: PresetStore
    ) async -> [Result<PresetImportOutcome, PresetImportError>] {
        await Task.detached(priority: .userInitiated) {
            urls.map { url in
                do {
                    return .success(try importFile(at: url, into: presetStore))
                } catch let importError as PresetImportError {
                    return .failure(importError)
                } catch {
                    return .failure(.unreadableFile)
                }
            }
        }.value
    }

    private static func importBWGData(
        _ data: Data,
        fallbackName: String,
        into presetStore: PresetStore
    ) throws -> PresetImportOutcome {
        let bwgResult: BWGImportResult
        do {
            bwgResult = try BWGImporter.importPreset(from: data, fallbackName: fallbackName)
        } catch let error as BWGImportError {
            throw PresetImportError.bwg(error)
        } catch {
            throw PresetImportError.bwg(.corruptedStructure)
        }

        var preset = bwgResult.preset
        preset.isBuiltIn = false
        preset.recommendedOutput = AudioRoutePolicy.hasActiveBinauralVoices(in: preset) ? .headphones : .any

        do {
            try presetStore.saveCustom(preset)
        } catch let storeError as PresetStoreError {
            switch storeError {
            case .invalidPreset, .cannotModifyBuiltIn:
                throw PresetImportError.invalidPreset
            }
        } catch {
            throw PresetImportError.storageFailure(error.localizedDescription)
        }

        return PresetImportOutcome(preset: preset, report: bwgResult.report)
    }

    private static func importSintoniaData(
        _ data: Data,
        fallbackName: String,
        into presetStore: PresetStore
    ) throws -> PresetImportOutcome {
        var preset: Preset
        do {
            preset = try PresetCodec.decode(data)
        } catch let codecError as PresetCodecError {
            switch codecError {
            case .unsupportedSchemaVersion(let version):
                throw PresetImportError.unsupportedSchemaVersion(version)
            }
        } catch {
            throw PresetImportError.corruptedSintoniaFile
        }

        // Assign fresh identifiers so importing a shared/built-in preset never collides or mutates built-ins.
        preset.id = UUID()
        preset.isBuiltIn = false
        preset.voices = preset.voices.map { voice in
            var copy = voice
            copy.id = UUID()
            return copy
        }

        let trimmedName = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            let resolvedFallback = fallbackName.isEmpty ? String(localized: "Imported Preset") : fallbackName
            preset.name = String(resolvedFallback.prefix(PresetLimits.maxNameLength))
        } else {
            preset.name = String(trimmedName.prefix(PresetLimits.maxNameLength))
        }
        preset.summary = String(preset.summary.prefix(PresetLimits.maxSummaryLength))
        preset.recommendedOutput = AudioRoutePolicy.hasActiveBinauralVoices(in: preset) ? .headphones : .any

        guard PresetValidator.validate(preset).isEmpty else {
            throw PresetImportError.invalidPreset
        }

        do {
            try presetStore.saveCustom(preset)
        } catch let storeError as PresetStoreError {
            switch storeError {
            case .invalidPreset, .cannotModifyBuiltIn:
                throw PresetImportError.invalidPreset
            }
        } catch {
            throw PresetImportError.storageFailure(error.localizedDescription)
        }

        return PresetImportOutcome(preset: preset, report: ImportReport())
    }

    private static func looksLikeBWGHeader(_ data: Data) -> Bool {
        var offset = 0
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            offset = 3
        }
        guard data.count - offset >= bwgMagicHeader.count else { return false }
        for index in 0..<bwgMagicHeader.count {
            if data[offset + index] != bwgMagicHeader[index] {
                return false
            }
        }
        return true
    }

    private static func looksLikeJSONObject(_ data: Data) -> Bool {
        for byte in data {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }
            return byte == UInt8(ascii: "{")
        }
        return false
    }

    /// Formats any thrown import error into a user-facing localized explanation.
    public static func localizedMessage(for error: any Error) -> String {
        if let importError = error as? PresetImportError,
           let description = importError.errorDescription {
            return description
        }
        if let bwgError = error as? BWGImportError,
           let description = PresetImportError.bwg(bwgError).errorDescription {
            return description
        }
        if let codecError = error as? PresetCodecError {
            switch codecError {
            case .unsupportedSchemaVersion(let version):
                return PresetImportError.unsupportedSchemaVersion(version).errorDescription
                    ?? String(localized: "Preset file structure is corrupted.")
            }
        }
        if let storeError = error as? PresetStoreError {
            switch storeError {
            case .invalidPreset, .cannotModifyBuiltIn:
                return String(localized: "Invalid preset configuration")
            }
        }
        return String(localized: "Failed to read preset file.")
    }
}

// MARK: - ImportResultAlert Presentation Model & Modifier

/// Structured alert payload surfaced by `ImportResultAlert` for skipped legacy BWG features,
/// import warnings, or typed import failures.
public struct ImportAlertContent: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case importedWithReport(presetName: String, report: ImportReport)
        case failure(message: String)
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Returns an alert payload when `outcome` has skipped legacy features or warnings; otherwise `nil`.
    public static func fromOutcome(_ outcome: PresetImportOutcome) -> ImportAlertContent? {
        guard outcome.hasNotices else { return nil }
        return ImportAlertContent(
            kind: .importedWithReport(presetName: outcome.preset.name, report: outcome.report)
        )
    }

    /// Returns a failure alert payload formatted from `error`.
    public static func fromError(_ error: any Error) -> ImportAlertContent {
        ImportAlertContent(kind: .failure(message: PresetImportCoordinator.localizedMessage(for: error)))
    }

    public var title: String {
        switch kind {
        case .importedWithReport:
            return String(localized: "Preset Imported")
        case .failure:
            return String(localized: "Import Failed")
        }
    }

    public var message: String {
        switch kind {
        case .failure(let message):
            return message

        case .importedWithReport(let presetName, let report):
            var sections: [String] = [presetName]

            if !report.skippedFeatures.isEmpty {
                var skippedLines: [String] = [String(localized: "Some legacy BWG features were skipped:")]
                for feature in report.skippedFeatures {
                    skippedLines.append("• \(Self.localizedDescription(for: feature))")
                }
                sections.append(skippedLines.joined(separator: "\n"))
            }

            let additionalWarnings = Self.filteredAdditionalWarnings(from: report)
            if !additionalWarnings.isEmpty {
                var warningLines: [String] = [String(localized: "Additional import notes:")]
                for warning in additionalWarnings.prefix(4) {
                    warningLines.append("• \(warning)")
                }
                if additionalWarnings.count > 4 {
                    warningLines.append("• +\(additionalWarnings.count - 4)")
                }
                sections.append(warningLines.joined(separator: "\n"))
            }

            return sections.joined(separator: "\n\n")
        }
    }

    private static func localizedDescription(for feature: SkippedLegacyFeature) -> String {
        switch feature {
        case .externalWavBackground:
            return String(localized: "External WAV background audio is not supported.")
        case .visualStimulation:
            return String(localized: "Visual / screen-flash stimulation is not supported.")
        }
    }

    private static func filteredAdditionalWarnings(from report: ImportReport) -> [String] {
        if !report.structuredWarnings.isEmpty {
            return report.structuredWarnings.map { Self.localizedWarning($0) }
        }

        guard !report.warnings.isEmpty else { return [] }
        let hasWavSkipped = report.skippedFeatures.contains(.externalWavBackground)
        let hasVisualSkipped = report.skippedFeatures.contains(.visualStimulation)

        return report.warnings.filter { warning in
            if hasWavSkipped && (warning.hasPrefix("Skipped external WAV") || warning.hasPrefix("Skipped legacy external WAV")) {
                return false
            }
            if hasVisualSkipped && warning.hasPrefix("Skipped legacy visual stimulation") {
                return false
            }
            return true
        }
    }

    private static func localizedWarning(_ warning: ImportWarning) -> String {
        switch warning {
        case let .unrecognizedMode(voiceNumber, rawValue):
            return String(localized: "Voice \(voiceNumber): unrecognized mode '\(rawValue)'; defaulted to binaural.")
        case let .unrecognizedWaveform(voiceNumber, rawValue):
            return String(localized: "Voice \(voiceNumber): unrecognized waveform '\(rawValue)'; defaulted to sine.")
        case let .skippedExcessVoice(voiceNumber, maxVoices):
            return String(localized: "Skipped Voice \(voiceNumber): Sintonia supports at most \(maxVoices) voices.")
        case let .skippedInvalidVoice(voiceNumber):
            return String(localized: "Skipped Voice \(voiceNumber): no finite carrier or beat parameters.")
        case let .ignoredInvalidTrackingRule(voiceNumber):
            return String(localized: "Ignored invalid tracking rule on Voice \(voiceNumber).")
        case let .removedCyclicTrackingRule(voiceName):
            return String(localized: "Removed cyclic tracking rule on '\(voiceName)'.")
        case let .droppedMalformedCurvePoints(target):
            let label = localizedTarget(target)
            return String(localized: "Dropped non-finite or malformed point(s) in \(label).")
        case let .clampedNegativeTimestamps(target):
            let label = localizedTarget(target)
            return String(localized: "Clamped negative timestamp(s) to 0s in \(label).")
        case let .clampedCurveValues(target, minVal, maxVal):
            let label = localizedTarget(target)
            let minStr = formatNumber(minVal)
            let maxStr = formatNumber(maxVal)
            return String(localized: "Clamped out-of-range value(s) in \(label) to \(minStr)...\(maxStr).")
        case let .deduplicatedTimestamps(target):
            let label = localizedTarget(target)
            return String(localized: "Deduplicated overlapping timestamp(s) in \(label).")
        case let .missingDurationDefaulted(defaultSeconds):
            return String(localized: "Missing duration; defaulted to \(defaultSeconds)s.")
        case let .replacedNonFiniteScalar(target, fallback):
            let label = localizedTarget(target)
            let fallbackStr = formatNumber(fallback)
            return String(localized: "Replaced non-finite \(label) with \(fallbackStr).")
        case let .clampedScalar(target, original, clamped):
            let label = localizedTarget(target)
            let origStr = formatNumber(original)
            let clampedStr = formatNumber(clamped)
            return String(localized: "Clamped \(label) from \(origStr) to \(clampedStr).")
        }
    }

    private static func localizedTarget(_ target: ImportWarningTarget) -> String {
        switch target {
        case .masterGain:
            return String(localized: "Master Gain")
        case .fadeIn:
            return String(localized: "Fade In")
        case .fadeOut:
            return String(localized: "Fade Out")
        case .duration:
            return String(localized: "Duration")
        case .noiseVolume:
            return String(localized: "Noise Volume")
        case .noiseSmoothness:
            return String(localized: "Noise Color")
        case .noisePulseDepth:
            return String(localized: "Pulse Depth")
        case .voiceCarrier(let n):
            return String(localized: "Voice \(n) Carrier")
        case .voiceBeat(let n):
            return String(localized: "Voice \(n) Beat")
        case .voiceVolume(let n):
            return String(localized: "Voice \(n) Volume")
        case .voicePan(let n):
            return String(localized: "Voice \(n) Pan")
        case .voiceIsochronicSoftness(let n):
            return String(localized: "Voice \(n) Softness")
        case .voiceIsochronicDutyCycle(let n):
            return String(localized: "Voice \(n) Duty Cycle")
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if value == floor(value) && abs(value) < 1_000_000_000.0 {
            return String(Int(value))
        }
        return String(value)
    }
}

/// Reusable alert modifier presenting `ImportAlertContent` for `.bwg` and `.sintonia` imports.
public struct ImportResultAlertModifier: ViewModifier {
    @Binding private var alertContent: ImportAlertContent?

    public init(alertContent: Binding<ImportAlertContent?>) {
        self._alertContent = alertContent
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { alertContent != nil },
            set: { newValue in
                if !newValue {
                    alertContent = nil
                }
            }
        )
    }

    public func body(content: Content) -> some View {
        content.alert(
            alertContent?.title ?? String(localized: "Import"),
            isPresented: isPresented,
            presenting: alertContent
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { payload in
            Text(verbatim: payload.message)
        }
    }
}

public extension View {
    /// Presents Sintonia's standardized `ImportResultAlert` when `alertContent` is non-nil.
    func importResultAlert(_ alertContent: Binding<ImportAlertContent?>) -> some View {
        modifier(ImportResultAlertModifier(alertContent: alertContent))
    }
}

/// Non-intrusive Liquid Glass confirmation toast shown briefly when a preset imports cleanly.
public struct ImportConfirmationToast: View {
    private let presetName: String
    private let onDismiss: () -> Void

    public init(presetName: String, onDismiss: @escaping () -> Void = {}) {
        self.presetName = presetName
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.ledGreen)

            VStack(alignment: .leading, spacing: 1) {
                Text("Preset Imported")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.primaryText)
                Text(verbatim: presetName)
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioGlassCapsule(tint: StudioTheme.ledGreen.opacity(0.18), interactive: true)
        .shadow(color: StudioTheme.hardwareShadow, radius: 12, x: 0, y: 6)
    }
}
