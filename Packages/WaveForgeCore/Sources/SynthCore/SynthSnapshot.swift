import Foundation
import Synchronization

/// Brainwave frequency bands mapped from entrainment beat frequencies.
public enum BrainwaveBand: String, Sendable, CaseIterable {
    case delta
    case theta
    case alpha
    case beta
    case gamma

    /// Classifies a beat frequency in Hz into its canonical brainwave band.
    public static func from(frequencyHz: Double) -> BrainwaveBand {
        guard frequencyHz.isFinite else {
            return frequencyHz == .infinity ? .gamma : .delta
        }
        if frequencyHz < 4.0 {
            return .delta
        } else if frequencyHz < 8.0 {
            return .theta
        } else if frequencyHz < 13.0 {
            return .alpha
        } else if frequencyHz < 30.0 {
            return .beta
        } else {
            return .gamma
        }
    }
}

/// Immutable real-time snapshot of a single synthesis voice with resolved curves.
public struct VoiceSnapshot: Sendable, Equatable {
    public var id: UUID
    public var isEnabled: Bool
    public var isMuted: Bool
    public var isSolo: Bool
    public var mode: EntrainmentMode
    public var waveform: Waveform
    public var isochronicSoftness: Double
    public var isochronicDutyCycle: Double
    public var pan: Double
    public var carrierCurve: CompiledCurve
    public var beatCurve: CompiledCurve
    public var volumeCurve: CompiledCurve

    public init(
        id: UUID,
        isEnabled: Bool,
        isMuted: Bool,
        isSolo: Bool,
        mode: EntrainmentMode,
        waveform: Waveform,
        isochronicSoftness: Double,
        isochronicDutyCycle: Double,
        pan: Double,
        carrierCurve: CompiledCurve,
        beatCurve: CompiledCurve,
        volumeCurve: CompiledCurve
    ) {
        self.id = id
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
    }
}

/// Immutable real-time snapshot of the stereo colored noise layer.
public struct NoiseSnapshot: Sendable, Equatable {
    public var isEnabled: Bool
    public var volumeCurve: CompiledCurve
    public var smoothnessCurve: CompiledCurve
    public var pulseEnabled: Bool
    public var pulseDepth: Double
    public var pulseSourceVoiceIndex: Int?

    public init(
        isEnabled: Bool,
        volumeCurve: CompiledCurve,
        smoothnessCurve: CompiledCurve,
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
    public static let disabled = NoiseSnapshot(
        isEnabled: false,
        volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.0)], interpolation: .linear),
        smoothnessCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.5)], interpolation: .linear),
        pulseEnabled: false,
        pulseDepth: 0.0,
        pulseSourceVoiceIndex: nil
    )
}

/// Complete session configuration snapshot passed to `SynthRenderer` (up to 10 voices).
public struct SynthSnapshot: Sendable, Equatable {
    public static let maxVoices = 10

    public var durationSec: Double
    public var masterGain: Double
    public var fadeInSec: Double
    public var fadeOutSec: Double
    public var noise: NoiseSnapshot
    public var voices: [VoiceSnapshot]

    public init(
        durationSec: Double,
        masterGain: Double,
        fadeInSec: Double,
        fadeOutSec: Double,
        noise: NoiseSnapshot,
        voices: [VoiceSnapshot]
    ) {
        self.durationSec = durationSec
        self.masterGain = masterGain
        self.fadeInSec = fadeInSec
        self.fadeOutSec = fadeOutSec
        self.noise = noise
        self.voices = voices.count > Self.maxVoices ? Array(voices.prefix(Self.maxVoices)) : voices
    }

