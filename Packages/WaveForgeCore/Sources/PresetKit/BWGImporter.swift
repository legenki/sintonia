import Foundation
import SynthCore

/// Errors thrown by `BWGImporter.importPreset(from:fallbackName:)`.
public enum BWGImportError: Error, Equatable, Sendable {
    case emptyFile
    case invalidHeader
    case corruptedStructure
    case noValidVoices
}

/// Legacy BrainWave Generator features omitted from WaveForge v1 synthesis.
public enum SkippedLegacyFeature: String, Equatable, Sendable {
    case externalWavBackground
    case visualStimulation
}

/// Target field identified by an `ImportWarning`.
public enum ImportWarningTarget: Equatable, Sendable {
    case masterGain
    case fadeIn
    case fadeOut
    case duration
    case noiseVolume
    case noiseSmoothness
    case noisePulseDepth
    case voiceCarrier(Int)
    case voiceBeat(Int)
    case voiceVolume(Int)
    case voicePan(Int)
    case voiceIsochronicSoftness(Int)
    case voiceIsochronicDutyCycle(Int)

    public var englishLabel: String {
        switch self {
        case .masterGain: return "MasterGain"
        case .fadeIn: return "FadeIn"
        case .fadeOut: return "FadeOut"
        case .duration: return "Duration"
        case .noiseVolume: return "NoiseVolume"
        case .noiseSmoothness: return "NoiseSmoothness"
        case .noisePulseDepth: return "NoisePulseDepth"
        case .voiceCarrier(let n): return "Voice \(n) Carrier"
        case .voiceBeat(let n): return "Voice \(n) Beat"
        case .voiceVolume(let n): return "Voice \(n) Volume"
        case .voicePan(let n): return "Voice \(n) Pan"
        case .voiceIsochronicSoftness(let n): return "Voice \(n) IsochronicSoftness"
        case .voiceIsochronicDutyCycle(let n): return "Voice \(n) IsochronicDutyCycle"
        }
    }
}

/// Structured, localizable sanitization warning recorded during `.bwg` import.
public enum ImportWarning: Equatable, Sendable {
    case unrecognizedMode(voiceNumber: Int, rawValue: String)
    case unrecognizedWaveform(voiceNumber: Int, rawValue: String)
    case skippedExcessVoice(voiceNumber: Int, maxVoices: Int)
    case skippedInvalidVoice(voiceNumber: Int)
    case ignoredInvalidTrackingRule(voiceNumber: Int)
    case removedCyclicTrackingRule(voiceName: String)
    case droppedMalformedCurvePoints(target: ImportWarningTarget)
    case clampedNegativeTimestamps(target: ImportWarningTarget)
    case clampedCurveValues(target: ImportWarningTarget, min: Double, max: Double)
    case deduplicatedTimestamps(target: ImportWarningTarget)
    case missingDurationDefaulted(defaultSeconds: Int)
    case replacedNonFiniteScalar(target: ImportWarningTarget, fallback: Double)
    case clampedScalar(target: ImportWarningTarget, original: Double, clamped: Double)

    public var englishMessage: String {
        switch self {
        case let .unrecognizedMode(voiceNumber, rawValue):
            return "Voice \(voiceNumber): unrecognized mode '\(rawValue)'; defaulted to binaural."
        case let .unrecognizedWaveform(voiceNumber, rawValue):
            return "Voice \(voiceNumber): unrecognized waveform '\(rawValue)'; defaulted to sine."
        case let .skippedExcessVoice(voiceNumber, maxVoices):
            return "Skipped Voice \(voiceNumber): WaveForge supports at most \(maxVoices) voices."
        case let .skippedInvalidVoice(voiceNumber):
            return "Skipped Voice \(voiceNumber): no finite carrier or beat parameters."
        case let .ignoredInvalidTrackingRule(voiceNumber):
            return "Ignored invalid tracking rule on Voice \(voiceNumber)."
        case let .removedCyclicTrackingRule(voiceName):
            return "Removed cyclic tracking rule on '\(voiceName)'."
        case let .droppedMalformedCurvePoints(target):
            return "Dropped non-finite or malformed point(s) in \(target.englishLabel)."
        case let .clampedNegativeTimestamps(target):
            return "Clamped negative timestamp(s) to 0s in \(target.englishLabel)."
        case let .clampedCurveValues(target, min, max):
            return "Clamped out-of-range value(s) in \(target.englishLabel) to \(min)...\(max)."
        case let .deduplicatedTimestamps(target):
            return "Deduplicated overlapping timestamp(s) in \(target.englishLabel)."
        case let .missingDurationDefaulted(defaultSeconds):
            return "Missing duration; defaulted to \(defaultSeconds)s."
        case let .replacedNonFiniteScalar(target, fallback):
            return "Replaced non-finite \(target.englishLabel) with \(fallback)."
        case let .clampedScalar(target, original, clamped):
            return "Clamped \(target.englishLabel) from \(original) to \(clamped)."
        }
    }
}

