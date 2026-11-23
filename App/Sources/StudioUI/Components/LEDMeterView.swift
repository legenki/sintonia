import Foundation
import SwiftUI

/// Orientation axis for `LEDMeterView`.
public enum LEDMeterOrientation: Sendable, Equatable {
    case vertical
    case horizontal
}

@MainActor
private final class PeakHoldTracker {
    private var peakLeft: Double = 0.0
    private var peakRight: Double = 0.0
    private var timestampLeft: TimeInterval = 0.0
    private var timestampRight: TimeInterval = 0.0

    private let holdDuration: TimeInterval = 0.55
    private let decayRatePerSecond: Double = 0.90

    func currentHeld(
        left: Double,
        right: Double,
        now: TimeInterval
    ) -> (left: Double, right: Double, isHolding: Bool) {
        let l = stepChannel(current: left, peak: &peakLeft, timestamp: &timestampLeft, now: now)
        let r = stepChannel(current: right, peak: &peakRight, timestamp: &timestampRight, now: now)
        return (l.held, r.held, l.isHolding || r.isHolding)
    }

    func hasResidualHold(left: Double, right: Double, now: TimeInterval) -> Bool {
        let heldL = decayedValue(peak: peakLeft, timestamp: timestampLeft, now: now)
        let heldR = decayedValue(peak: peakRight, timestamp: timestampRight, now: now)
        return heldL > left + 0.002 || heldR > right + 0.002
    }

    private func stepChannel(
        current: Double,
        peak: inout Double,
        timestamp: inout TimeInterval,
        now: TimeInterval
    ) -> (held: Double, isHolding: Bool) {
        let decayed = decayedValue(peak: peak, timestamp: timestamp, now: now)
        if current >= decayed {
            peak = current
            timestamp = now
            return (current, current > 0.002)
        }
        return (decayed, decayed > current + 0.002)
    }

    private func decayedValue(peak: Double, timestamp: TimeInterval, now: TimeInterval) -> Double {
        guard peak > 0.0001 else { return 0.0 }
        let elapsed = max(0.0, now - timestamp)
        if elapsed <= holdDuration {
            return peak
        }
        return max(0.0, peak - (elapsed - holdDuration) * decayRatePerSecond)
    }
}

/// Segmented GarageBand-style stereo LED level meter with green → amber → red zones and decaying peak-hold caps.
public struct LEDMeterView: View {
    private let leftLevel: Float
    private let rightLevel: Float
    private let leftPeak: Float?
    private let rightPeak: Float?
    private let orientation: LEDMeterOrientation
    private let segmentCount: Int
    private let showsLabels: Bool

    @State private var peakTracker = PeakHoldTracker()
    @State private var isDecayAnimating = false

    public init(
        leftLevel: Float,
        rightLevel: Float,
        leftPeak: Float? = nil,
        rightPeak: Float? = nil,
        orientation: LEDMeterOrientation = .vertical,
        segmentCount: Int = 16,
        showsLabels: Bool = false
    ) {
        self.leftLevel = leftLevel
        self.rightLevel = rightLevel
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
        self.orientation = orientation
        self.segmentCount = min(32, max(4, segmentCount))
        self.showsLabels = showsLabels
    }

    private var normLeft: Double {
        Self.normalizedMeterLevel(for: leftLevel)
    }

    private var normRight: Double {
        Self.normalizedMeterLevel(for: rightLevel)
    }

    private var normPeakInputLeft: Double {
        let peakAmplitude = leftPeak.map { max(leftLevel, $0) } ?? leftLevel
        return Self.normalizedMeterLevel(for: peakAmplitude)
    }

    private var normPeakInputRight: Double {
        let peakAmplitude = rightPeak.map { max(rightLevel, $0) } ?? rightLevel
        return Self.normalizedMeterLevel(for: peakAmplitude)
    }