    /// Evaluates the loudest audible voice's beat frequency at `timeSec`.
    public func dominantBeatHz(at timeSec: Double) -> Double {
        let hasSolo = voices.contains { $0.isEnabled && $0.isSolo }
        var found = false
        var bestVolume = -Double.infinity
        var bestBeat = 0.0

        for v in voices where v.isEnabled && !v.isMuted && (!hasSolo || v.isSolo) {
            let rawVol = v.volumeCurve.evaluate(at: timeSec)
            let vol = rawVol.isFinite ? min(1.0, max(0.0, rawVol)) : 0.0
            let rawBeat = v.beatCurve.evaluate(at: timeSec)
            let beat = rawBeat.isFinite ? max(0.0, rawBeat) : 0.0
            if !found || vol > bestVolume {
                found = true
                bestVolume = vol
                bestBeat = beat
            }
        }
        return bestBeat
    }
}

/// Real-time performance multipliers and noise color offset controlled from the player UI.
public struct LiveOverrides: Sendable, Equatable {
    public var masterGain: Double
    public var tonesGain: Double
    public var noiseGain: Double
    public var noiseSmoothnessOffset: Double

    /// Neutral overrides leaving preset levels and noise color unmodified.
    public static let identity = LiveOverrides()

    public init(
        masterGain: Double = 1.0,
        tonesGain: Double = 1.0,
        noiseGain: Double = 1.0,
        noiseSmoothnessOffset: Double = 0.0
    ) {
        self.masterGain = masterGain
        self.tonesGain = tonesGain
        self.noiseGain = noiseGain
        self.noiseSmoothnessOffset = noiseSmoothnessOffset
    }
}

// MARK: - Lock-Free POD Snapshot Channel

internal struct PODCurvePoint {
    var timeSec: Double
    var value: Double
}

internal struct PODCurveHeader {
    var offset: Int
    var count: Int
    var interpolationRaw: UInt8

    @inline(__always)
    func evaluate(at timeSec: Double, points: UnsafePointer<PODCurvePoint>) -> Double {
        guard count > 0 else { return 0.0 }
        let first = points[offset]
        let lastIndex = count - 1
        let last = points[offset + lastIndex]

        guard timeSec.isFinite else {
            return timeSec == .infinity ? last.value : first.value
        }
        if timeSec <= first.timeSec {
            return first.value
        }
        if timeSec >= last.timeSec {
            return last.value
        }

        var lo = 0
        var hi = lastIndex
        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2
            if points[offset + mid].timeSec <= timeSec {
                lo = mid
            } else {
                hi = mid
            }
        }

        let p0 = points[offset + lo]
        let p1 = points[offset + lo + 1]
        let dt = p1.timeSec - p0.timeSec
        guard dt > 0.0 else { return p1.value }

        let rawU = (timeSec - p0.timeSec) / dt
        let u = rawU.isFinite ? min(1.0, max(0.0, rawU)) : 1.0
        let weight = interpolationRaw == 1 ? (u * u * (3.0 - 2.0 * u)) : u

        if p0.value == p1.value {
            return p0.value
        }
        return p0.value * (1.0 - weight) + p1.value * weight
    }
}

internal struct PODVoice {
    var isEnabled: Bool
    var isMuted: Bool
    var isSolo: Bool
    var modeRaw: UInt8
    var waveformRaw: UInt8
    var isochronicSoftness: Double
    var isochronicDutyCycle: Double
    var pan: Double
    var carrierCurve: PODCurveHeader
    var beatCurve: PODCurveHeader
    var volumeCurve: PODCurveHeader

    @inline(__always)
    var mode: EntrainmentMode {
        switch modeRaw {
        case 0: return .binaural
        case 1: return .monaural
        default: return .isochronic
        }
    }

    @inline(__always)
    var waveform: Waveform {
        switch waveformRaw {
        case 0: return .sine
        case 1: return .sineSquared
        case 2: return .triangle
        case 3: return .square
        default: return .smoothSquare
        }
    }
}

internal struct PODNoise {
    var isEnabled: Bool
    var volumeCurve: PODCurveHeader
    var smoothnessCurve: PODCurveHeader
    var pulseEnabled: Bool
    var pulseDepth: Double
    var pulseSourceVoiceIndex: Int
}

