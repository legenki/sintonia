import Foundation
import SynthCore

/// Validation errors returned by `PresetValidator.validate(_:)`.
public enum PresetValidationError: Error, Equatable, Sendable {
    case invalidDuration
    case invalidVoiceCount
    case invalidMasterGain
    case invalidFadeIn
    case invalidFadeOut
    case invalidNoiseVolume
    case invalidNoiseSmoothness
    case invalidNoisePulseDepth
    case invalidNoisePulseSourceVoiceIndex
    case invalidPan(voiceIndex: Int)
    case invalidIsochronicSoftness(voiceIndex: Int)
    case invalidIsochronicDutyCycle(voiceIndex: Int)
    case emptyCurve(voiceIndex: Int?)
    case nonFiniteValue(voiceIndex: Int?)
    case negativeCurveTime(voiceIndex: Int?)
    case carrierOutOfRange(voiceIndex: Int)
    case beatOutOfRange(voiceIndex: Int)
    case volumeOutOfRange(voiceIndex: Int)
    case trackingSourceOutOfBounds(voiceIndex: Int, sourceVoiceIndex: Int)
    case cyclicTracking(voiceIndices: [Int])
}

/// Validates declarative `Preset` documents against canonical WaveForge bounds and graph invariants.
public enum PresetValidator {
    /// Returns all validation errors found in `preset`, or an empty array if valid.
    public static func validate(_ preset: Preset) -> [PresetValidationError] {
        var errors: [PresetValidationError] = []

        if !isValid(preset.durationSec, in: PresetLimits.durationRange) {
            errors.append(.invalidDuration)
        }
        if !PresetLimits.voiceCountRange.contains(preset.voices.count) {
            errors.append(.invalidVoiceCount)
        }
        if !isValid(preset.masterGain, in: PresetLimits.unitRange) {
            errors.append(.invalidMasterGain)
        }
        if !isValid(preset.fadeInSec, in: PresetLimits.fadeRange) {
            errors.append(.invalidFadeIn)
        }
        if !isValid(preset.fadeOutSec, in: PresetLimits.fadeRange) {
            errors.append(.invalidFadeOut)
        }

        validateNoise(preset.noise, voiceCount: preset.voices.count, errors: &errors)

        for (index, voice) in preset.voices.enumerated() {
            validateVoice(voice, at: index, voiceCount: preset.voices.count, errors: &errors)
        }

        detectTrackingCycles(in: preset.voices, errors: &errors)

        return errors
    }

    private static func isValid(_ value: Double, in range: ClosedRange<Double>) -> Bool {
        value.isFinite && range.contains(value)
    }

    private static func validateNoise(
        _ noise: NoiseLayer,
        voiceCount: Int,
        errors: inout [PresetValidationError]
    ) {
        validateCurve(
            noise.volumeCurve,
            voiceIndex: nil,
            range: PresetLimits.unitRange,
            outOfRangeError: .invalidNoiseVolume,
            errors: &errors
        )
        validateCurve(
            noise.smoothnessCurve,
            voiceIndex: nil,
            range: PresetLimits.unitRange,
            outOfRangeError: .invalidNoiseSmoothness,
            errors: &errors
        )
        if !isValid(noise.pulseDepth, in: PresetLimits.unitRange) {
            errors.append(.invalidNoisePulseDepth)
        }
        if let sourceIdx = noise.pulseSourceVoiceIndex, !(0..<voiceCount).contains(sourceIdx) {
            errors.append(.invalidNoisePulseSourceVoiceIndex)
        }
    }

    private static func validateVoice(
        _ voice: Voice,
        at index: Int,
        voiceCount: Int,
        errors: inout [PresetValidationError]
    ) {
        if !isValid(voice.pan, in: PresetLimits.panRange) {
            errors.append(.invalidPan(voiceIndex: index))
        }
        if !isValid(voice.isochronicSoftness, in: PresetLimits.isochronicSoftnessRange) {
            errors.append(.invalidIsochronicSoftness(voiceIndex: index))
        }
        if !isValid(voice.isochronicDutyCycle, in: PresetLimits.isochronicDutyCycleRange) {
            errors.append(.invalidIsochronicDutyCycle(voiceIndex: index))
        }

        validateCurve(
            voice.carrierCurve,
            voiceIndex: index,
            range: PresetLimits.carrierHzRange,
            outOfRangeError: .carrierOutOfRange(voiceIndex: index),
            errors: &errors
        )
        validateCurve(
            voice.beatCurve,
            voiceIndex: index,
            range: PresetLimits.beatHzRange,
            outOfRangeError: .beatOutOfRange(voiceIndex: index),
            errors: &errors
        )
        validateCurve(
            voice.volumeCurve,
            voiceIndex: index,
            range: PresetLimits.unitRange,
            outOfRangeError: .volumeOutOfRange(voiceIndex: index),
            errors: &errors
        )

        if let rule = voice.trackingRule {
            if !rule.ratio.isFinite || !rule.offset.isFinite {
                errors.append(.nonFiniteValue(voiceIndex: index))
            }
            if !(0..<voiceCount).contains(rule.sourceVoiceIndex) {
                errors.append(.trackingSourceOutOfBounds(voiceIndex: index, sourceVoiceIndex: rule.sourceVoiceIndex))
            }
        }
    }

    private static func validateCurve(
        _ curve: EnvelopeCurve,
        voiceIndex: Int?,
        range: ClosedRange<Double>,
        outOfRangeError: PresetValidationError,
        errors: inout [PresetValidationError]
    ) {
        guard !curve.points.isEmpty else {
            errors.append(.emptyCurve(voiceIndex: voiceIndex))
            return
        }

        var hasNonFinite = false
        var hasNegativeTime = false
        var hasOutOfRange = false

        for point in curve.points {
            if !point.timeSec.isFinite || !point.value.isFinite {
                hasNonFinite = true
                continue
            }
            if point.timeSec < 0.0 {
                hasNegativeTime = true
            }
            if !range.contains(point.value) {
                hasOutOfRange = true
            }
        }

        if hasNonFinite {
            errors.append(.nonFiniteValue(voiceIndex: voiceIndex))
        }
        if hasNegativeTime {
            errors.append(.negativeCurveTime(voiceIndex: voiceIndex))
        }
        if hasOutOfRange {
            errors.append(outOfRangeError)
        }
    }

    private static func detectTrackingCycles(
        in voices: [Voice],
        errors: inout [PresetValidationError]
    ) {
        enum VisitColor {
            case white
            case gray
            case black
        }

        let count = voices.count
        var colors = [VisitColor](repeating: .white, count: count)

        for start in 0..<count {
            guard colors[start] == .white else { continue }

            var path: [Int] = []
            var current: Int? = start

            while let node = current {
                colors[node] = .gray
                path.append(node)

                guard let next = voices[node].trackingRule?.sourceVoiceIndex,
                      (0..<count).contains(next) else {
                    current = nil
                    break
                }

                switch colors[next] {
                case .white:
                    current = next
                case .gray:
                    if let cycleStart = path.firstIndex(of: next) {
                        errors.append(.cyclicTracking(voiceIndices: Array(path[cycleStart...])))
                    }
                    current = nil
                case .black:
                    current = nil
                }
            }

            for visitedNode in path {
                colors[visitedNode] = .black
            }
        }
    }
}
