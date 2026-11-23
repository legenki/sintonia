import Foundation
import SynthCore

/// Canonical preset category used for library organization and filtering.
public enum PresetCategory: String, Codable, Sendable, CaseIterable {
    case focus
    case relax
    case sleep
    case meditation
    case study
    case creative
    case custom
}

/// Recommended playback hardware hint derived from active entrainment modes.
public enum OutputHint: String, Codable, Sendable, CaseIterable {
    case headphones
    case any
}

/// Voice parameter targeted by a `VoiceTrackingRule`.
public enum TrackedParameter: String, Codable, Sendable, CaseIterable {
    case carrier
    case beat
}

/// Relative tracking rule binding a voice's carrier or beat frequency to another voice.
public struct VoiceTrackingRule: Codable, Sendable, Equatable {
    public var sourceVoiceIndex: Int
    public var targetParameter: TrackedParameter
    public var ratio: Double
    public var offset: Double

    public init(
        sourceVoiceIndex: Int,
        targetParameter: TrackedParameter,
        ratio: Double,
        offset: Double
    ) {
        self.sourceVoiceIndex = sourceVoiceIndex
        self.targetParameter = targetParameter
        self.ratio = ratio
        self.offset = offset
    }
}

/// Declarative time-varying parameter automation curve.
public struct EnvelopeCurve: Codable, Sendable, Equatable {
    public var points: [CurvePoint]
    public var interpolation: CurveInterpolation

    public init(points: [CurvePoint], interpolation: CurveInterpolation = .linear) {
        self.points = points
        self.interpolation = interpolation
    }

    /// Compiles this curve into a sanitized, monotonically sorted `CompiledCurve`.
    public func compiled() -> CompiledCurve {
        CompiledCurve(points: points, interpolation: interpolation)
    }

    /// Evaluates the curve at `timeSec` using `CompiledCurve` semantics.
    public func evaluate(at timeSec: Double) -> Double {
        compiled().evaluate(at: timeSec)
    }
}

/// Declarative configuration for the stereo colored noise background layer.
public struct NoiseLayer: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var volumeCurve: EnvelopeCurve
    public var smoothnessCurve: EnvelopeCurve
    public var pulseEnabled: Bool
    public var pulseDepth: Double
    public var pulseSourceVoiceIndex: Int?

    public init(
        isEnabled: Bool,
        volumeCurve: EnvelopeCurve,
        smoothnessCurve: EnvelopeCurve,
        pulseEnabled: Bool,
        pulseDepth: Double,
        pulseSourceVoiceIndex: Int?
    ) {
        self.isEnabled = isEnabled
        self.volumeCurve = volumeCurve
        self.smoothnessCurve = smoothnessCurve
        self.pulseEnabled = pulseEnabled
        self.pulseDepth = pulseDepth
        self.pulseSourceVoiceIndex = pulseSourceVoiceIndex
    }

    /// Disabled noise layer placeholder with zero output volume.
    public static let disabled = NoiseLayer(
        isEnabled: false,
        volumeCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.0)], interpolation: .linear),
        smoothnessCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.5)], interpolation: .linear),
        pulseEnabled: false,
        pulseDepth: 0.0,
        pulseSourceVoiceIndex: nil
    )
}

/// Single entrainment oscillator voice in a `Preset` (up to 10 voices per session).
public struct Voice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var isMuted: Bool
    public var isSolo: Bool
    public var mode: EntrainmentMode
    public var waveform: Waveform
    public var isochronicSoftness: Double
    public var isochronicDutyCycle: Double
    public var pan: Double
    public var carrierCurve: EnvelopeCurve
    public var beatCurve: EnvelopeCurve
    public var volumeCurve: EnvelopeCurve
    public var trackingRule: VoiceTrackingRule?

    public init(
        id: UUID,
        name: String,
        isEnabled: Bool,
        isMuted: Bool,
        isSolo: Bool,
        mode: EntrainmentMode,
        waveform: Waveform,
        isochronicSoftness: Double,
        isochronicDutyCycle: Double,
        pan: Double,
        carrierCurve: EnvelopeCurve,
        beatCurve: EnvelopeCurve,
        volumeCurve: EnvelopeCurve,
        trackingRule: VoiceTrackingRule?
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.mode = mode
        self.waveform = waveform
        self.isochronicSoftness = isochronicSoftness
        self.isochronicDutyCycle = isochronicDutyCycle
        self.pan = pan
        self.carrierCurve = carrierCurve
        self.beatCurve = beatCurve
        self.volumeCurve = volumeCurve
        self.trackingRule = trackingRule
    }
}

/// Complete declarative WaveForge entrainment session preset.
public struct Preset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var category: PresetCategory
    public var summary: String
    public var durationSec: Double
    public var recommendedOutput: OutputHint
    public var masterGain: Double
    public var fadeInSec: Double
    public var fadeOutSec: Double
    public var noise: NoiseLayer
    public var voices: [Voice]
    public var isBuiltIn: Bool

    public init(
        id: UUID,
        name: String,
        category: PresetCategory,
        summary: String,
        durationSec: Double,
        recommendedOutput: OutputHint,
        masterGain: Double,
        fadeInSec: Double,
        fadeOutSec: Double,
        noise: NoiseLayer,
        voices: [Voice],
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.durationSec = durationSec
        self.recommendedOutput = recommendedOutput
        self.masterGain = masterGain
        self.fadeInSec = fadeInSec
        self.fadeOutSec = fadeOutSec
        self.noise = noise
        self.voices = voices
        self.isBuiltIn = isBuiltIn
    }
}

/// Canonical parameter bounds shared by `PresetValidator` and `SnapshotCompiler`.
public enum PresetLimits {
    public static let durationRange: ClosedRange<Double> = 60.0...7200.0
    public static let voiceCountRange: ClosedRange<Int> = 1...10
    public static let unitRange: ClosedRange<Double> = 0.0...1.0
    public static let fadeRange: ClosedRange<Double> = 0.0...120.0
    public static let panRange: ClosedRange<Double> = -1.0...1.0
    public static let isochronicSoftnessRange: ClosedRange<Double> = 0.05...1.0
    public static let isochronicDutyCycleRange: ClosedRange<Double> = 0.2...0.8
    public static let carrierHzRange: ClosedRange<Double> = 40.0...1000.0
    public static let beatHzRange: ClosedRange<Double> = 0.5...60.0
    public static let maxImportFileBytes: Int = 4 * 1024 * 1024
    public static let maxCurvePoints: Int = 4_096
    public static let maxNameLength: Int = 256
    public static let maxSummaryLength: Int = 2_000
}