internal struct PODSnapshotSlot {
    var resetGeneration: UInt64
    var resetSeekSeq: UInt64
    var durationSec: Double
    var masterGain: Double
    var fadeInSec: Double
    var fadeOutSec: Double
    var voiceCount: Int
    var noise: PODNoise
    let voices: UnsafeMutablePointer<PODVoice>
    let curvePoints: UnsafeMutablePointer<PODCurvePoint>

    @inline(__always)
    func hasActiveSoloVoice() -> Bool {
        for i in 0..<voiceCount {
            let v = voices[i]
            if v.isEnabled && v.isSolo {
                return true
            }
        }
        return false
    }

    @inline(__always)
    func isVoiceAudible(_ index: Int, hasSolo: Bool) -> Bool {
        let v = voices[index]
        return v.isEnabled && !v.isMuted && (!hasSolo || v.isSolo)
    }

    func dominantBeatHz(at timeSec: Double) -> Double {
        let hasSolo = hasActiveSoloVoice()

        var found = false
        var bestVolume = -Double.infinity
        var bestBeat = 0.0

        for i in 0..<voiceCount {
            guard isVoiceAudible(i, hasSolo: hasSolo) else { continue }
            let v = voices[i]
            let rawVol = v.volumeCurve.evaluate(at: timeSec, points: curvePoints)
            let vol = rawVol.isFinite ? min(1.0, max(0.0, rawVol)) : 0.0
            let rawBeat = v.beatCurve.evaluate(at: timeSec, points: curvePoints)
            let beat = rawBeat.isFinite ? max(0.0, rawBeat) : 0.0
            if !found || vol > bestVolume {
                found = true
                bestVolume = vol
                bestBeat = beat
            }
        }
        return bestBeat
    }
}

/// Wait-free triple-buffered POD snapshot channel for real-time audio rendering.
internal struct SnapshotChannel: ~Copyable {
    static let maxVoices = SynthSnapshot.maxVoices
    static let maxPointsPerCurve = 512
    private static let curvesPerSnapshot = maxVoices * 3 + 2
    private static let pointsCapacityPerSlot = curvesPerSnapshot * maxPointsPerCurve
    private static let totalSlots = 4 // 0..2 triple-buffer slots + 3 UI query slot

    private let slots: UnsafeMutablePointer<PODSnapshotSlot>
    private let middleState: Atomic<Int>
    private let producerLock: Atomic<Bool>
    private let latestDurationBits: Atomic<UInt64>

    // Owned exclusively by producer under `producerLock`; stored in Atomic for non-mutating access.
    private let producerIndex: Atomic<Int>
    private let latestResetGeneration = Atomic<UInt64>(0)
    private let latestResetSeekSeq = Atomic<UInt64>(0)
    // Owned exclusively by the audio render thread; stored in Atomic for non-mutating access.
    private let audioIndex: Atomic<Int>

