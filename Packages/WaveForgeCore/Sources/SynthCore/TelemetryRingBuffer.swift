import Synchronization

/// Latest 1024-frame stereo telemetry snapshot and instantaneous RMS/peak levels for UI metering.
public struct TelemetryFrame: Sendable, Equatable {
    public static let capacity = 1024

    public var leftSamples: [Float]
    public var rightSamples: [Float]
    public var rmsL: Float
    public var rmsR: Float
    public var peakL: Float
    public var peakR: Float

    public init(
        leftSamples: [Float] = [Float](repeating: 0, count: TelemetryFrame.capacity),
        rightSamples: [Float] = [Float](repeating: 0, count: TelemetryFrame.capacity),
        rmsL: Float = 0,
        rmsR: Float = 0,
        peakL: Float = 0,
        peakR: Float = 0
    ) {
        self.leftSamples = leftSamples
        self.rightSamples = rightSamples
        self.rmsL = rmsL
        self.rmsR = rmsR
        self.peakL = peakL
        self.peakR = peakR
    }
}

internal struct TelemetryStorage: ~Copyable {
    static let capacity = TelemetryFrame.capacity
    private static let mask = capacity - 1

    private let leftRing: UnsafeMutablePointer<Atomic<UInt32>>
    private let rightRing: UnsafeMutablePointer<Atomic<UInt32>>
    private let writeHead = Atomic<Int>(0)
    private let sequence = Atomic<UInt64>(0)
    private let rmsLBits = Atomic<UInt32>(0)
    private let rmsRBits = Atomic<UInt32>(0)
    private let peakLBits = Atomic<UInt32>(0)
    private let peakRBits = Atomic<UInt32>(0)

    init() {
        let lPtr = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: Self.capacity)
        let rPtr = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: Self.capacity)
        for i in 0..<Self.capacity {
            (lPtr + i).initialize(to: Atomic<UInt32>(0))
            (rPtr + i).initialize(to: Atomic<UInt32>(0))
        }
        self.leftRing = lPtr
        self.rightRing = rPtr
    }

    deinit {
        leftRing.deinitialize(count: Self.capacity)
        leftRing.deallocate()
        rightRing.deinitialize(count: Self.capacity)
        rightRing.deallocate()
    }

    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        let startIndex = count > Self.capacity ? (count - Self.capacity) : 0
        let sampleCount = count - startIndex

        let seqStart = sequence.load(ordering: .relaxed)
        _ = sequence.exchange(seqStart &+ 1, ordering: .acquiringAndReleasing)

        var head = writeHead.load(ordering: .relaxed) & Self.mask
        var sumSqL = 0.0
        var sumSqR = 0.0
        var maxPeakL: Float = 0.0
        var maxPeakR: Float = 0.0

        for i in startIndex..<count {
            let rawL = left[i]
            let rawR = right[i]
            let sL: Float = rawL.isFinite ? rawL : 0.0
            let sR: Float = rawR.isFinite ? rawR : 0.0

            (leftRing + head).pointee.store(sL.bitPattern, ordering: .relaxed)
            (rightRing + head).pointee.store(sR.bitPattern, ordering: .relaxed)
            head = (head + 1) & Self.mask

            let dL = Double(sL)
            let dR = Double(sR)
            sumSqL += dL * dL
            sumSqR += dR * dR

            let aL = abs(sL)
            let aR = abs(sR)
            if aL > maxPeakL { maxPeakL = aL }
            if aR > maxPeakR { maxPeakR = aR }
        }

        let invN = 1.0 / Double(sampleCount)
        let rmsL = Float((sumSqL * invN).squareRoot())
        let rmsR = Float((sumSqR * invN).squareRoot())

        writeHead.store(head, ordering: .releasing)
        rmsLBits.store((rmsL.isFinite ? rmsL : 0.0).bitPattern, ordering: .relaxed)
        rmsRBits.store((rmsR.isFinite ? rmsR : 0.0).bitPattern, ordering: .relaxed)
        peakLBits.store((maxPeakL.isFinite ? maxPeakL : 0.0).bitPattern, ordering: .relaxed)
        peakRBits.store((maxPeakR.isFinite ? maxPeakR : 0.0).bitPattern, ordering: .relaxed)

        sequence.store(seqStart &+ 2, ordering: .releasing)
    }

    func readLatest(into frame: inout TelemetryFrame) {
        if frame.leftSamples.count != Self.capacity {
            frame.leftSamples = [Float](repeating: 0, count: Self.capacity)
        }
        if frame.rightSamples.count != Self.capacity {
            frame.rightSamples = [Float](repeating: 0, count: Self.capacity)
        }

        for _ in 0..<8 {
            let s1 = sequence.load(ordering: .acquiring)
            if (s1 & 1) != 0 { continue }

            let head = writeHead.load(ordering: .acquiring) & Self.mask
            let rmsL = Float(bitPattern: rmsLBits.load(ordering: .relaxed))
            let rmsR = Float(bitPattern: rmsRBits.load(ordering: .relaxed))
            let peakL = Float(bitPattern: peakLBits.load(ordering: .relaxed))
            let peakR = Float(bitPattern: peakRBits.load(ordering: .relaxed))

            for i in 0..<Self.capacity {
                let idx = (head + i) & Self.mask
                frame.leftSamples[i] = Float(bitPattern: (leftRing + idx).pointee.load(ordering: .relaxed))
                frame.rightSamples[i] = Float(bitPattern: (rightRing + idx).pointee.load(ordering: .relaxed))
            }

            let fence = Atomic<Int>(0)
            _ = fence.exchange(0, ordering: .acquiringAndReleasing)
            let s2 = sequence.load(ordering: .acquiring)
            if s1 == s2 {
                frame.rmsL = rmsL.isFinite ? rmsL : 0.0
                frame.rmsR = rmsR.isFinite ? rmsR : 0.0
                frame.peakL = peakL.isFinite ? peakL : 0.0
                frame.peakR = peakR.isFinite ? peakR : 0.0
                return
            }
        }
    }
}

/// Lock-free, allocation-free SPSC 1024-frame stereo ring buffer for real-time audio telemetry.
public final class TelemetryRingBuffer: @unchecked Sendable {
    public static let capacity = TelemetryFrame.capacity

    internal let storage: UnsafeMutablePointer<TelemetryStorage>

    public init() {
        let ptr = UnsafeMutablePointer<TelemetryStorage>.allocate(capacity: 1)
        ptr.initialize(to: TelemetryStorage())
        self.storage = ptr
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Pushes stereo audio frames from the real-time audio thread with zero allocations or locks.
    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        storage.pointee.push(left: left, right: right, count: count)
    }

    /// Copies the latest coherent 1024-sample stereo window and meter readings on the UI thread.
    public func readLatest(into frame: inout TelemetryFrame) {
        storage.pointee.readLatest(into: &frame)
    }
}
