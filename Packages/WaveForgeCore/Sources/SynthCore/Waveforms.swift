import Darwin

/// Band-limited and classic BrainWave Generator waveform oscillator.
public enum WaveformOscillator {
    private static let tanh35 = tanh(3.5)

    public static func sample(waveform: Waveform, phase: Double, phaseIncrement: Double) -> Double {
        guard phase.isFinite else { return 0.0 }
        let wrapped = phase - floor(phase)
        let p = wrapped >= 1.0 ? 0.0 : wrapped

        switch waveform {
        case .sine:
            return sin(2.0 * .pi * p)

        case .sineSquared:
            let s = sin(.pi * p)
            return 2.0 * s * s - 1.0

        case .triangle:
            if p < 0.25 {
                return 4.0 * p
            } else if p < 0.75 {
                return 2.0 - 4.0 * p
            } else {
                return 4.0 * p - 4.0
            }

        case .square:
            let dt = phaseIncrement.isFinite ? min(0.25, max(0.0, abs(phaseIncrement))) : 0.0
            var value = p < 0.5 ? 1.0 : -1.0
            value += polyBLEP(t: p, dt: dt)
            let shifted = p >= 0.5 ? p - 0.5 : p + 0.5
            value -= polyBLEP(t: shifted, dt: dt)
            return min(1.0, max(-1.0, value))

        case .smoothSquare:
            return tanh(3.5 * sin(2.0 * .pi * p)) / tanh35
        }
    }

    @inline(__always)
    private static func polyBLEP(t: Double, dt: Double) -> Double {
        guard dt > 0.0 else { return 0.0 }
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1.0
        } else if t > 1.0 - dt {
            let x = (t - 1.0) / dt
            return x * x + x + x + 1.0
        }
        return 0.0
    }
}

/// Raised-cosine trapezoidal amplitude envelope for isochronic pulse modulation.
public enum IsochronicEnvelope {
    public static func sample(phase: Double, dutyCycle: Double, softness: Double) -> Double {
        guard phase.isFinite else { return 0.0 }
        let wrapped = phase - floor(phase)
        let p = wrapped >= 1.0 ? 0.0 : wrapped
        let duty = dutyCycle.isFinite ? min(1.0, max(0.0, dutyCycle)) : 0.5

        if duty <= 0.0 { return 0.0 }
        if duty >= 1.0 { return 1.0 }

        let soft = softness.isFinite ? min(1.0, max(0.0, softness)) : 0.5
        let edge = 0.5 * duty * soft
        if edge <= 1e-9 {
            return p < duty ? 1.0 : 0.0
        }

        if p < edge {
            return min(1.0, max(0.0, 0.5 * (1.0 - cos(.pi * (p / edge)))))
        } else if p <= duty - edge {
            return 1.0
        } else if p < duty {
            let u = (p - (duty - edge)) / edge
            return min(1.0, max(0.0, 0.5 * (1.0 + cos(.pi * u))))
        } else {
            return 0.0
        }
    }
}