    private var inputSignature: Int {
        var hasher = Hasher()
        hasher.combine(leftLevel.bitPattern)
        hasher.combine(rightLevel.bitPattern)
        hasher.combine(leftPeak?.bitPattern ?? 0)
        hasher.combine(rightPeak?.bitPattern ?? 0)
        return hasher.finalize()
    }

    public var body: some View {
        Group {
            if showsLabels {
                labeledContent
            } else {
                meterWell
            }
        }
        .task(id: inputSignature) {
            let now = Date.timeIntervalSinceReferenceDate
            let activeInput = normPeakInputLeft > 0.002 || normPeakInputRight > 0.002
            if activeInput || peakTracker.hasResidualHold(left: normLeft, right: normRight, now: now) {
                isDecayAnimating = true
            }
            while isDecayAnimating && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { break }
                let checkNow = Date.timeIntervalSinceReferenceDate
                let stillHolding = peakTracker.hasResidualHold(left: normLeft, right: normRight, now: checkNow)
                let stillReceivingSignal = normPeakInputLeft > 0.002 || normPeakInputRight > 0.002
                if !stillHolding && !stillReceivingSignal {
                    isDecayAnimating = false
                    break
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stereo Level Meter"))
        .accessibilityValue(accessibilityReadout)
    }

    @ViewBuilder
    private var labeledContent: some View {
        switch orientation {
        case .vertical:
            VStack(spacing: 4) {
                meterWell
                HStack(spacing: 4) {
                    Text(verbatim: "L")
                        .frame(maxWidth: .infinity)
                    Text(verbatim: "R")
                        .frame(maxWidth: .infinity)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.mutedText)
            }
        case .horizontal:
            HStack(spacing: 5) {
                VStack(spacing: 3) {
                    Text(verbatim: "L")
                        .frame(maxHeight: .infinity)
                    Text(verbatim: "R")
                        .frame(maxHeight: .infinity)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.mutedText)
                meterWell
            }
        }
    }

    private var meterWell: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isDecayAnimating)) { _ in
            Canvas { context, size in
                let now = Date.timeIntervalSinceReferenceDate
                let held = peakTracker.currentHeld(
                    left: normPeakInputLeft,
                    right: normPeakInputRight,
                    now: now
                )
                drawMeter(
                    in: &context,
                    size: size,
                    leftLevel: normLeft,
                    rightLevel: normRight,
                    holdLeft: held.left,
                    holdRight: held.right
                )
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(StudioTheme.recessedWell)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
        }
    }