/// Non-fatal report summarizing skipped legacy features and sanitization warnings during `.bwg` import.
public struct ImportReport: Equatable, Sendable {
    public var skippedFeatures: [SkippedLegacyFeature]
    public var warnings: [String]
    public var structuredWarnings: [ImportWarning]

    public init(
        skippedFeatures: [SkippedLegacyFeature] = [],
        warnings: [String] = [],
        structuredWarnings: [ImportWarning] = []
    ) {
        self.skippedFeatures = skippedFeatures
        self.warnings = warnings
        self.structuredWarnings = structuredWarnings
    }
}

/// Result returned by `BWGImporter.importPreset(from:fallbackName:)`.
public struct BWGImportResult: Equatable, Sendable {
    public var preset: Preset
    public var report: ImportReport

    public init(preset: Preset, report: ImportReport) {
        self.preset = preset
        self.report = report
    }
}

/// Imports classic BrainWave Generator `.bwg` files (structured text and legacy binary payloads) into `Preset`.
public enum BWGImporter {
    private static let magicHeader = "BrainWave Generator File"
    private static let defaultDurationSec = 1800.0
    private static let defaultMasterGain = 0.85

    /// Parses `.bwg` `data` into a validated `Custom` `Preset` plus a diagnostic `ImportReport`.
    public static func importPreset(from data: Data, fallbackName: String) throws -> BWGImportResult {
        guard !data.isEmpty else {
            throw BWGImportError.emptyFile
        }

        let bodyStartOffset = try validateHeaderOffset(in: data)
        let payload = data.subdata(in: bodyStartOffset..<data.count)
        let (lines, isBinaryPayload) = extractCandidateLines(from: payload)

        var state = ParseState()
        for rawLine in lines {
            parseLine(rawLine, into: &state)
        }

        if !state.recognizedAnyStructure {
            throw BWGImportError.corruptedStructure
        }

        let (builtVoices, numberToIndex) = buildVoices(from: state, stateWarnings: &state)
        guard !builtVoices.isEmpty else {
            throw isBinaryPayload && state.voices.isEmpty
                ? BWGImportError.corruptedStructure
                : BWGImportError.noValidVoices
        }

        let durationSec = resolveDuration(from: state, voices: builtVoices, state: &state)
        let noiseLayer = buildNoiseLayer(from: state, numberToIndex: numberToIndex, state: &state)
        let resolvedName = resolveName(parsed: state.name, fallbackName: fallbackName)
        let resolvedSummary = state.summary ?? "Imported from BrainWave Generator (.bwg)"
        let masterGain = clampScalar(state.masterGain ?? defaultMasterGain, to: PresetLimits.unitRange, target: .masterGain, state: &state)
        let defaultFade = min(10.0, durationSec * 0.1)
        let fadeInSec = clampScalar(state.fadeInSec ?? defaultFade, to: PresetLimits.fadeRange, target: .fadeIn, state: &state)
        let fadeOutSec = clampScalar(state.fadeOutSec ?? defaultFade, to: PresetLimits.fadeRange, target: .fadeOut, state: &state)
        let hasBinaural = builtVoices.contains { $0.isEnabled && $0.mode == .binaural }

        let preset = Preset(
            id: UUID(),
            name: resolvedName,
            category: .custom,
            summary: resolvedSummary,
            durationSec: durationSec,
            recommendedOutput: hasBinaural ? .headphones : .any,
            masterGain: masterGain,
            fadeInSec: fadeInSec,
            fadeOutSec: fadeOutSec,
            noise: noiseLayer,
            voices: builtVoices,
            isBuiltIn: false
        )

        return BWGImportResult(
            preset: preset,
            report: ImportReport(
                skippedFeatures: state.skippedFeatures,
                warnings: state.warnings,
                structuredWarnings: state.structuredWarnings
            )
        )
    }

    // MARK: - Header & Payload Extraction

    private static func validateHeaderOffset(in data: Data) throws -> Int {
        var offset = 0
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            offset = 3
        }

        let headerBytes = Array(magicHeader.utf8)
        guard data.count - offset >= headerBytes.count else {
            throw BWGImportError.invalidHeader
        }

        for i in 0..<headerBytes.count where data[offset + i] != headerBytes[i] {
            throw BWGImportError.invalidHeader
        }

