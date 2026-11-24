import Foundation

/// Entrainment synthesis modes supported by a SynthCore voice.
public enum EntrainmentMode: String, Codable, Sendable, CaseIterable {
    case binaural
    case monaural
    case isochronic
}

/// Carrier oscillator waveforms matching BrainWave Generator shapes.
public enum Waveform: String, Codable, Sendable, CaseIterable {
    case sine
    case sineSquared
    case triangle
    case square
    case smoothSquare
}

/// Interpolation mode between adjacent points of an automation curve.
public enum CurveInterpolation: String, Codable, Sendable, CaseIterable {
    case linear
    case smoothStep
}

/// Single timestamped control point in a parameter automation curve.
public struct CurvePoint: Codable, Sendable, Equatable {
    public var timeSec: Double
    public var value: Double

    public init(timeSec: Double, value: Double) {
        self.timeSec = timeSec
        self.value = value
    }
}

/// Sanitized, monotonically ordered curve ready for real-time evaluation.
public struct CompiledCurve: Sendable, Equatable {
    public let points: [CurvePoint]
    public let interpolation: CurveInterpolation

    public init(points: [CurvePoint], interpolation: CurveInterpolation) {
        self.interpolation = interpolation

        var indexedValid: [(index: Int, point: CurvePoint)] = []
        indexedValid.reserveCapacity(points.count)

        for (index, point) in points.enumerated() {
            guard point.timeSec.isFinite, point.value.isFinite else {
                continue
            }
            let clampedTime = point.timeSec <= 0.0 ? 0.0 : point.timeSec
            indexedValid.append((index, CurvePoint(timeSec: clampedTime, value: point.value)))
        }

        indexedValid.sort { lhs, rhs in
            if lhs.point.timeSec != rhs.point.timeSec {
                return lhs.point.timeSec < rhs.point.timeSec
            }
            return lhs.index < rhs.index
        }

        var collapsed: [CurvePoint] = []
        collapsed.reserveCapacity(indexedValid.count)
        for item in indexedValid {
            if let last = collapsed.last, last.timeSec == item.point.timeSec {
                collapsed[collapsed.count - 1] = item.point
            } else {
                collapsed.append(item.point)
            }
        }

        if collapsed.isEmpty {
            self.points = [CurvePoint(timeSec: 0.0, value: 0.0)]
        } else {
            self.points = collapsed
        }
    }

    public func evaluate(at timeSec: Double) -> Double {
        guard !points.isEmpty else { return 0.0 }
        guard timeSec.isFinite else {
            if timeSec == .infinity {
                return points[points.count - 1].value
            }
            return points[0].value
        }

        if timeSec <= points[0].timeSec {
            return points[0].value
        }
        let lastIndex = points.count - 1
        if timeSec >= points[lastIndex].timeSec {
            return points[lastIndex].value
        }

        var lo = 0
        var hi = lastIndex
        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2
            if points[mid].timeSec <= timeSec {
                lo = mid
            } else {
                hi = mid
            }
        }

        let p0 = points[lo]
        let p1 = points[lo + 1]
        let dt = p1.timeSec - p0.timeSec
        guard dt > 0.0 else { return p1.value }

        let rawU = (timeSec - p0.timeSec) / dt
        let u = rawU.isFinite ? min(1.0, max(0.0, rawU)) : 1.0
        let weight: Double
        switch interpolation {
        case .linear:
            weight = u
        case .smoothStep:
            weight = u * u * (3.0 - 2.0 * u)
        }

        if p0.value == p1.value {
            return p0.value
        }
        return p0.value * (1.0 - weight) + p1.value * weight
    }
}
