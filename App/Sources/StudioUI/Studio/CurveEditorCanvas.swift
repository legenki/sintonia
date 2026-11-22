import PresetKit
import SwiftUI
import SynthCore

/// Editable automation curve targets exposed in `CurveEditorView`.
public enum CurveEditorParameter: String, CaseIterable, Identifiable, Sendable {
    case beatHz
    case carrierHz
    case voiceVolume
    case noiseVolume
    case noiseColor

    public var id: String { rawValue }

    /// Indicates whether this curve belongs to the currently selected voice rather than the global noise layer.
    public var isVoiceParameter: Bool {
        switch self {
        case .beatHz, .carrierHz, .voiceVolume:
            return true
        case .noiseVolume, .noiseColor:
            return false
        }
    }

    /// Valid parameter range enforced by `PresetValidator` and `SnapshotCompiler`.
    public var valueRange: ClosedRange<Double> {
        switch self {
        case .beatHz:
            return PresetLimits.beatHzRange
        case .carrierHz:
            return PresetLimits.carrierHzRange
        case .voiceVolume, .noiseVolume, .noiseColor:
            return PresetLimits.unitRange
        }
    }

    public var localizedTitleKey: LocalizedStringKey {
        switch self {
        case .beatHz: return "Beat Frequency"
        case .carrierHz: return "Carrier Frequency"
        case .voiceVolume: return "Voice Volume"
        case .noiseVolume: return "Noise Volume"
        case .noiseColor: return "Noise Color"
        }
    }

    public var shortTitleKey: LocalizedStringKey {
        switch self {
        case .beatHz: return "Beat"
        case .carrierHz: return "Carrier"
        case .voiceVolume: return "Voice Volume"
        case .noiseVolume: return "Noise Volume"
        case .noiseColor: return "Noise Color"
        }
    }

    public var accentColor: Color {
        switch self {
        case .beatHz: return StudioTheme.alphaColor
        case .carrierHz: return StudioTheme.deltaColor
        case .voiceVolume: return StudioTheme.ledGreen
        case .noiseVolume: return StudioTheme.thetaColor
        case .noiseColor: return StudioTheme.betaColor
        }
    }

    /// Formats a parameter value with units or noise spectrum descriptor for floating badges and readouts.
    public func formatValue(_ value: Double) -> String {
        let lower = valueRange.lowerBound
        let upper = valueRange.upperBound
        let clamped = value.isFinite ? min(upper, max(lower, value)) : lower
        switch self {
        case .beatHz, .carrierHz:
            return StudioTheme.formatFrequency(clamped)
        case .voiceVolume, .noiseVolume:
            return String(format: "%.0f%%", clamped * 100.0)
        case .noiseColor:
            let pct = Int((clamped * 100.0).rounded())
            if clamped < 0.2 {
                return "\(String(localized: "White")) (\(pct)%)"
            } else if clamped <= 0.75 {
                return "\(String(localized: "Pink")) (\(pct)%)"
            } else {
                return "\(String(localized: "Brown")) (\(pct)%)"
            }
        }
    }

    /// Formats compact Y-axis graticule tick labels.
    public func formatAxisLabel(_ value: Double) -> String {
        switch self {
        case .beatHz:
            return value >= 10.0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        case .carrierHz:
            return String(format: "%.0f", value)
        case .voiceVolume, .noiseVolume:
            return String(format: "%.0f%%", value * 100.0)
        case .noiseColor:
            if value <= 0.05 { return String(localized: "White") }
            if abs(value - 0.5) < 0.08 { return String(localized: "Pink") }
            if value >= 0.95 { return String(localized: "Brown") }
            return String(format: "%.0f%%", value * 100.0)
        }
    }
}

/// Interactive SwiftUI `Canvas` timeline editor for `EnvelopeCurve`.
/// Supports tap-to-add, `@GestureState`-guarded point dragging with floating coordinate badge,
/// long-press delete (never removing the final point), pinch-to-zoom, horizontal pan, 1-minute snap,
/// linear/smooth-step rendering, and a live playback cursor.
public struct CurveEditorCanvas: View {
    @Binding private var curve: EnvelopeCurve
    @Binding private var selectedPointIndex: Int?
    @Binding private var timeZoom: CGFloat
    @Binding private var panFraction: CGFloat

