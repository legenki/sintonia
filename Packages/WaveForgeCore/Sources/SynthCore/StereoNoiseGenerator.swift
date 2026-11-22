/// Deterministic, real-time safe 256-bit xoshiro256** PRNG seeded via SplitMix64.
public struct Xoshiro256StarStar: Sendable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    public init(seed: UInt64) {
        var splitState = seed
        let v0 = Self.splitMix64(&splitState)
        let v1 = Self.splitMix64(&splitState)
        let v2 = Self.splitMix64(&splitState)
        let v3 = Self.splitMix64(&splitState)

        if (v0 | v1 | v2 | v3) == 0 {
            self.s0 = 0x9E3779B97F4A7C15
            self.s1 = 0xBF58476D1CE4E5B9
            self.s2 = 0x94D049BB133111EB
            self.s3 = 0x517CC1B727220A95
        } else {
            self.s0 = v0
            self.s1 = v1
            self.s2 = v2
            self.s3 = v3
        }
    }

    /// Returns a uniformly distributed double in `[0.0, 1.0)`.
    public mutating func nextUnitDouble() -> Double {
        Double(nextUInt64() >> 11) * 0x1.0p-53
    }

    @inline(__always)
    private mutating func nextUInt64() -> UInt64 {
        let result = Self.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17

        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Self.rotl(s3, 45)

        return result
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    private static func splitMix64(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private struct MonoNoiseChannel: Sendable {
    // Empirically calibrated RMS gain factors matching white -> pink -> brown (~0.128 RMS).
    private static let whiteGain = 0.220
    private static let pinkGain = 0.088
    private static let brownGain = 0.780
    // Subsonic DC blocker (~45 Hz @ 48 kHz) removing inaudible sub-bass drift and preserving headroom.
    private static let dcBlockerCoeff = 0.994

    private var rng: Xoshiro256StarStar
    private var b0: Double = 0.0
    private var b1: Double = 0.0
    private var b2: Double = 0.0
    private var b3: Double = 0.0
    private var b4: Double = 0.0
    private var b5: Double = 0.0
    private var b6: Double = 0.0
    private var brown: Double = 0.0
    private var dcPrevIn: Double = 0.0
    private var dcPrevOut: Double = 0.0

    init(seed: UInt64) {
        self.rng = Xoshiro256StarStar(seed: seed)
    }

    mutating func nextSample(smoothness: Double) -> Double {
        let white = rng.nextUnitDouble() * 2.0 - 1.0

        // Paul Kellet's 6-stage -3 dB/oct pink noise filter
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926

        // Leaky-integrator brown noise filter
        brown = 0.996 * brown + 0.04 * white

        let wScaled = white * Self.whiteGain
        let pScaled = pink * Self.pinkGain
        let bScaled = brown * Self.brownGain

        let s = smoothness.isFinite ? min(1.0, max(0.0, smoothness)) : 0.5
        let mixed: Double
        if s <= 0.5 {
            let t = s * 2.0
            mixed = wScaled * (1.0 - t) + pScaled * t
        } else {
            let t = (s - 0.5) * 2.0
            mixed = pScaled * (1.0 - t) + bScaled * t
        }

        let highPassed = mixed - dcPrevIn + Self.dcBlockerCoeff * dcPrevOut
        dcPrevIn = mixed
        dcPrevOut = highPassed
        return highPassed
    }
}

/// Independent dual-channel colored noise generator (white -> pink -> brown).
public struct StereoNoiseGenerator: Sendable {
    private var left: MonoNoiseChannel
    private var right: MonoNoiseChannel

    public init(leftSeed: UInt64, rightSeed: UInt64) {
        self.left = MonoNoiseChannel(seed: leftSeed)
        self.right = MonoNoiseChannel(seed: rightSeed)
    }

    public mutating func nextSample(smoothness: Double) -> (left: Double, right: Double) {
        let l = left.nextSample(smoothness: smoothness)
        let r = right.nextSample(smoothness: smoothness)
        return (l, r)
    }
}
