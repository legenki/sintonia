import Foundation
import SynthCore

/// Compiles declarative `Preset` models into real-time `SynthSnapshot` values,
/// resolving acyclic `VoiceTrackingRule` dependencies in topological order.
public enum SnapshotCompiler {
    private static let clampedSegmentSubdivisions = 32

    /// Compiles `preset` into an immutable `SynthSnapshot` suitable for `SynthRenderer`.
    /// Any cyclic or out-of-bounds tracking rule safely falls back to the voice's own curve.
    public static func compile(_ preset: Preset) -> SynthSnapshot {
        let count = preset.voices.count
        var carrierCurves = preset.voices.map { $0.carrierCurve.compiled() }
        var beatCurves = preset.voices.map { $0.beatCurve.compiled() }
        let volumeCurves = preset.voices.map { $0.volumeCurve.compiled() }

        for index in topologicalOrder(for: preset.voices) {
            guard let rule = preset.voices[index].trackingRule,
                  rule.ratio.isFinite,
                  rule.offset.isFinite,
                  (0..<count).contains(rule.sourceVoiceIndex),
                  rule.sourceVoiceIndex != index else {
                continue
            }

            switch rule.targetParameter {
            case .carrier:
                carrierCurves[index] = deriveCurve(
                    from: carrierCurves[rule.sourceVoiceIndex],
                    ratio: rule.ratio,
                    offset: rule.offset,
                    clampRange: PresetLimits.carrierHzRange
                )
            case .beat:
                beatCurves[index] = deriveCurve(
                    from: beatCurves[rule.sourceVoiceIndex],
                    ratio: rule.ratio,
                    offset: rule.offset,
                    clampRange: PresetLimits.beatHzRange
                )
            }
        }

        let compiledVoices: [VoiceSnapshot] = (0..<count).map { index in
            let voice = preset.voices[index]
            return VoiceSnapshot(
                id: voice.id,
                isEnabled: voice.isEnabled,
                isMuted: voice.isMuted,
                isSolo: voice.isSolo,
                mode: voice.mode,
                waveform: voice.waveform,
                isochronicSoftness: clampFinite(
                    voice.isochronicSoftness,
                    to: PresetLimits.isochronicSoftnessRange,
                    fallback: 0.5
                ),
                isochronicDutyCycle: clampFinite(
                    voice.isochronicDutyCycle,
                    to: PresetLimits.isochronicDutyCycleRange,
                    fallback: 0.5
                ),
                pan: clampFinite(voice.pan, to: PresetLimits.panRange, fallback: 0.0),
                carrierCurve: carrierCurves[index],
                beatCurve: beatCurves[index],
                volumeCurve: volumeCurves[index]
            )
        }

        let validPulseSource: Int? = {
            guard let sourceIndex = preset.noise.pulseSourceVoiceIndex,
                  (0..<min(count, SynthSnapshot.maxVoices)).contains(sourceIndex) else {
                return nil
            }
            return sourceIndex
        }()

        let compiledNoise = NoiseSnapshot(
            isEnabled: preset.noise.isEnabled,
            volumeCurve: preset.noise.volumeCurve.compiled(),
            smoothnessCurve: preset.noise.smoothnessCurve.compiled(),
            pulseEnabled: preset.noise.pulseEnabled,
            pulseDepth: clampFinite(preset.noise.pulseDepth, to: PresetLimits.unitRange, fallback: 0.0),
            pulseSourceVoiceIndex: validPulseSource
        )

        let duration = preset.durationSec.isFinite ? max(0.0, preset.durationSec) : 0.0
        return SynthSnapshot(
            durationSec: duration,
            masterGain: clampFinite(preset.masterGain, to: PresetLimits.unitRange, fallback: 1.0),
            fadeInSec: clampFinite(preset.fadeInSec, to: PresetLimits.fadeRange, fallback: 0.0),
            fadeOutSec: clampFinite(preset.fadeOutSec, to: PresetLimits.fadeRange, fallback: 0.0),
            noise: compiledNoise,
            voices: compiledVoices
        )
    }

    private static func topologicalOrder(for voices: [Voice]) -> [Int] {
        let count = voices.count
        guard count > 0 else { return [] }

        var dependents = [[Int]](repeating: [], count: count)
        var inDegree = [Int](repeating: 0, count: count)

        for (index, voice) in voices.enumerated() {
            guard let rule = voice.trackingRule,
                  rule.ratio.isFinite,
                  rule.offset.isFinite,
                  (0..<count).contains(rule.sourceVoiceIndex),
                  rule.sourceVoiceIndex != index else {
                continue
            }
            dependents[rule.sourceVoiceIndex].append(index)
            inDegree[index] += 1
        }

        var queue: [Int] = []
        queue.reserveCapacity(count)
        for index in 0..<count where inDegree[index] == 0 {
            queue.append(index)
        }

        var order: [Int] = []
        order.reserveCapacity(count)
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            order.append(current)

            for dependent in dependents[current] {
                inDegree[dependent] -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }

        return order
    }

    private static func deriveCurve(
        from source: CompiledCurve,
        ratio: Double,
        offset: Double,
        clampRange: ClosedRange<Double>
    ) -> CompiledCurve {
        let points = source.points
        guard !points.isEmpty else {
            return CompiledCurve(
                points: [CurvePoint(timeSec: 0.0, value: clampRange.lowerBound)],
                interpolation: source.interpolation
            )
        }

        if points.count == 1 {
            let raw = ratio * points[0].value + offset
            return CompiledCurve(
                points: [CurvePoint(timeSec: points[0].timeSec, value: clampFinite(raw, to: clampRange, fallback: clampRange.lowerBound))],
                interpolation: source.interpolation
            )
        }

        var derivedPoints: [CurvePoint] = []
        derivedPoints.reserveCapacity(points.count)

        for segmentIndex in 0..<(points.count - 1) {
            let p0 = points[segmentIndex]
            let p1 = points[segmentIndex + 1]
            let raw0 = ratio * p0.value + offset
            let raw1 = ratio * p1.value + offset

            if segmentIndex == 0 {
                derivedPoints.append(
                    CurvePoint(
                        timeSec: p0.timeSec,
                        value: clampFinite(raw0, to: clampRange, fallback: clampRange.lowerBound)
                    )
                )
            }

            if !clampRange.contains(raw0) || !clampRange.contains(raw1) {
                let dt = p1.timeSec - p0.timeSec
                for step in 1..<clampedSegmentSubdivisions {
                    let fraction = Double(step) / Double(clampedSegmentSubdivisions)
                    let t = p0.timeSec + dt * fraction
                    let raw = ratio * source.evaluate(at: t) + offset
                    derivedPoints.append(
                        CurvePoint(
                            timeSec: t,
                            value: clampFinite(raw, to: clampRange, fallback: clampRange.lowerBound)
                        )
                    )
                }
            }

            derivedPoints.append(
                CurvePoint(
                    timeSec: p1.timeSec,
                    value: clampFinite(raw1, to: clampRange, fallback: clampRange.lowerBound)
                )
            )
        }

        return CompiledCurve(points: derivedPoints, interpolation: source.interpolation)
    }

    private static func clampFinite(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