    private let durationSec: Double
    private let valueRange: ClosedRange<Double>
    private let currentTime: Double
    private let snapToMinute: Bool
    private let accentColor: Color
    private let isBeatFrequency: Bool
    private let valueFormatter: (Double) -> String
    private let axisLabelFormatter: (Double) -> String

    @GestureState private var isDragGestureActive = false
    @GestureState private var isPinching = false
    @GestureState private var pinchScale: CGFloat = 1.0

    @State private var dragState: ActiveDragState?
    @State private var haptics = StudioControlHaptics()

    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 16.0
    private static let hitRadiusPt: CGFloat = 24.0
    private static let dragMoveThresholdPt: CGFloat = 7.0
    private static let smoothSegmentSubdivisions = 28

    private enum ActiveDragState: Equatable {
        case point(
            originIndex: Int,
            basePoints: [CurvePoint],
            startLocation: CGPoint,
            currentPoint: CurvePoint,
            hasMoved: Bool
        )
        case canvasPanOrTap(
            startLocation: CGPoint,
            startPanFraction: CGFloat,
            hasMoved: Bool
        )
        case suppressed
    }

    public init(
        curve: Binding<EnvelopeCurve>,
        selectedPointIndex: Binding<Int?>,
        timeZoom: Binding<CGFloat>,
        panFraction: Binding<CGFloat>,
        durationSec: Double,
        valueRange: ClosedRange<Double>,
        currentTime: Double,
        snapToMinute: Bool,
        accentColor: Color,
        isBeatFrequency: Bool = false,
        valueFormatter: @escaping (Double) -> String,
        axisLabelFormatter: @escaping (Double) -> String
    ) {
        self._curve = curve
        self._selectedPointIndex = selectedPointIndex
        self._timeZoom = timeZoom
        self._panFraction = panFraction
        self.durationSec = durationSec
        self.valueRange = valueRange
        self.currentTime = currentTime
        self.snapToMinute = snapToMinute
        self.accentColor = accentColor
        self.isBeatFrequency = isBeatFrequency
        self.valueFormatter = valueFormatter
        self.axisLabelFormatter = axisLabelFormatter
    }

    private var effectiveDuration: Double {
        let raw = durationSec.isFinite && durationSec > 1.0 ? durationSec : 60.0
        return raw
    }

    private var effectiveZoom: CGFloat {
        min(Self.maxZoom, max(Self.minZoom, timeZoom * pinchScale))
    }

    private var visibleDuration: Double {
        effectiveDuration / Double(effectiveZoom)
    }

    private var effectivePanFraction: CGFloat {
        let baseSpan = 1.0 / Double(max(Self.minZoom, timeZoom))
        let newSpan = 1.0 / Double(effectiveZoom)
        if abs(pinchScale - 1.0) > 0.001 {
            let center = Double(panFraction) + baseSpan * 0.5
            let adjusted = center - newSpan * 0.5
            return CGFloat(min(max(0.0, 1.0 - newSpan), max(0.0, adjusted)))
        }
        return CGFloat(min(max(0.0, 1.0 - newSpan), max(0.0, Double(panFraction))))
    }

    private var visibleStartSec: Double {
        Double(effectivePanFraction) * effectiveDuration
    }

    private var visibleEndSec: Double {
        visibleStartSec + visibleDuration
    }