    init(initial: SynthSnapshot) {
        let allocatedSlots = UnsafeMutablePointer<PODSnapshotSlot>.allocate(capacity: Self.totalSlots)
        let defaultNoise = PODNoise(
            isEnabled: false,
            volumeCurve: PODCurveHeader(offset: 0, count: 1, interpolationRaw: 0),
            smoothnessCurve: PODCurveHeader(offset: 0, count: 1, interpolationRaw: 0),
            pulseEnabled: false,
            pulseDepth: 0.0,
            pulseSourceVoiceIndex: -1
        )
        for i in 0..<Self.totalSlots {
            let voicesPtr = UnsafeMutablePointer<PODVoice>.allocate(capacity: Self.maxVoices)
            voicesPtr.initialize(
                repeating: PODVoice(
                    isEnabled: false,
                    isMuted: false,
                    isSolo: false,
                    modeRaw: 0,
                    waveformRaw: 0,
                    isochronicSoftness: 0.5,
                    isochronicDutyCycle: 0.5,
                    pan: 0.0,
                    carrierCurve: PODCurveHeader(offset: 0, count: 1, interpolationRaw: 0),
                    beatCurve: PODCurveHeader(offset: 0, count: 1, interpolationRaw: 0),
                    volumeCurve: PODCurveHeader(offset: 0, count: 1, interpolationRaw: 0)
                ),
                count: Self.maxVoices
            )
            let pointsPtr = UnsafeMutablePointer<PODCurvePoint>.allocate(capacity: Self.pointsCapacityPerSlot)
            pointsPtr.initialize(repeating: PODCurvePoint(timeSec: 0.0, value: 0.0), count: Self.pointsCapacityPerSlot)
            (allocatedSlots + i).initialize(
                to: PODSnapshotSlot(
                    resetGeneration: 0,
                    resetSeekSeq: 0,
                    durationSec: 0.0,
                    masterGain: 1.0,
                    fadeInSec: 0.0,
                    fadeOutSec: 0.0,
                    voiceCount: 0,
                    noise: defaultNoise,
                    voices: voicesPtr,
                    curvePoints: pointsPtr
                )
            )
        }

        self.slots = allocatedSlots
        self.middleState = Atomic<Int>(2) // dirty = 0, index = 2
        self.producerLock = Atomic<Bool>(false)
        self.producerIndex = Atomic<Int>(1)
        self.audioIndex = Atomic<Int>(0)
        let safeDuration = Self.sanitizeDuration(initial.durationSec)
        self.latestDurationBits = Atomic<UInt64>(safeDuration.bitPattern)

        // Populate initial audio slot (0), middle slot (2), and UI mirror slot (3).
        Self.pack(snapshot: initial, into: allocatedSlots + 0)
        Self.pack(snapshot: initial, into: allocatedSlots + 2)
        Self.pack(snapshot: initial, into: allocatedSlots + 3)
    }

    deinit {
        for i in 0..<Self.totalSlots {
            slots[i].voices.deinitialize(count: Self.maxVoices)
            slots[i].voices.deallocate()
            slots[i].curvePoints.deinitialize(count: Self.pointsCapacityPerSlot)
            slots[i].curvePoints.deallocate()
        }
        slots.deinitialize(count: Self.totalSlots)
        slots.deallocate()
    }

    /// Returns the initial slot pointer for audio-thread initialization before rendering begins.
    func initialAudioSlot() -> UnsafePointer<PODSnapshotSlot> {
        UnsafePointer(slots + audioIndex.load(ordering: .relaxed))
    }

    /// Publishes a new snapshot from caller/UI thread without blocking the audio thread.
    /// When `sessionResetSeekSeq` is provided, increments the atomic session-reset generation
    /// so the audio thread performs a clean zero-click reset on the next render block.
    func publish(_ snapshot: SynthSnapshot, sessionResetSeekSeq: UInt64? = nil) {
        acquireProducerLock()
        defer { producerLock.store(false, ordering: .releasing) }

        var resetGen = latestResetGeneration.load(ordering: .relaxed)
        var resetSeekSeq = latestResetSeekSeq.load(ordering: .relaxed)
        if let seekSeq = sessionResetSeekSeq {
            resetGen &+= 1
            resetSeekSeq = seekSeq
            latestResetGeneration.store(resetGen, ordering: .relaxed)
            latestResetSeekSeq.store(resetSeekSeq, ordering: .relaxed)
        }

        let currentProducer = producerIndex.load(ordering: .relaxed)
        Self.pack(snapshot: snapshot, into: slots + currentProducer)
        (slots + currentProducer).pointee.resetGeneration = resetGen
        (slots + currentProducer).pointee.resetSeekSeq = resetSeekSeq
        Self.pack(snapshot: snapshot, into: slots + 3)
        (slots + 3).pointee.resetGeneration = resetGen
        (slots + 3).pointee.resetSeekSeq = resetSeekSeq

        let safeDuration = Self.sanitizeDuration(snapshot.durationSec)
        latestDurationBits.store(safeDuration.bitPattern, ordering: .releasing)

        let prevMiddle = middleState.exchange((1 << 2) | currentProducer, ordering: .acquiringAndReleasing)
        producerIndex.store(prevMiddle & 0b11, ordering: .relaxed)
    }