    private func drawMeter(
        in context: inout GraphicsContext,
        size: CGSize,
        leftLevel: Double,
        rightLevel: Double,
        holdLeft: Double,
        holdRight: Double
    ) {
        guard size.width > 1, size.height > 1 else { return }

        let channelSpacing: CGFloat = 2.0
        let segmentGap: CGFloat = 1.5
        let count = segmentCount

        switch orientation {
        case .vertical:
            let trackWidth = max(1.0, (size.width - channelSpacing) * 0.5)
            let segHeight = max(1.0, (size.height - CGFloat(count - 1) * segmentGap) / CGFloat(count))
            let corner = min(1.5, min(trackWidth, segHeight) * 0.28)

            let peakIndexL = peakSegmentIndex(for: holdLeft, count: count)
            let peakIndexR = peakSegmentIndex(for: holdRight, count: count)

            for i in 0..<count {
                let y = size.height - CGFloat(i + 1) * segHeight - CGFloat(i) * segmentGap
                let threshold = Double(i) / Double(count) + 0.015
                let zoneColor = segmentColor(index: i, count: count)

                let rectL = CGRect(x: 0, y: y, width: trackWidth, height: segHeight)
                drawSegment(
                    in: &context,
                    rect: rectL,
                    cornerRadius: corner,
                    color: zoneColor,
                    isLit: leftLevel >= threshold,
                    isPeakCap: peakIndexL == i
                )

                let rectR = CGRect(x: trackWidth + channelSpacing, y: y, width: trackWidth, height: segHeight)
                drawSegment(
                    in: &context,
                    rect: rectR,
                    cornerRadius: corner,
                    color: zoneColor,
                    isLit: rightLevel >= threshold,
                    isPeakCap: peakIndexR == i
                )
            }

        case .horizontal:
            let trackHeight = max(1.0, (size.height - channelSpacing) * 0.5)
            let segWidth = max(1.0, (size.width - CGFloat(count - 1) * segmentGap) / CGFloat(count))
            let corner = min(1.5, min(segWidth, trackHeight) * 0.28)

            let peakIndexL = peakSegmentIndex(for: holdLeft, count: count)
            let peakIndexR = peakSegmentIndex(for: holdRight, count: count)

            for i in 0..<count {
                let x = CGFloat(i) * (segWidth + segmentGap)
                let threshold = Double(i) / Double(count) + 0.015
                let zoneColor = segmentColor(index: i, count: count)

                let rectL = CGRect(x: x, y: 0, width: segWidth, height: trackHeight)
                drawSegment(
                    in: &context,
                    rect: rectL,
                    cornerRadius: corner,
                    color: zoneColor,
                    isLit: leftLevel >= threshold,
                    isPeakCap: peakIndexL == i
                )

                let rectR = CGRect(x: x, y: trackHeight + channelSpacing, width: segWidth, height: trackHeight)
                drawSegment(
                    in: &context,
                    rect: rectR,
                    cornerRadius: corner,
                    color: zoneColor,
                    isLit: rightLevel >= threshold,
                    isPeakCap: peakIndexR == i
                )
            }
        }
    }

    private func drawSegment(
        in context: inout GraphicsContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        color: Color,
        isLit: Bool,
        isPeakCap: Bool
    ) {
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
        if isLit || isPeakCap {
            context.fill(path, with: .color(color.opacity(isPeakCap && !isLit ? 0.95 : 0.92)))
            let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
            if insetRect.width > 0.5, insetRect.height > 0.5 {
                let highlightPath = Path(roundedRect: insetRect, cornerRadius: max(0.5, cornerRadius - 0.5))
                context.fill(highlightPath, with: .color(Color.white.opacity(isPeakCap ? 0.35 : 0.16)))
            }
        } else {
            context.fill(path, with: .color(StudioTheme.ledOff))
            context.fill(path, with: .color(color.opacity(0.11)))
        }
    }

    private func segmentColor(index: Int, count: Int) -> Color {
        let ratio = Double(index + 1) / Double(count)
        if ratio > 0.875 {
            return StudioTheme.ledRed
        } else if ratio > 0.68 {
            return StudioTheme.ledAmber
        } else {
            return StudioTheme.ledGreen
        }
    }

    private func peakSegmentIndex(for heldNormalized: Double, count: Int) -> Int? {
        guard heldNormalized > 0.015 else { return nil }
        let idx = Int(ceil(heldNormalized * Double(count))) - 1
        return min(count - 1, max(0, idx))
    }

    /// Maps linear sample amplitude `[0, 1+]` onto a musical `[-48 dBFS, 0 dBFS]` normalized scale.
    public static func normalizedMeterLevel(for linearAmplitude: Float) -> Double {
        guard linearAmplitude.isFinite, linearAmplitude > 1e-5 else { return 0.0 }
        let minDB = -48.0
        let db = 20.0 * log10(Double(linearAmplitude))
        return min(1.0, max(0.0, (db - minDB) / (0.0 - minDB)))
    }

    private var accessibilityReadout: String {
        let dbL = StudioTheme.formatDecibels(linearGain: Double(max(0, leftLevel)))
        let dbR = StudioTheme.formatDecibels(linearGain: Double(max(0, rightLevel)))
        return "L \(dbL), R \(dbR)"
    }
}