    private var sortedPoints: [CurvePoint] {
        curve.points.sorted { lhs, rhs in
            lhs.timeSec < rhs.timeSec
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let canvasSize = proxy.size
            let plotRect = Self.plotRect(for: canvasSize)
            let points = sortedPoints

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StudioTheme.recessedWell)

                Canvas { context, size in
                    drawEditor(in: &context, size: size, plotRect: plotRect, points: points)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if isDragGestureActive,
                   case .point(_, _, _, let activePt, _) = dragState {
                    floatingCoordinateBadge(
                        for: activePt,
                        in: canvasSize,
                        plotRect: plotRect
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDragGestureActive ? accentColor.opacity(0.5) : StudioTheme.hairlineHighlight,
                        lineWidth: isDragGestureActive ? 1.0 : 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($isDragGestureActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        handleDragChanged(gesture, plotRect: plotRect, points: points)
                    }
                    .onEnded { gesture in
                        handleDragEnded(gesture, plotRect: plotRect, points: points)
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.55)
                    .onEnded { _ in
                        handleLongPressEnded()
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($isPinching) { _, state, _ in
                        state = true
                    }
                    .updating($pinchScale) { value, state, _ in
                        state = value.magnification
                    }
                    .onEnded { value in
                        commitPinchZoom(magnification: value.magnification)
                    }
            )
        }
        .onChange(of: isDragGestureActive) { _, active in
            if !active {
                dragState = nil
            }
        }
        .onChange(of: isPinching) { _, pinching in
            if pinching {
                switch dragState {
                case .canvasPanOrTap, .point(_, _, _, _, false):
                    dragState = .suppressed
                case .point(_, _, _, _, true), .suppressed, .none:
                    break
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDragGestureActive)
    }

    // MARK: - Coordinate Mapping

    private static func plotRect(for size: CGSize) -> CGRect {
        let left: CGFloat = 46
        let right: CGFloat = 14
        let top: CGFloat = 16
        let bottom: CGFloat = 24
        return CGRect(
            x: left,
            y: top,
            width: max(1.0, size.width - left - right),
            height: max(1.0, size.height - top - bottom)
        )
    }

    private func xPosition(forTime timeSec: Double, in plotRect: CGRect) -> CGFloat {
        let span = max(1e-6, visibleDuration)
        let fraction = (timeSec - visibleStartSec) / span
        return plotRect.minX + CGFloat(fraction) * plotRect.width
    }

    private func yPosition(forValue value: Double, in plotRect: CGRect) -> CGFloat {
        let span = max(1e-6, valueRange.upperBound - valueRange.lowerBound)
        let clamped = min(valueRange.upperBound, max(valueRange.lowerBound, value))
        let norm = (clamped - valueRange.lowerBound) / span
        return plotRect.maxY - CGFloat(norm) * plotRect.height
    }

    private func curvePoint(at location: CGPoint, in plotRect: CGRect, applySnap: Bool) -> CurvePoint {
        let rawFracX = Double((location.x - plotRect.minX) / max(1.0, plotRect.width))
        let rawTime = visibleStartSec + rawFracX * visibleDuration
        var clampedTime = min(effectiveDuration, max(0.0, rawTime))
        if applySnap {
            let snapped = (clampedTime / 60.0).rounded() * 60.0
            clampedTime = min(effectiveDuration, max(0.0, snapped))
        }

        let rawNormY = Double((plotRect.maxY - location.y) / max(1.0, plotRect.height))
        let clampedNormY = min(1.0, max(0.0, rawNormY))
        let span = max(0.0, valueRange.upperBound - valueRange.lowerBound)
        let val = valueRange.lowerBound + clampedNormY * span
        return CurvePoint(timeSec: clampedTime, value: val)
    }

    // MARK: - Floating Coordinate Pill

    private func floatingCoordinateBadge(
        for point: CurvePoint,
        in canvasSize: CGSize,
        plotRect: CGRect
    ) -> some View {
        let rawX = xPosition(forTime: point.timeSec, in: plotRect)
        let rawY = yPosition(forValue: point.value, in: plotRect)
        let pillHalfW: CGFloat = 62
        let clampedX = min(max(pillHalfW, rawX), max(pillHalfW, canvasSize.width - pillHalfW))
        let placeBelow = rawY < plotRect.minY + 34
        let badgeY = placeBelow ? min(canvasSize.height - 16, rawY + 28) : max(14, rawY - 28)

        return Text(verbatim: "\(StudioTheme.formatTime(point.timeSec)) • \(valueFormatter(point.value))")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(StudioTheme.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(StudioTheme.elevatedSurface)
                    .shadow(color: StudioTheme.hardwareShadow, radius: 6, x: 0, y: 3)
            }
            .overlay {
                Capsule()
                    .strokeBorder(accentColor.opacity(0.75), lineWidth: 0.9)
            }
            .position(x: clampedX, y: badgeY)
            .allowsHitTesting(false)
    }

    // MARK: - Gesture Handling

    private func hitPointIndex(near location: CGPoint, in plotRect: CGRect, points: [CurvePoint]) -> Int? {
        var bestIndex: Int?
        var bestDist = Self.hitRadiusPt

        for (index, pt) in points.enumerated() {
            let x = xPosition(forTime: pt.timeSec, in: plotRect)
            let y = yPosition(forValue: pt.value, in: plotRect)
            guard x >= plotRect.minX - Self.hitRadiusPt && x <= plotRect.maxX + Self.hitRadiusPt else {
                continue
            }
            let dist = hypot(location.x - x, location.y - y)
            if dist <= bestDist {
                bestDist = dist
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func handleDragChanged(
        _ gesture: DragGesture.Value,
        plotRect: CGRect,
        points: [CurvePoint]
    ) {
        if dragState == nil {
            if let hitIdx = hitPointIndex(near: gesture.startLocation, in: plotRect, points: points) {
                haptics.prepare()
                selectedPointIndex = hitIdx
                dragState = .point(
                    originIndex: hitIdx,
                    basePoints: points,
                    startLocation: gesture.startLocation,
                    currentPoint: points[hitIdx],
                    hasMoved: false
                )
            } else if plotRect.insetBy(dx: -12, dy: -12).contains(gesture.startLocation) {
                haptics.prepare()
                dragState = .canvasPanOrTap(
                    startLocation: gesture.startLocation,
                    startPanFraction: panFraction,
                    hasMoved: false
                )
            } else {
                dragState = .suppressed
            }
        }

        guard let state = dragState else { return }
        switch state {
        case .suppressed:
            return

        case .point(let originIndex, let basePoints, let startLoc, _, let wasMoved):
            let travel = hypot(gesture.location.x - startLoc.x, gesture.location.y - startLoc.y)
            let moved = wasMoved || travel > Self.dragMoveThresholdPt
            guard moved else { return }

            let mapped = curvePoint(at: gesture.location, in: plotRect, applySnap: snapToMinute)
            dragState = .point(
                originIndex: originIndex,
                basePoints: basePoints,
                startLocation: startLoc,
                currentPoint: mapped,
                hasMoved: true
            )
            applyDraggedPoint(mapped, originIndex: originIndex, basePoints: basePoints)

        case .canvasPanOrTap(let startLoc, let startPan, let wasMoved):
            let travel = hypot(gesture.location.x - startLoc.x, gesture.location.y - startLoc.y)
            let moved = wasMoved || travel > Self.dragMoveThresholdPt
            if moved && effectiveZoom > Self.minZoom {
                let dx = gesture.location.x - startLoc.x
                let visibleSpan = 1.0 / Double(effectiveZoom)
                let deltaPan = CGFloat(-Double(dx / max(1.0, plotRect.width)) * visibleSpan)
                let maxPan = CGFloat(max(0.0, 1.0 - visibleSpan))
                panFraction = min(maxPan, max(0.0, startPan + deltaPan))
            }
            if moved != wasMoved {
                dragState = .canvasPanOrTap(
                    startLocation: startLoc,
                    startPanFraction: startPan,
                    hasMoved: moved
                )
            }
        }
    }

    private func handleDragEnded(
        _ gesture: DragGesture.Value,
        plotRect: CGRect,
        points: [CurvePoint]
    ) {
        defer { dragState = nil }
        guard let state = dragState else { return }

        switch state {
        case .suppressed:
            return

        case .point(let originIndex, let basePoints, let startLoc, _, let wasMoved):
            let travel = hypot(gesture.location.x - startLoc.x, gesture.location.y - startLoc.y)
            if wasMoved || travel > Self.dragMoveThresholdPt {
                let mapped = curvePoint(at: gesture.location, in: plotRect, applySnap: snapToMinute)
                applyDraggedPoint(mapped, originIndex: originIndex, basePoints: basePoints)
                haptics.fireStep()
            } else {
                haptics.fireModeShift()
            }

        case .canvasPanOrTap(let startLoc, _, let wasMoved):
            let travel = hypot(gesture.location.x - startLoc.x, gesture.location.y - startLoc.y)
            let isTap = !wasMoved && travel <= Self.dragMoveThresholdPt
            if isTap && plotRect.insetBy(dx: -10, dy: -10).contains(gesture.location) {
                let newPoint = curvePoint(at: gesture.location, in: plotRect, applySnap: snapToMinute)
                insertControlPoint(newPoint, existingPoints: points)
            }
        }
    }

    private func handleLongPressEnded() {
        guard case .point(let originIndex, _, _, _, let hasMoved) = dragState,
              !hasMoved else {
            return
        }
        let points = sortedPoints
        guard points.count > 1, points.indices.contains(originIndex) else { return }

        var remaining = points
        remaining.remove(at: originIndex)
        curve.points = remaining
        selectedPointIndex = min(originIndex, remaining.count - 1)
        dragState = .suppressed
        haptics.fireReset()
    }

    private func commitPinchZoom(magnification: CGFloat) {
        let oldZoom = timeZoom
        let newZoom = min(Self.maxZoom, max(Self.minZoom, oldZoom * magnification))
        let oldSpan = 1.0 / Double(max(Self.minZoom, oldZoom))
        let newSpan = 1.0 / Double(newZoom)
        let centerFrac = Double(panFraction) + oldSpan * 0.5
        timeZoom = newZoom
        panFraction = CGFloat(min(max(0.0, 1.0 - newSpan), max(0.0, centerFrac - newSpan * 0.5)))
    }

    private func applyDraggedPoint(
        _ newPoint: CurvePoint,
        originIndex: Int,
        basePoints: [CurvePoint]
    ) {
        guard basePoints.indices.contains(originIndex) else { return }
        var tagged: [(isTarget: Bool, originalIndex: Int, point: CurvePoint)] = basePoints
            .enumerated()
            .map { idx, pt in
                if idx == originIndex {
                    return (true, idx, newPoint)
                }
                return (false, idx, pt)
            }

        tagged.sort { lhs, rhs in
            if lhs.point.timeSec != rhs.point.timeSec {
                return lhs.point.timeSec < rhs.point.timeSec
            }
            return lhs.originalIndex < rhs.originalIndex
        }

        curve.points = tagged.map(\.point)
        if let sortedIdx = tagged.firstIndex(where: \.isTarget) {
            selectedPointIndex = sortedIdx
        }
    }

    private func insertControlPoint(_ newPoint: CurvePoint, existingPoints: [CurvePoint]) {
        var tagged: [(isNew: Bool, point: CurvePoint)] = existingPoints.map { (false, $0) }
        tagged.append((true, newPoint))
        tagged.sort { lhs, rhs in
            if lhs.point.timeSec != rhs.point.timeSec {
                return lhs.point.timeSec < rhs.point.timeSec
            }
            return !lhs.isNew && rhs.isNew
        }

        curve.points = tagged.map(\.point)
        if let insertedIdx = tagged.firstIndex(where: \.isNew) {
            selectedPointIndex = insertedIdx
        }
        haptics.fireStep()
    }

    // MARK: - Canvas Drawing

    private func drawEditor(
        in context: inout GraphicsContext,
        size: CGSize,
        plotRect: CGRect,
        points: [CurvePoint]
    ) {
        guard plotRect.width > 4, plotRect.height > 4 else { return }

        if isBeatFrequency {
            drawBrainwaveBandStrata(in: &context, plotRect: plotRect)
        }

        drawGridAndAxes(in: &context, size: size, plotRect: plotRect)
        drawCurveAndArea(in: &context, plotRect: plotRect, points: points)
        drawPlaybackCursor(in: &context, plotRect: plotRect, points: points)
        drawControlPoints(in: &context, plotRect: plotRect, points: points)
    }

    private func drawBrainwaveBandStrata(in context: inout GraphicsContext, plotRect: CGRect) {
        let bands: [(band: BrainwaveBand, lower: Double, upper: Double)] = [
            (.delta, 0.5, 4.0),
            (.theta, 4.0, 8.0),
            (.alpha, 8.0, 13.0),
            (.beta, 13.0, 30.0),
            (.gamma, 30.0, 60.0),
        ]

        for entry in bands {
            let yBottom = yPosition(forValue: entry.lower, in: plotRect)
            let yTop = yPosition(forValue: entry.upper, in: plotRect)
            let height = max(0.0, yBottom - yTop)
            guard height > 1.0 else { continue }

            let bandRect = CGRect(x: plotRect.minX, y: yTop, width: plotRect.width, height: height)
            context.fill(Path(bandRect), with: .color(entry.band.accentColor.opacity(0.045)))

            if height >= 14.0 {
                let label = Text(verbatim: entry.band.localizedTitle)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(entry.band.accentColor.opacity(0.55))
                context.draw(
                    label,
                    at: CGPoint(x: plotRect.maxX - 4, y: yTop + 8),
                    anchor: .trailing
                )
            }
        }
    }

    private func drawGridAndAxes(
        in context: inout GraphicsContext,
        size: CGSize,
        plotRect: CGRect
    ) {
        let rows = 4
        var gridPath = Path()

        // Horizontal value lines & Y labels
        let span = valueRange.upperBound - valueRange.lowerBound
        for row in 0...rows {
            let fraction = Double(row) / Double(rows)
            let val = valueRange.lowerBound + fraction * span
            let y = plotRect.maxY - CGFloat(fraction) * plotRect.height
            gridPath.move(to: CGPoint(x: plotRect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: y))

            let labelText = Text(verbatim: axisLabelFormatter(val))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTheme.mutedText)
            context.draw(
                labelText,
                at: CGPoint(x: plotRect.minX - 6, y: y),
                anchor: .trailing
            )
        }

        // Optional 1-minute vertical snap guides when zoomed in enough
        if snapToMinute && visibleDuration <= 2400.0 {
            let firstMin = ceil(visibleStartSec / 60.0) * 60.0
            var snapPath = Path()
            var t = firstMin
            while t <= visibleEndSec {
                let x = xPosition(forTime: t, in: plotRect)
                snapPath.move(to: CGPoint(x: x, y: plotRect.minY))
                snapPath.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                t += 60.0
            }
            context.stroke(snapPath, with: .color(accentColor.opacity(0.08)), lineWidth: 0.5)
        }

        // Major vertical time grid lines & MM:SS labels
        let tickStep = timeGridStepSeconds(for: visibleDuration)
        let firstTick = ceil(visibleStartSec / tickStep) * tickStep
        var t = firstTick
        while t <= visibleEndSec + 0.01 {
            let x = xPosition(forTime: t, in: plotRect)
            if x >= plotRect.minX - 1 && x <= plotRect.maxX + 1 {
                gridPath.move(to: CGPoint(x: x, y: plotRect.minY))
                gridPath.addLine(to: CGPoint(x: x, y: plotRect.maxY))

                let timeLabel = Text(verbatim: StudioTheme.formatTime(t))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.mutedText)
                let anchor: UnitPoint = if x - plotRect.minX < 20 {
                    .topLeading
                } else if plotRect.maxX - x < 20 {
                    .topTrailing
                } else {
                    .top
                }
                context.draw(
                    timeLabel,
                    at: CGPoint(x: x, y: min(size.height - 14, plotRect.maxY + 5)),
                    anchor: anchor
                )
            }
            t += tickStep
        }

        context.stroke(gridPath, with: .color(Color.white.opacity(0.08)), lineWidth: 0.6)

        // Subtle plot perimeter
        context.stroke(
            Path(plotRect),
            with: .color(Color.white.opacity(0.11)),
            lineWidth: 0.75
        )
    }

    private func timeGridStepSeconds(for spanSec: Double) -> Double {
        let candidates: [Double] = [10, 15, 30, 60, 120, 300, 600, 900, 1200, 1800]
        for step in candidates where spanSec / step <= 6.5 {
            return step
        }
        return 1800
    }

    private func drawCurveAndArea(
        in context: inout GraphicsContext,
        plotRect: CGRect,
        points: [CurvePoint]
    ) {
        guard !points.isEmpty else { return }

        let compiled = CompiledCurve(points: points, interpolation: curve.interpolation)
        var tracePath = Path()
        var areaPath = Path()

        let sampleCount = max(24, Int((plotRect.width / 3.0).rounded()))
        for step in 0...sampleCount {
            let frac = Double(step) / Double(sampleCount)
            let timeSec = visibleStartSec + frac * visibleDuration
            let val = compiled.evaluate(at: timeSec)
            let pt = CGPoint(
                x: plotRect.minX + CGFloat(frac) * plotRect.width,
                y: yPosition(forValue: val, in: plotRect)
            )
            if step == 0 {
                tracePath.move(to: pt)
                areaPath.move(to: CGPoint(x: pt.x, y: plotRect.maxY))
                areaPath.addLine(to: pt)
            } else {
                tracePath.addLine(to: pt)
                areaPath.addLine(to: pt)
            }
        }
        areaPath.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        areaPath.closeSubpath()

        var clipped = context
        clipped.clip(to: Path(plotRect))

        clipped.fill(
            areaPath,
            with: .linearGradient(
                Gradient(colors: [accentColor.opacity(0.24), accentColor.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: plotRect.minY),
                endPoint: CGPoint(x: 0, y: plotRect.maxY)
            )
        )

        clipped.stroke(
            tracePath,
            with: .color(accentColor.opacity(0.32)),
            style: StrokeStyle(lineWidth: 5.0, lineCap: .round, lineJoin: .round)
        )
        clipped.stroke(
            tracePath,
            with: .color(accentColor),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawPlaybackCursor(
        in context: inout GraphicsContext,
        plotRect: CGRect,
        points: [CurvePoint]
    ) {
        let clampedTime = min(effectiveDuration, max(0.0, currentTime.isFinite ? currentTime : 0.0))
        guard clampedTime >= visibleStartSec - 0.5 && clampedTime <= visibleEndSec + 0.5 else {
            return
        }

        let x = xPosition(forTime: clampedTime, in: plotRect)
        guard x >= plotRect.minX - 1 && x <= plotRect.maxX + 1 else { return }

        var cursorLine = Path()
        cursorLine.move(to: CGPoint(x: x, y: plotRect.minY))
        cursorLine.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        context.stroke(cursorLine, with: .color(StudioTheme.primaryText.opacity(0.72)), lineWidth: 1.3)

        // Small playhead triangle at top of plot
        var head = Path()
        head.move(to: CGPoint(x: x, y: plotRect.minY + 4))
        head.addLine(to: CGPoint(x: x - 4.5, y: plotRect.minY - 3))
        head.addLine(to: CGPoint(x: x + 4.5, y: plotRect.minY - 3))
        head.closeSubpath()
        context.fill(head, with: .color(StudioTheme.primaryText))

        if !points.isEmpty {
            let val = CompiledCurve(points: points, interpolation: curve.interpolation).evaluate(at: clampedTime)
            let y = yPosition(forValue: val, in: plotRect)
            let dot = Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
            context.fill(dot, with: .color(StudioTheme.primaryText))
        }
    }

    private func drawControlPoints(
        in context: inout GraphicsContext,
        plotRect: CGRect,
        points: [CurvePoint]
    ) {
        let activelyDragging = isDragGestureActive && {
            if case .point = dragState { return true }
            return false
        }()

        for (index, pt) in points.enumerated() {
            let x = xPosition(forTime: pt.timeSec, in: plotRect)
            guard x >= plotRect.minX - 8 && x <= plotRect.maxX + 8 else { continue }
            let y = yPosition(forValue: pt.value, in: plotRect)
            let isSelected = selectedPointIndex == index

            if isSelected {
                let haloRadius: CGFloat = activelyDragging ? 12.5 : 9.5
                let halo = Path(ellipseIn: CGRect(
                    x: x - haloRadius,
                    y: y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                ))
                context.fill(halo, with: .color(accentColor.opacity(activelyDragging ? 0.34 : 0.22)))
            }

            let radius: CGFloat = isSelected ? 5.5 : 4.5
            let circle = Path(ellipseIn: CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.fill(circle, with: .color(isSelected ? StudioTheme.primaryText : StudioTheme.elevatedSurface))
            context.stroke(circle, with: .color(accentColor), lineWidth: isSelected ? 2.2 : 1.8)
        }
    }
}