    /// Wait-free audio-thread slot check; swaps to newly published POD slot if dirty.
    @inline(__always)
    func acquireAudioSlotIfUpdated() -> (slot: UnsafePointer<PODSnapshotSlot>, didSwap: Bool) {
        let currentAudio = audioIndex.load(ordering: .relaxed)
        let currentMiddle = middleState.load(ordering: .relaxed)
        if (currentMiddle & 0b100) != 0 {
            let swapped = middleState.exchange(currentAudio, ordering: .acquiringAndReleasing)
            let nextAudio = swapped & 0b11
            audioIndex.store(nextAudio, ordering: .relaxed)
            return (UnsafePointer(slots + nextAudio), true)
        }
        return (UnsafePointer(slots + currentAudio), false)
    }

    /// Returns latest snapshot duration atomically for seek clamping.
    func latestDurationSec() -> Double {
        Double(bitPattern: latestDurationBits.load(ordering: .acquiring))
    }

    /// Evaluates the dominant beat frequency on caller/UI threads without touching audio-thread state.
    func dominantBeatHz(at timeSec: Double) -> Double {
        acquireProducerLock()
        defer { producerLock.store(false, ordering: .releasing) }
        return slots[3].dominantBeatHz(at: timeSec)
    }

    private func acquireProducerLock() {
        while producerLock.exchange(true, ordering: .acquiring) {
            // Producer-only atomic spin; the real-time audio thread never calls this.
        }
    }

    private static func sanitizeDuration(_ value: Double) -> Double {
        value.isFinite ? max(0.0, value) : 0.0
    }

    private static func sanitizeNonNegative(_ value: Double) -> Double {
        value.isFinite ? max(0.0, value) : 0.0
    }

