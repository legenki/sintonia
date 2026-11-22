import Testing
@testable import SynthCore

@Suite("Curves, Waveforms, and Stereo Noise")
struct CurveWaveformNoiseTests {
    @Test func curveInterpolationAndEdgeClamping() {
        let linear = CompiledCurve(
            points: [CurvePoint(timeSec: 10, value: 100), CurvePoint(timeSec: 20, value: 200)],
            interpolation: .linear
        )
        #expect(linear.evaluate(at: 0) == 100)
        #expect(linear.evaluate(at: 15) == 150)
        #expect(linear.evaluate(at: 30) == 200)

        let smooth = CompiledCurve(
            points: [CurvePoint(timeSec: 0, value: 0), CurvePoint(timeSec: 10, value: 100)],
            interpolation: .smoothStep
        )
        #expect(abs(smooth.evaluate(at: 2.5) - 15.625) < 1e-6)
        #expect(smooth.evaluate(at: 5.0) == 50)
    }

    @Test func curveSanitizesDuplicateUnsortedAndNaNPoints() {
        let dirty = CompiledCurve(
            points: [
                CurvePoint(timeSec: 20, value: 200),
                CurvePoint(timeSec: .nan, value: 999),
                CurvePoint(timeSec: -5, value: 50),
                CurvePoint(timeSec: 10, value: 120),
                CurvePoint(timeSec: 10, value: 140),
                CurvePoint(timeSec: 15, value: .infinity),
            ],
            interpolation: .smoothStep
        )
        for t in stride(from: -10.0, through: 30.0, by: 0.5) {
            let v = dirty.evaluate(at: t)
            #expect(v.isFinite)
        }
        #expect(dirty.evaluate(at: 0) == 50)
        #expect(dirty.evaluate(at: 25) == 200)
    }

    @Test func allFiveWaveformsRangeAndSineSquaredZeroDC() {
        let steps = 48_000
        let inc = 200.0 / 48_000.0
        for waveform in Waveform.allCases {
            var sum = 0.0
            for i in 0..<steps {
                let phase = (Double(i) * inc).truncatingRemainder(dividingBy: 1.0)
                let s = WaveformOscillator.sample(waveform: waveform, phase: phase, phaseIncrement: inc)
                #expect(s.isFinite && abs(s) <= 1.001)
                sum += s
            }
            if waveform == .sineSquared {
                #expect(abs(sum / Double(steps)) < 1e-3)
            }
        }
    }

    @Test func isochronicEnvelopeSmoothEdges() {
        var prev = IsochronicEnvelope.sample(phase: 0.0, dutyCycle: 0.5, softness: 0.5)
        var minVal = prev
        var maxVal = prev
        for i in 1...1000 {
            let v = IsochronicEnvelope.sample(phase: Double(i) / 1000.0, dutyCycle: 0.5, softness: 0.5)
            #expect(v >= 0.0 && v <= 1.0)
            #expect(abs(v - prev) < 0.02)
            prev = v
            minVal = min(minVal, v)
            maxVal = max(maxVal, v)
        }
        #expect(minVal < 0.01 && maxVal > 0.99)
    }

    @Test func stereoNoiseRMSContinuityAndDecorrelation() {
        var rmsValues: [Double] = []
        for smoothness in [0.0, 0.25, 0.5, 0.75, 1.0] {
            var gen = StereoNoiseGenerator(leftSeed: 111, rightSeed: 222)
            var sumSqL = 0.0
            var dotLR = 0.0
            var sumSqR = 0.0
            let n = 48_000
            for _ in 0..<n {
                let (l, r) = gen.nextSample(smoothness: smoothness)
                #expect(l.isFinite && r.isFinite)
                sumSqL += l * l
                sumSqR += r * r
                dotLR += l * r
            }
            let rmsL = (sumSqL / Double(n)).squareRoot()
            rmsValues.append(rmsL)
            let corr = abs(dotLR / (sumSqL * sumSqR).squareRoot())
            #expect(corr < 0.05)
        }
        for i in 1..<rmsValues.count {
            let ratio = rmsValues[i] / rmsValues[i - 1]
            #expect(ratio > 0.65 && ratio < 1.55)
        }
    }

    @Test func compiledCurveExposesPointsAndHandlesEmptyAndNonFiniteQueries() {
        let empty = CompiledCurve(points: [CurvePoint(timeSec: .nan, value: 1)], interpolation: .smoothStep)
        #expect(empty.points == [CurvePoint(timeSec: 0, value: 0)])
        #expect(empty.interpolation == .smoothStep)
        #expect(empty.evaluate(at: 0) == 0)
        #expect(empty.evaluate(at: .nan) == 0)
        #expect(empty.evaluate(at: -.infinity) == 0)
        #expect(empty.evaluate(at: .infinity) == 0)

        let multi = CompiledCurve(
            points: [
                CurvePoint(timeSec: 10, value: 20),
                CurvePoint(timeSec: 0, value: 10),
                CurvePoint(timeSec: 10, value: 30),
            ],
            interpolation: .linear
        )
        #expect(multi.points == [CurvePoint(timeSec: 0, value: 10), CurvePoint(timeSec: 10, value: 30)])
        #expect(multi.evaluate(at: .nan) == 10)
        #expect(multi.evaluate(at: -.infinity) == 10)
        #expect(multi.evaluate(at: .infinity) == 30)
    }

    @Test func xoshiroSeedZeroAndIsochronicAndNoiseEdgeBounds() {
        var rng = Xoshiro256StarStar(seed: 0)
        for _ in 0..<1000 {
            let u = rng.nextUnitDouble()
            #expect(u >= 0.0 && u < 1.0 && u.isFinite)
        }

        for duty in [0.0, 0.2, 0.8, 1.0] {
            for softness in [0.0, 0.05, 1.0] {
                for phase in [-0.25, 0.0, 0.1, 0.5, 0.9, 1.25] {
                    let v = IsochronicEnvelope.sample(phase: phase, dutyCycle: duty, softness: softness)
                    #expect(v >= 0.0 && v <= 1.0 && v.isFinite)
                }
            }
        }

        var noise = StereoNoiseGenerator(leftSeed: 1, rightSeed: 2)
        for s in [-1.0, .nan, .infinity, 2.0] {
            let (l, r) = noise.nextSample(smoothness: s)
            #expect(l.isFinite && r.isFinite)
        }
    }
}