        return offset + headerBytes.count
    }

    private static func extractCandidateLines(from payload: Data) -> (lines: [String], isBinary: Bool) {
        let containsBinaryControl = payload.contains { byte in
            byte == 0x00 || (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D)
        }

        if !containsBinaryControl, let utf8 = String(data: payload, encoding: .utf8) {
            return (splitLines(utf8), false)
        }

        var runs: [String] = []
        var buffer: [UInt8] = []
        buffer.reserveCapacity(128)

        for byte in payload {
            if (byte >= 0x20 && byte <= 0x7E) || byte == 0x09 {
                buffer.append(byte)
            } else if !buffer.isEmpty {
                if let run = String(bytes: buffer, encoding: .ascii) {
                    runs.append(run)
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty, let run = String(bytes: buffer, encoding: .ascii) {
            runs.append(run)
        }

        return (runs, true)
    }

    private static func splitLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Line & Key-Value Parsing

    private struct PartialVoice {
        var name: String?
        var isEnabled: Bool = true
        var isMuted: Bool = false
        var isSolo: Bool = false
        var mode: EntrainmentMode = .binaural
        var waveform: Waveform = .sine
        var isochronicSoftness: Double = 0.5
        var isochronicDutyCycle: Double = 0.5
        var pan: Double = 0.0
        var interpolation: CurveInterpolation = .linear
        var carrierRaw: String?
        var beatRaw: String?
        var volumeRaw: String?
        var trackingRaw: String?
        var trackingSourceNumber: Int?
        var trackingParam: TrackedParameter?
        var trackingRatio: Double?
        var trackingOffset: Double?
    }

    private enum ActiveSection {
        case global
        case noise
        case voice(Int)
    }

    private struct ParseState {
        var activeSection: ActiveSection = .global
        var recognizedAnyStructure: Bool = false
        var name: String?
        var summary: String?
        var durationSec: Double?
        var masterGain: Double?
        var fadeInSec: Double?
        var fadeOutSec: Double?
        var noiseEnabled: Bool?
        var noiseVolumeRaw: String?
        var noiseSmoothnessRaw: String?
        var noiseInterpolation: CurveInterpolation = .linear
        var noisePulseEnabled: Bool = false
        var noisePulseDepth: Double = 0.0
        var noisePulseSourceVoiceNumber: Int?
        var voices: [Int: PartialVoice] = [:]
        var skippedFeatures: [SkippedLegacyFeature] = []
        var warnings: [String] = []
        var structuredWarnings: [ImportWarning] = []

        mutating func recordSkipped(_ feature: SkippedLegacyFeature, warning: String) {
            if !skippedFeatures.contains(feature) {
                skippedFeatures.append(feature)
            }
            warnings.append(warning)
        }

        mutating func recordWarning(_ warning: ImportWarning) {
            structuredWarnings.append(warning)
            warnings.append(warning.englishMessage)
        }
    }

    private static func parseLine(_ rawLine: String, into state: inout ParseState) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") {
            return
        }

        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 3 {
            let sectionName = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
            if sectionName == "general" || sectionName == "preset" || sectionName == "options" {
                state.activeSection = .global
                state.recognizedAnyStructure = true
            } else if sectionName == "noise" {
                state.activeSection = .noise
                state.recognizedAnyStructure = true
            } else if let voiceNum = parseVoiceIndexPrefix(sectionName) {
                state.activeSection = .voice(voiceNum)
                state.recognizedAnyStructure = true
            }
            return
        }

        guard let equalsIdx = trimmed.firstIndex(of: "=") else {
            scanUnstructuredToken(trimmed, into: &state)
            return
        }

        let rawKey = String(trimmed[..<equalsIdx]).trimmingCharacters(in: .whitespaces)
        let rawVal = String(trimmed[trimmed.index(after: equalsIdx)...]).trimmingCharacters(in: .whitespaces)
        let keyLower = rawKey.lowercased()

        if let (voiceNum, property) = splitVoiceKey(keyLower) {
            state.recognizedAnyStructure = true
            parseVoiceProperty(voiceNumber: voiceNum, property: property, value: rawVal, into: &state)
            return
        }

        switch state.activeSection {
        case .global:
            parseGlobalProperty(keyLower: keyLower, value: rawVal, into: &state)
        case .noise:
            if !parseNoiseProperty(property: keyLower, value: rawVal, allowUnprefixed: true, into: &state) {
                parseGlobalProperty(keyLower: keyLower, value: rawVal, into: &state)
            }
        case let .voice(voiceNum):
            state.recognizedAnyStructure = true
            parseVoiceProperty(voiceNumber: voiceNum, property: keyLower, value: rawVal, into: &state)
        }
    }

    private static func scanUnstructuredToken(_ token: String, into state: inout ParseState) {
        if let wavRange = token.range(of: #"[A-Za-z0-9_.\-/\\]+\.wav"#, options: [.regularExpression, .caseInsensitive]) {
            let wavName = String(token[wavRange])
            state.recordSkipped(.externalWavBackground, warning: "Skipped legacy external WAV background '\(wavName)'.")
            state.recognizedAnyStructure = true
        }
        let lower = token.lowercased()
        if lower.contains("audiostrobe") || lower.contains("visualstimulation") {
            state.recordSkipped(.visualStimulation, warning: "Skipped legacy visual stimulation / AudioStrobe directive.")
            state.recognizedAnyStructure = true
        }
    }

    private static func parseGlobalProperty(keyLower: String, value: String, into state: inout ParseState) {
        if parseNoiseProperty(property: keyLower, value: value, allowUnprefixed: false, into: &state) {
            return
        }

        let normalizedKey = normalizeIdentifier(keyLower)
        switch normalizedKey {
        case "version", "formatversion":
            state.recognizedAnyStructure = true
        case "name", "title", "presetname":
            state.recognizedAnyStructure = true
            if !value.isEmpty { state.name = value }
        case "comment", "description", "summary":
            state.recognizedAnyStructure = true
            if !value.isEmpty { state.summary = value }
        case "duration", "durationsec", "length", "totaltime":
            state.recognizedAnyStructure = true
            state.durationSec = parseDurationSeconds(value)
        case "mastergain", "mastervolume":
            state.recognizedAnyStructure = true
            state.masterGain = parseDouble(value)
        case "fadein", "fadeinsec":
            state.recognizedAnyStructure = true
            state.fadeInSec = parseDouble(value)
        case "fadeout", "fadeoutsec":
            state.recognizedAnyStructure = true
            state.fadeOutSec = parseDouble(value)
        case "backgroundsound", "backgroundwav", "backgroundwave", "backgroundfile", "backgroundaudio",
             "wavfile", "wavefile", "audiofile", "soundfile", "ambientwav":
            state.recognizedAnyStructure = true
            if isNonEmptyLegacyResource(value) {
                state.recordSkipped(.externalWavBackground, warning: "Skipped external WAV background '\(value)'.")
            }
        case "visualstimulation", "visualstim", "visual", "audiostrobe", "strobe", "screenflash", "visualmode", "flashing":
            state.recognizedAnyStructure = true
            if isTruthyLegacyFeature(value) {
                state.recordSkipped(.visualStimulation, warning: "Skipped legacy visual stimulation / AudioStrobe option.")
            }
        default:
            if value.lowercased().hasSuffix(".wav") && isNonEmptyLegacyResource(value) {
                state.recognizedAnyStructure = true
                state.recordSkipped(.externalWavBackground, warning: "Skipped external WAV reference '\(value)'.")
            }
        }
    }

    private static func parseNoiseProperty(
        property: String,
        value: String,
        allowUnprefixed: Bool,
        into state: inout ParseState
    ) -> Bool {
        let normalized = normalizeIdentifier(property)
        let canonical: String
        if allowUnprefixed {
            switch normalized {
            case "enabled", "volume", "level", "smoothness", "color", "type",
                 "interpolation", "pulse", "pulseenabled", "pulsedepth",
                 "pulsesource", "pulsesourcevoice":
                canonical = "noise" + normalized
            default:
                canonical = normalized
            }
        } else {
            canonical = normalized
        }

        switch canonical {
        case "noise", "noiseenabled":
            state.noiseEnabled = parseBool(value)
        case "noisevolume", "noiselevel":
            state.noiseVolumeRaw = value
        case "noisesmoothness", "noisecolor", "noisetype":
            state.noiseSmoothnessRaw = value
        case "noiseinterpolation":
            state.noiseInterpolation = parseInterpolation(value)
        case "noisepulse", "noisepulseenabled":
            state.noisePulseEnabled = parseBool(value) ?? false
        case "noisepulsedepth":
            state.noisePulseDepth = parseDouble(value) ?? 0.0
        case "noisepulsesource", "noisepulsesourcevoice":
            state.noisePulseSourceVoiceNumber = parseVoiceIndexPrefix(value) ?? parseInt(value)
        default:
            return false
        }

        state.recognizedAnyStructure = true
        return true
    }

    private static func parseVoiceProperty(
        voiceNumber: Int,
        property: String,
        value: String,
        into state: inout ParseState
    ) {
        var voice = state.voices[voiceNumber] ?? PartialVoice()
        switch normalizeIdentifier(property) {
        case "name", "label":
            if !value.isEmpty { voice.name = value }
        case "enabled", "isenabled", "active":
            voice.isEnabled = parseBool(value) ?? true
        case "muted", "ismuted", "mute":
            voice.isMuted = parseBool(value) ?? false
        case "solo", "issolo":
            voice.isSolo = parseBool(value) ?? false
        case "mode", "entrainmentmode", "type":
            if let parsed = parseMode(value) {
                voice.mode = parsed
            } else {
                state.recordWarning(.unrecognizedMode(voiceNumber: voiceNumber, rawValue: value))
            }
        case "waveform", "wave":
            if let parsed = parseWaveform(value) {
                voice.waveform = parsed
            } else {
                state.recordWarning(.unrecognizedWaveform(voiceNumber: voiceNumber, rawValue: value))
            }
        case "isochronicsoftness", "softness":
            if let parsed = parseDouble(value) { voice.isochronicSoftness = parsed }
        case "isochronicdutycycle", "dutycycle", "duty":
            if let parsed = parseDouble(value) { voice.isochronicDutyCycle = parsed }
        case "pan":
            if let parsed = parseDouble(value) { voice.pan = parsed }
        case "interpolation":
            voice.interpolation = parseInterpolation(value)
        case "carrier", "carrierhz", "basefreq", "frequency", "freq":
            voice.carrierRaw = value
        case "beat", "beathz", "beatfreq":
            voice.beatRaw = value
        case "volume", "vol", "gain", "amp", "amplitude":
            voice.volumeRaw = value
        case "tracking":
            voice.trackingRaw = value
        case "trackingsource", "trackingvoice":
            voice.trackingSourceNumber = parseVoiceIndexPrefix(value) ?? parseInt(value)
        case "trackingparameter", "trackingparam":
            voice.trackingParam = value.lowercased().contains("beat") ? .beat : .carrier
        case "trackingratio":
            voice.trackingRatio = parseDouble(value)
        case "trackingoffset":
            voice.trackingOffset = parseDouble(value)
        default:
            break
        }
        state.voices[voiceNumber] = voice
    }

    // MARK: - Assembly & Sanitization

    private static func buildVoices(from state: ParseState, stateWarnings: inout ParseState) -> (voices: [Voice], numberToIndex: [Int: Int]) {
        let sortedNumbers = state.voices.keys.sorted()
        var validEntries: [(number: Int, partial: PartialVoice, carrier: [CurvePoint], beat: [CurvePoint], volume: [CurvePoint])] = []

        for voiceNum in sortedNumbers {
            guard let partial = state.voices[voiceNum] else { continue }
            if validEntries.count >= PresetLimits.voiceCountRange.upperBound {
                stateWarnings.recordWarning(.skippedExcessVoice(voiceNumber: voiceNum, maxVoices: PresetLimits.voiceCountRange.upperBound))
                continue
            }

            let parsedCarrier = partial.carrierRaw.map {
                sanitizeCurvePoints($0, range: PresetLimits.carrierHzRange, target: .voiceCarrier(voiceNum), state: &stateWarnings)
            } ?? []
            let parsedBeat = partial.beatRaw.map {
                sanitizeCurvePoints($0, range: PresetLimits.beatHzRange, target: .voiceBeat(voiceNum), state: &stateWarnings)
            } ?? []

            guard !parsedCarrier.isEmpty || !parsedBeat.isEmpty else {
                stateWarnings.recordWarning(.skippedInvalidVoice(voiceNumber: voiceNum))
                continue
            }

            let carrierPoints = parsedCarrier.isEmpty ? [CurvePoint(timeSec: 0, value: 200.0)] : parsedCarrier
            let beatPoints = parsedBeat.isEmpty ? [CurvePoint(timeSec: 0, value: 10.0)] : parsedBeat
            let parsedVolume = partial.volumeRaw.map {
                sanitizeCurvePoints($0, range: PresetLimits.unitRange, target: .voiceVolume(voiceNum), state: &stateWarnings)
            } ?? []
            let volumePoints = parsedVolume.isEmpty ? [CurvePoint(timeSec: 0, value: 0.7)] : parsedVolume

            validEntries.append((voiceNum, partial, carrierPoints, beatPoints, volumePoints))
        }

        let numberToIndex = Dictionary(uniqueKeysWithValues: validEntries.enumerated().map { ($1.number, $0) })

        var voices: [Voice] = validEntries.map { entry in
            let p = entry.partial
            let pan = clampScalar(p.pan, to: PresetLimits.panRange, target: .voicePan(entry.number), state: &stateWarnings)
            let softness = clampScalar(
                p.isochronicSoftness,
                to: PresetLimits.isochronicSoftnessRange,
                target: .voiceIsochronicSoftness(entry.number),
                state: &stateWarnings
            )
            let duty = clampScalar(
                p.isochronicDutyCycle,
                to: PresetLimits.isochronicDutyCycleRange,
                target: .voiceIsochronicDutyCycle(entry.number),
                state: &stateWarnings
            )

            let tracking = resolveTrackingRule(
                for: entry.number,
                partial: p,
                numberToIndex: numberToIndex,
                state: &stateWarnings
            )

            return Voice(
                id: UUID(),
                name: p.name ?? "Voice \(entry.number)",
                isEnabled: p.isEnabled,
                isMuted: p.isMuted,
                isSolo: p.isSolo,
                mode: p.mode,
                waveform: p.waveform,
                isochronicSoftness: softness,
                isochronicDutyCycle: duty,
                pan: pan,
                carrierCurve: EnvelopeCurve(points: entry.carrier, interpolation: p.interpolation),
                beatCurve: EnvelopeCurve(points: entry.beat, interpolation: p.interpolation),
                volumeCurve: EnvelopeCurve(points: entry.volume, interpolation: p.interpolation),
                trackingRule: tracking
            )
        }

        breakAnyTrackingCycles(&voices, state: &stateWarnings)
        return (voices, numberToIndex)
    }

    private static func resolveTrackingRule(
        for voiceNumber: Int,
        partial: PartialVoice,
        numberToIndex: [Int: Int],
        state: inout ParseState
    ) -> VoiceTrackingRule? {
        var sourceNumber = partial.trackingSourceNumber
        var targetParam = partial.trackingParam ?? .carrier
        var ratio = partial.trackingRatio ?? 1.0
        var offset = partial.trackingOffset ?? 0.0

        if let raw = partial.trackingRaw {
            let parts = raw.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
            if let first = parts.first {
                sourceNumber = parseVoiceIndexPrefix(first) ?? parseInt(first)
            }
            if parts.count >= 2 {
                targetParam = parts[1].lowercased().contains("beat") ? .beat : .carrier
            }
            if parts.count >= 3, let parsedRatio = parseDouble(parts[2]) {
                ratio = parsedRatio
            }
            if parts.count >= 4, let parsedOffset = parseDouble(parts[3]) {
                offset = parsedOffset
            }
        }

        guard let srcNum = sourceNumber,
              let srcIndex = numberToIndex[srcNum],
              let selfIndex = numberToIndex[voiceNumber],
              srcIndex != selfIndex,
              ratio.isFinite,
              offset.isFinite else {
            if partial.trackingRaw != nil || partial.trackingSourceNumber != nil {
                state.recordWarning(.ignoredInvalidTrackingRule(voiceNumber: voiceNumber))
            }
            return nil
        }

        return VoiceTrackingRule(
            sourceVoiceIndex: srcIndex,
            targetParameter: targetParam,
            ratio: ratio,
            offset: offset
        )
    }

    private static func breakAnyTrackingCycles(_ voices: inout [Voice], state: inout ParseState) {
        for index in voices.indices {
            guard voices[index].trackingRule != nil else { continue }
            var visited: Set<Int> = [index]
            var cursor = voices[index].trackingRule?.sourceVoiceIndex
            while let next = cursor, voices.indices.contains(next) {
                if visited.contains(next) {
                    voices[index].trackingRule = nil
                    state.recordWarning(.removedCyclicTrackingRule(voiceName: voices[index].name))
                    break
                }
                visited.insert(next)
                cursor = voices[next].trackingRule?.sourceVoiceIndex
            }
        }
    }

    private static func sanitizeCurvePoints(
        _ raw: String,
        range: ClosedRange<Double>,
        target: ImportWarningTarget,
        state: inout ParseState
    ) -> [CurvePoint] {
        let rawSegments = raw
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",", omittingEmptySubsequences: true)
        var tokens: [Substring] = []
        for segment in rawSegments {
            let sepCount = segment.filter { $0 == ":" || $0 == "@" }.count
            if sepCount > 1 {
                tokens.append(contentsOf: segment.split(whereSeparator: { $0.isWhitespace }))
            } else {
                tokens.append(segment)
            }
        }

        var indexedValid: [(index: Int, point: CurvePoint)] = []
        var droppedNonFinite = false
        var clampedNegativeTime = false
        var clampedValue = false

        for (index, token) in tokens.enumerated() {
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            let separator: Character? = cleaned.contains(":") ? ":" : (cleaned.contains("@") ? "@" : nil)
            let rawTime: Double
            let rawVal: Double

            if let sep = separator {
                let parts = cleaned.split(separator: sep, maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2,
                      let t = Double(parts[0]),
                      let v = Double(parts[1]) else {
                    droppedNonFinite = true
                    continue
                }
                rawTime = t
                rawVal = v
            } else if let scalar = Double(cleaned) {
                rawTime = 0.0
                rawVal = scalar
            } else {
                droppedNonFinite = true
                continue
            }

            guard rawTime.isFinite, rawVal.isFinite else {
                droppedNonFinite = true
                continue
            }

            var timeSec = rawTime
            if timeSec < 0.0 {
                timeSec = 0.0
                clampedNegativeTime = true
            }

            var value = rawVal
            if !range.contains(value) {
                value = min(range.upperBound, max(range.lowerBound, value))
                clampedValue = true
            }

            indexedValid.append((index, CurvePoint(timeSec: timeSec, value: value)))
        }

        if droppedNonFinite {
            state.recordWarning(.droppedMalformedCurvePoints(target: target))
        }
        if clampedNegativeTime {
            state.recordWarning(.clampedNegativeTimestamps(target: target))
        }
        if clampedValue {
            state.recordWarning(.clampedCurveValues(target: target, min: range.lowerBound, max: range.upperBound))
        }

        indexedValid.sort { lhs, rhs in
            if lhs.point.timeSec != rhs.point.timeSec {
                return lhs.point.timeSec < rhs.point.timeSec
            }
            return lhs.index < rhs.index
        }

        var collapsed: [CurvePoint] = []
        collapsed.reserveCapacity(indexedValid.count)
        var deduplicated = false
        for item in indexedValid {
            if let last = collapsed.last, last.timeSec == item.point.timeSec {
                collapsed[collapsed.count - 1] = item.point
                deduplicated = true
            } else {
                collapsed.append(item.point)
            }
        }
        if deduplicated {
            state.recordWarning(.deduplicatedTimestamps(target: target))
        }

        return collapsed
    }

    private static func buildNoiseLayer(
        from parseState: ParseState,
        numberToIndex: [Int: Int],
        state: inout ParseState
    ) -> NoiseLayer {
        let volPoints: [CurvePoint]
        if let rawVol = parseState.noiseVolumeRaw {
            let parsed = sanitizeCurvePoints(rawVol, range: PresetLimits.unitRange, target: .noiseVolume, state: &state)
            volPoints = parsed.isEmpty ? [CurvePoint(timeSec: 0, value: 0.0)] : parsed
        } else {
            volPoints = [CurvePoint(timeSec: 0, value: parseState.noiseEnabled == true ? 0.2 : 0.0)]
        }

        let smoothPoints: [CurvePoint]
        if let rawSmooth = parseState.noiseSmoothnessRaw {
            let lower = rawSmooth.trimmingCharacters(in: .whitespaces).lowercased()
            switch lower {
            case "white":
                smoothPoints = [CurvePoint(timeSec: 0, value: 0.0)]
            case "pink":
                smoothPoints = [CurvePoint(timeSec: 0, value: 0.5)]
            case "brown":
                smoothPoints = [CurvePoint(timeSec: 0, value: 1.0)]
            default:
                let parsed = sanitizeCurvePoints(rawSmooth, range: PresetLimits.unitRange, target: .noiseSmoothness, state: &state)
                smoothPoints = parsed.isEmpty ? [CurvePoint(timeSec: 0, value: 0.5)] : parsed
            }
        } else {
            smoothPoints = [CurvePoint(timeSec: 0, value: 0.5)]
        }

        let hasAudibleNoise = volPoints.contains { $0.value > 0.0 }
        let isEnabled = parseState.noiseEnabled ?? hasAudibleNoise
        let pulseDepth = clampScalar(parseState.noisePulseDepth, to: PresetLimits.unitRange, target: .noisePulseDepth, state: &state)

        let pulseSourceIndex: Int?
        if let sourceNum = parseState.noisePulseSourceVoiceNumber {
            pulseSourceIndex = numberToIndex[sourceNum]
        } else {
            pulseSourceIndex = nil
        }

        return NoiseLayer(
            isEnabled: isEnabled,
            volumeCurve: EnvelopeCurve(points: volPoints, interpolation: parseState.noiseInterpolation),
            smoothnessCurve: EnvelopeCurve(points: smoothPoints, interpolation: parseState.noiseInterpolation),
            pulseEnabled: parseState.noisePulseEnabled,
            pulseDepth: pulseDepth,
            pulseSourceVoiceIndex: pulseSourceIndex
        )
    }

    private static func resolveDuration(from parseState: ParseState, voices: [Voice], state: inout ParseState) -> Double {
        if let parsed = parseState.durationSec {
            return clampScalar(parsed, to: PresetLimits.durationRange, target: .duration, state: &state)
        }

        let maxCurveTime = voices.flatMap { voice in
            voice.carrierCurve.points + voice.beatCurve.points + voice.volumeCurve.points
        }.map(\.timeSec).max() ?? 0.0

        if maxCurveTime >= PresetLimits.durationRange.lowerBound {
            return clampScalar(maxCurveTime, to: PresetLimits.durationRange, target: .duration, state: &state)
        }

        let defaultSec = Int(defaultDurationSec)
        state.recordWarning(.missingDurationDefaulted(defaultSeconds: defaultSec))
        return defaultDurationSec
    }

    private static func resolveName(parsed: String?, fallbackName: String) -> String {
        if let parsed = parsed?.trimmingCharacters(in: .whitespacesAndNewlines), !parsed.isEmpty {
            return parsed
        }
        let fallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Imported Preset" : fallback
    }

    // MARK: - Primitive Parsers

    private static func splitVoiceKey(_ keyLower: String) -> (Int, String)? {
        guard let dotIndex = keyLower.firstIndex(of: ".") ?? keyLower.firstIndex(of: "_") else {
            return nil
        }
        let prefix = String(keyLower[..<dotIndex])
        let property = String(keyLower[keyLower.index(after: dotIndex)...])
        guard !property.isEmpty, let number = parseVoiceIndexPrefix(prefix) else {
            return nil
        }
        return (number, property)
    }

    private static func parseVoiceIndexPrefix(_ raw: String) -> Int? {
        let cleaned = normalizeIdentifier(raw)
        if cleaned.hasPrefix("voice"), let num = Int(cleaned.dropFirst(5)), num >= 0 {
            return num
        }
        if cleaned.hasPrefix("v"), cleaned.count >= 2, let num = Int(cleaned.dropFirst(1)), num >= 0 {
            return num
        }
        return nil
    }

    private static func normalizeIdentifier(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func parseDouble(_ raw: String) -> Double? {
        guard let val = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), val.isFinite else {
            return nil
        }
        return val
    }

    private static func parseInt(_ raw: String) -> Int? {
        Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseDurationSeconds(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numeric = Double(trimmed), numeric.isFinite {
            return numeric
        }
        let rawParts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard rawParts.count == 2 || rawParts.count == 3 else {
            return nil
        }
        var parts: [Double] = []
        parts.reserveCapacity(rawParts.count)
        for segment in rawParts {
            let cleaned = segment.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, let parsed = Double(cleaned), parsed.isFinite, parsed >= 0.0 else {
                return nil
            }
            parts.append(parsed)
        }
        let total = parts.count == 2
            ? (parts[0] * 60.0 + parts[1])
            : (parts[0] * 3600.0 + parts[1] * 60.0 + parts[2])
        return total.isFinite ? total : nil
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func isTruthyLegacyFeature(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if ["0", "false", "no", "off", "none", "null"].contains(lower) {
            return false
        }
        return true
    }

    private static func isNonEmptyLegacyResource(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.isEmpty && !["0", "false", "no", "off", "none", "null"].contains(lower)
    }

    private static func parseMode(_ raw: String) -> EntrainmentMode? {
        switch normalizeIdentifier(raw) {
        case "binaural", "bin", "0": return .binaural
        case "monaural", "mono", "1": return .monaural
        case "isochronic", "iso", "pulse", "2": return .isochronic
        default: return nil
        }
    }

    private static func parseWaveform(_ raw: String) -> Waveform? {
        switch normalizeIdentifier(raw) {
        case "sine", "sin", "0": return .sine
        case "sinesquared", "sine2", "sin2", "1": return .sineSquared
        case "triangle", "tri", "2": return .triangle
        case "square", "sq", "3": return .square
        case "smoothedsquare", "smoothsquare", "smoothsq", "4": return .smoothSquare
        default: return nil
        }
    }

    private static func parseInterpolation(_ raw: String) -> CurveInterpolation {
        switch normalizeIdentifier(raw) {
        case "smoothstep", "smooth", "scurve", "hermite": return .smoothStep
        default: return .linear
        }
    }

    private static func clampScalar(
        _ value: Double,
        to range: ClosedRange<Double>,
        target: ImportWarningTarget,
        state: inout ParseState
    ) -> Double {
        guard value.isFinite else {
            state.recordWarning(.replacedNonFiniteScalar(target: target, fallback: range.lowerBound))
            return range.lowerBound
        }
        if !range.contains(value) {
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            state.recordWarning(.clampedScalar(target: target, original: value, clamped: clamped))
            return clamped
        }
        return value
    }
}
