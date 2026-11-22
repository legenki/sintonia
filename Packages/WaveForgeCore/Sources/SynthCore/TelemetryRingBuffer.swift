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

private struct TelemetryPODSlot {
    let leftSamples: UnsafeMutablePointer<Float>
    let rightSamples: UnsafeMutablePointer<Float>
    var rmsL: Float
    var rmsR: Float
    var peakL: Float
    var peakR: Float
}

/// Wait-free 3-slot POD triple-buffered storage for zero-allocation SPSC audio telemetry.
internal struct TelemetryStorage: ~Copyable {
    static let capacity = TelemetryFrame.capacity
    private static let mask = capacity - 1
    private static let slotCount = 3

    // Private rolling 1024-frame ring owned exclusively by the audio writer (`push`).
    private let writerLeft: UnsafeMutablePointer<Float>
    private let writerRight: UnsafeMutablePointer<Float>
    private let writerHead = Atomic<Int>(0)

    // Pre-allocated 3-slot POD triple buffer swapped via `middleState` with `.acquiringAndReleasing`.
    private let slots: UnsafeMutablePointer<TelemetryPODSlot>
    private let middleState = Atomic<Int>(2) // (dirtyBit << 2) | slotIndex -> clean, slot 2
    private let producerIndex = Atomic<Int>(1) // Owned exclusively by `push`.
    private let readerIndex = Atomic<Int>(0)   // Owned exclusively by `readLatest` under `readerLock`.
    private let readerLock = Atomic<Bool>(false) // Non-audio reader guard only; `push` never touches this.

    init() {
        let wL = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        wL.initialize(repeating: 0.0, count: Self.capacity)
        let wR = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        wR.initialize(repeating: 0.0, count: Self.capacity)
        self.writerLeft = wL
        self.writerRight = wR

        let allocatedSlots = UnsafeMutablePointer<TelemetryPODSlot>.allocate(capacity: Self.slotCount)
        for i in 0..<Self.slotCount {
            let lBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
            lBuf.initialize(repeating: 0.0, count: Self.capacity)
            let rBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
            rBuf.initialize(repeating: 0.0, count: Self.capacity)
            (allocatedSlots + i).initialize(
                to: TelemetryPODSlot(
                    leftSamples: lBuf,
                    rightSamples: rBuf,
                    rmsL: 0.0,
                    rmsR: 0.0,
                    peakL: 0.0,
                    peakR: 0.0
                )
            )
        }
        self.slots = allocatedSlots
    }

    deinit {
        writerLeft.deinitialize(count: Self.capacity)
        writerLeft.deallocate()
        writerRight.deinitialize(count: Self.capacity)
        writerRight.deallocate()

        for i in 0..<Self.slotCount {
            slots[i].leftSamples.deinitialize(count: Self.capacity)
            slots[i].leftSamples.deallocate()
            slots[i].rightSamples.deinitialize(count: Self.capacity)
            slots[i].rightSamples.deallocate()
        }
        slots.deinitialize(count: Self.slotCount)
        slots.deallocate()
    }

    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        let startIndex = count > Self.capacity ? (count - Self.capacity) : 0
        let sampleCount = count - startIndex

        var head = writerHead.load(ordering: .relaxed) & Self.mask
        var sumSqL = 0.0
        var sumSqR = 0.0
        var maxPeakL: Float = 0.0
        var maxPeakR: Float = 0.0

        for i in startIndex..<count {
            let rawL = left[i]
            let rawR = right[i]
            let sL: Float = rawL.isFinite ? rawL : 0.0
            let sR: Float = rawR.isFinite ? rawR : 0.0

            writerLeft[head] = sL
            writerRight[head] = sR
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

        writerHead.store(head, ordering: .relaxed)

        let invN = 1.0 / Double(sampleCount)
        let rmsL = Float((sumSqL * invN).squareRoot())
        let rmsR = Float((sumSqR * invN).squareRoot())

        // Linearize the chronological 1024-frame history into the private producer slot.
        let prodIdx = producerIndex.load(ordering: .relaxed)
        let tailCount = Self.capacity - head
        let dstL = slots[prodIdx].leftSamples
        let dstR = slots[prodIdx].rightSamples

        dstL.update(from: writerLeft + head, count: tailCount)
        dstR.update(from: writerRight + head, count: tailCount)
        if head > 0 {
            (dstL + tailCount).update(from: writerLeft, count: head)
            (dstR + tailCount).update(from: writerRight, count: head)
        }

        slots[prodIdx].rmsL = rmsL.isFinite ? rmsL : 0.0
        slots[prodIdx].rmsR = rmsR.isFinite ? rmsR : 0.0
        slots[prodIdx].peakL = maxPeakL.isFinite ? maxPeakL : 0.0
        slots[prodIdx].peakR = maxPeakR.isFinite ? maxPeakR : 0.0

        // Publish completed slot to consumer with acquire-release happens-before synchronization.
        let prevMiddle = middleState.exchange((1 << 2) | prodIdx, ordering: .acquiringAndReleasing)
        producerIndex.store(prevMiddle & 0b11, ordering: .relaxed)
    }

    func readLatest(into frame: inout TelemetryFrame) {
        if frame.leftSamples.count != Self.capacity {
            frame.leftSamples = [Float](repeating: 0, count: Self.capacity)
        }
        if frame.rightSamples.count != Self.capacity {
            frame.rightSamples = [Float](repeating: 0, count: Self.capacity)
        }

        while readerLock.exchange(true, ordering: .acquiring) {
            // Reader-only atomic guard; the audio thread (`push`) never touches this.
        }
        defer { readerLock.store(false, ordering: .releasing) }

        var readIdx = readerIndex.load(ordering: .relaxed)
        let currentMiddle = middleState.load(ordering: .relaxed)
        if (currentMiddle & 0b100) != 0 {
            let swapped = middleState.exchange(readIdx, ordering: .acquiringAndReleasing)
            readIdx = swapped & 0b11
            readerIndex.store(readIdx, ordering: .relaxed)
        }

        let slot = slots[readIdx]
        frame.leftSamples.withUnsafeMutableBufferPointer { dstL in
            dstL.baseAddress?.update(from: slot.leftSamples, count: Self.capacity)
        }
        frame.rightSamples.withUnsafeMutableBufferPointer { dstR in
            dstR.baseAddress?.update(from: slot.rightSamples, count: Self.capacity)
        }
        frame.rmsL = slot.rmsL
        frame.rmsR = slot.rmsR
        frame.peakL = slot.peakL
        frame.peakR = slot.peakR
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