    private static func sanitizeUnit(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1.0, max(0.0, value)) : fallback
    }

    private static func sanitizePan(_ value: Double) -> Double {
        value.isFinite ? min(1.0, max(-1.0, value)) : 0.0
    }

    private static func pack(snapshot: SynthSnapshot, into dst: UnsafeMutablePointer<PODSnapshotSlot>) {
        let voiceCount = min(maxVoices, snapshot.voices.count)
        dst.pointee.durationSec = sanitizeDuration(snapshot.durationSec)
        dst.pointee.masterGain = sanitizeUnit(snapshot.masterGain, fallback: 1.0)
        dst.pointee.fadeInSec = sanitizeNonNegative(snapshot.fadeInSec)
        dst.pointee.fadeOutSec = sanitizeNonNegative(snapshot.fadeOutSec)
        dst.pointee.voiceCount = voiceCount

        let pointsBuf = dst.pointee.curvePoints
        var nextCurveSlot = 0

        for i in 0..<voiceCount {
            let v = snapshot.voices[i]
            let carrierHdr = packCurve(v.carrierCurve, into: pointsBuf, curveSlot: nextCurveSlot)
            nextCurveSlot += 1
            let beatHdr = packCurve(v.beatCurve, into: pointsBuf, curveSlot: nextCurveSlot)
            nextCurveSlot += 1
            let volumeHdr = packCurve(v.volumeCurve, into: pointsBuf, curveSlot: nextCurveSlot)
            nextCurveSlot += 1

            dst.pointee.voices[i] = PODVoice(
                isEnabled: v.isEnabled,
                isMuted: v.isMuted,
                isSolo: v.isSolo,
                modeRaw: encodeMode(v.mode),
                waveformRaw: encodeWaveform(v.waveform),
                isochronicSoftness: v.isochronicSoftness.isFinite ? min(1.0, max(0.05, v.isochronicSoftness)) : 0.5,
                isochronicDutyCycle: v.isochronicDutyCycle.isFinite ? min(1.0, max(0.0, v.isochronicDutyCycle)) : 0.5,
                pan: sanitizePan(v.pan),
                carrierCurve: carrierHdr,
                beatCurve: beatHdr,
                volumeCurve: volumeHdr
            )
        }

        let noiseVolHdr = packCurve(snapshot.noise.volumeCurve, into: pointsBuf, curveSlot: maxVoices * 3)
        let noiseSmoothHdr = packCurve(snapshot.noise.smoothnessCurve, into: pointsBuf, curveSlot: maxVoices * 3 + 1)
        let sourceIdx = snapshot.noise.pulseSourceVoiceIndex ?? -1

        dst.pointee.noise = PODNoise(
            isEnabled: snapshot.noise.isEnabled,
            volumeCurve: noiseVolHdr,
            smoothnessCurve: noiseSmoothHdr,
            pulseEnabled: snapshot.noise.pulseEnabled,
            pulseDepth: sanitizeUnit(snapshot.noise.pulseDepth, fallback: 0.0),
            pulseSourceVoiceIndex: sourceIdx
        )
    }

    private static func packCurve(
        _ curve: CompiledCurve,
        into pointsBuf: UnsafeMutablePointer<PODCurvePoint>,
        curveSlot: Int
    ) -> PODCurveHeader {
        let offset = curveSlot * maxPointsPerCurve
        let interpRaw: UInt8 = curve.interpolation == .smoothStep ? 1 : 0
        let src = curve.points

        if src.isEmpty {
            pointsBuf[offset] = PODCurvePoint(timeSec: 0.0, value: 0.0)
            return PODCurveHeader(offset: offset, count: 1, interpolationRaw: interpRaw)
        }

        if src.count <= maxPointsPerCurve {
            for idx in 0..<src.count {
                let p = src[idx]
                pointsBuf[offset + idx] = PODCurvePoint(
                    timeSec: p.timeSec.isFinite ? p.timeSec : 0.0,
                    value: p.value.isFinite ? p.value : 0.0
                )
            }
            return PODCurveHeader(offset: offset, count: src.count, interpolationRaw: interpRaw)
        }

        // Resample curves exceeding maxPointsPerCurve uniformly across their full time span.
        let tStart = src[0].timeSec
        let tEnd = src[src.count - 1].timeSec
        if tEnd <= tStart {
            let v = src[src.count - 1].value
            pointsBuf[offset] = PODCurvePoint(timeSec: tStart, value: v.isFinite ? v : 0.0)
            return PODCurveHeader(offset: offset, count: 1, interpolationRaw: interpRaw)
        }

        let denom = Double(maxPointsPerCurve - 1)
        let span = tEnd - tStart
        for idx in 0..<maxPointsPerCurve {
            let t = idx == (maxPointsPerCurve - 1) ? tEnd : (tStart + (Double(idx) / denom) * span)
            let v = curve.evaluate(at: t)
            pointsBuf[offset + idx] = PODCurvePoint(timeSec: t, value: v.isFinite ? v : 0.0)
        }
        // Force linear interpolation on uniformly resampled curves to avoid double smoothStep distortion.
        return PODCurveHeader(offset: offset, count: maxPointsPerCurve, interpolationRaw: 0)
    }

    private static func encodeMode(_ mode: EntrainmentMode) -> UInt8 {
        switch mode {
        case .binaural: return 0
        case .monaural: return 1
        case .isochronic: return 2
        }
    }

    private static func encodeWaveform(_ waveform: Waveform) -> UInt8 {
        switch waveform {
        case .sine: return 0
        case .sineSquared: return 1
        case .triangle: return 2
        case .square: return 3
        case .smoothSquare: return 4
        }
    }
}
