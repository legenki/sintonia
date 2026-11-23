import SwiftUI
import SynthCore
#if os(macOS)
import AppKit
#endif

/// Display modes cycled by tapping `OscilloscopeView`.
public enum OscilloscopeDisplayMode: Int, CaseIterable, Sendable {
    case waveform
    case lissajous
    case bandMonitor

    /// Localized mode title matching `Localizable.xcstrings`.
    public var localizedTitle: String {
        switch self {
        case .waveform: return String(localized: "Waveform")
        case .lissajous: return String(localized: "Lissajous")
        case .bandMonitor: return String(localized: "Band Monitor")
        }
    }

    /// Returns the next display mode in the cycle (`waveform -> lissajous -> bandMonitor -> waveform`).
    public func next() -> OscilloscopeDisplayMode {
        let all = Self.allCases
        let nextIndex = (rawValue + 1) % all.count
        return all[nextIndex]
    }
}

/// Pre-allocated scratch buffers kept across frames to avoid heap churn at 60–120 fps.
@MainActor
private final class TelemetryScratchBox {
    static let waveformPointCount = 256
    static let waveformTrailCapacity = 9
    static let lissajousPointCount = 384
    static let lissajousTrailCapacity = 14

    var frame = TelemetryFrame()
    var smoothedLeft = [Double](repeating: 0.0, count: TelemetryScratchBox.waveformPointCount)
    var smoothedRight = [Double](repeating: 0.0, count: TelemetryScratchBox.waveformPointCount)
    var hasWaveformHistory: Bool = false

    var leftTrails: [[CGPoint]] = (0..<TelemetryScratchBox.waveformTrailCapacity).map { _ in
        [CGPoint](repeating: .zero, count: TelemetryScratchBox.waveformPointCount)
    }
    var rightTrails: [[CGPoint]] = (0..<TelemetryScratchBox.waveformTrailCapacity).map { _ in
        [CGPoint](repeating: .zero, count: TelemetryScratchBox.waveformPointCount)
    }
    var waveformTrailHead: Int = 0
    var waveformTrailCount: Int = 0

    var lissajousRawX = [Double](repeating: 0.0, count: TelemetryScratchBox.lissajousPointCount)
    var lissajousRawY = [Double](repeating: 0.0, count: TelemetryScratchBox.lissajousPointCount)
    var lissajousTrails: [[CGPoint]] = (0..<TelemetryScratchBox.lissajousTrailCapacity).map { _ in
        [CGPoint](repeating: .zero, count: TelemetryScratchBox.lissajousPointCount)
    }
    var lissajousTrailHead: Int = 0
    var lissajousTrailCount: Int = 0

    var smoothedWaveformGain: Double = 1.0
    var smoothedLissajousGain: Double = 1.0
    var lastTimestamp: TimeInterval? = nil
    var lastDisplayMode: OscilloscopeDisplayMode? = nil
    var lastCanvasSize: CGSize = .zero

    func resetTemporalState() {
        hasWaveformHistory = false
        waveformTrailHead = 0
        waveformTrailCount = 0
        lissajousTrailHead = 0
        lissajousTrailCount = 0
    }
}

/// 60–120 fps studio CRT/OLED oscilloscope backed by `TelemetryRingBuffer`.
/// Tap to cycle `.waveform`, `.lissajous`, and `.bandMonitor` modes.
public struct OscilloscopeView: View {
    private let telemetryBuffer: TelemetryRingBuffer
    private let dominantBeatHz: Double
    private let dominantBand: BrainwaveBand
    private let activeVoiceCount: Int
    private let isPlaying: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayMode: OscilloscopeDisplayMode
    @State private var scratch = TelemetryScratchBox()
    @State private var haptics = StudioControlHaptics()
    @State private var isWindowVisible: Bool = true

    public init(
        telemetryBuffer: TelemetryRingBuffer,
        dominantBeatHz: Double,
        dominantBand: BrainwaveBand,
        activeVoiceCount: Int,
        isPlaying: Bool,
        initialMode: OscilloscopeDisplayMode = .waveform
    ) {
        self.telemetryBuffer = telemetryBuffer
        self.dominantBeatHz = dominantBeatHz
        self.dominantBand = dominantBand
        self.activeVoiceCount = activeVoiceCount
        self.isPlaying = isPlaying
        self._displayMode = State(initialValue: initialMode)
    }

    private var clampedVoiceCount: Int {
        min(SynthSnapshot.maxVoices, max(0, activeVoiceCount))
    }

    private var isAnimationPaused: Bool {
        !isPlaying || !isWindowVisible || scenePhase != .active
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StudioTheme.recessedWell)

            TimelineView(.animation(minimumInterval: reduceMotion ? (1.0 / 20.0) : nil, paused: isAnimationPaused)) { timeline in
                Canvas { context, size in
                    let box = scratch
                    let dt = computeFrameDelta(
                        now: timeline.date.timeIntervalSinceReferenceDate,
                        size: size,
                        box: box
                    )
                    telemetryBuffer.readLatest(into: &box.frame)

                    switch displayMode {
                    case .waveform:
                        drawWaveformGraticule(in: &context, size: size)
                        drawStereoWaveform(in: &context, size: size, dt: dt, box: box)
                    case .lissajous:
                        drawLissajousGraticule(in: &context, size: size)
                        drawLissajousPlot(in: &context, size: size, dt: dt, box: box)
                    case .bandMonitor:
                        drawWaveformGraticule(in: &context, size: size, subtle: true)
                        drawBandMonitorAmbientBars(in: &context, size: size, frame: box.frame)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            #if os(macOS)
            .background(
                OscilloscopeWindowVisibilityBridge(isVisible: $isWindowVisible)
                    .allowsHitTesting(false)
            )
            #endif

            if displayMode == .bandMonitor {
                bandMonitorOverlay
                    .transition(.opacity)
            }

            topHUD
                .padding(10)

            // Subtle glass screen reflection along top edge
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.065),
                            Color.white.opacity(0.015),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(StudioTheme.metallicRimGradient, lineWidth: 1.2)
        }
        .shadow(color: StudioTheme.hardwareShadow, radius: 10, x: 0, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            haptics.prepare()
            withAnimation(.easeInOut(duration: 0.18)) {
                displayMode = displayMode.next()
            }
            haptics.fireImpact(.light, intensity: 0.65)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Oscilloscope"))
        .accessibilityValue(accessibilityDescription)
        .accessibilityHint(Text("Cycle Display Mode"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - HUD & Band Monitor Overlay

    private var topHUD: some View {
        VStack {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(displayMode.localizedTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)

                    HStack(spacing: 3) {
                        ForEach(OscilloscopeDisplayMode.allCases, id: \.rawValue) { mode in
                            Circle()
                                .fill(mode == displayMode ? dominantBand.accentColor : StudioTheme.mutedText.opacity(0.45))
                                .frame(width: 4.5, height: 4.5)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))

                Spacer(minLength: 8)

                if displayMode == .waveform {
                    HStack(spacing: 6) {
                        channelDot(label: "L", color: StudioTheme.leftTraceColor)
                        channelDot(label: "R", color: StudioTheme.rightTraceColor)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
                }

                if displayMode != .bandMonitor {
                    BrainwaveBandBadge(band: dominantBand, beatHz: dominantBeatHz, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func channelDot(label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(StudioTheme.secondaryText)
        }
    }

    private var bandMonitorOverlay: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 28)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(StudioTheme.formatFrequencyNumber(dominantBeatHz))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .shadow(color: dominantBand.accentColor.opacity(0.55), radius: 10)

                Text(verbatim: "Hz")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(dominantBand.accentColor)
            }

            BrainwaveBandBadge(band: dominantBand, beatHz: nil, compact: false)

            HStack(spacing: 8) {
                Text("Active Voices")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)

                HStack(spacing: 4) {
                    ForEach(0..<SynthSnapshot.maxVoices, id: \.self) { index in
                        let isActive = index < clampedVoiceCount
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isActive ? dominantBand.accentColor : StudioTheme.ledOff)
                            .frame(width: 7, height: 10)
                            .shadow(
                                color: isActive ? dominantBand.accentColor.opacity(0.7) : .clear,
                                radius: 3
                            )
                    }
                }

                Text(verbatim: "\(clampedVoiceCount)/\(SynthSnapshot.maxVoices)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Canvas Drawing Routines (Zero Heap Churn)

    private func drawWaveformGraticule(
        in context: inout GraphicsContext,
        size: CGSize,
        subtle: Bool = false
    ) {
        let gridOpacity = subtle ? 0.045 : 0.08
        let midOpacity = subtle ? 0.08 : 0.14
        let columns = 8
        let rows = 4

        var gridPath = Path()
        for col in 1..<columns {
            let x = size.width * CGFloat(col) / CGFloat(columns)
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
        }
        for row in 1..<rows {
            if row == rows / 2 { continue }
            let y = size.height * CGFloat(row) / CGFloat(rows)
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(gridPath, with: .color(Color.white.opacity(gridOpacity)), lineWidth: 0.5)

        var centerPath = Path()
        let midY = size.height * 0.5
        centerPath.move(to: CGPoint(x: 0, y: midY))
        centerPath.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(centerPath, with: .color(Color.white.opacity(midOpacity)), lineWidth: 0.75)
    }

    private func computeFrameDelta(
        now: TimeInterval,
        size: CGSize,
        box: TelemetryScratchBox
    ) -> Double {
        let sizeChanged = abs(box.lastCanvasSize.width - size.width) > 0.5
            || abs(box.lastCanvasSize.height - size.height) > 0.5
        let modeChanged = box.lastDisplayMode != displayMode
        let rawDelta = box.lastTimestamp.map { now - $0 } ?? (1.0 / 60.0)

        if sizeChanged || modeChanged || rawDelta > 0.25 || rawDelta < 0.0 {
            box.resetTemporalState()
        }

        box.lastTimestamp = now
        box.lastDisplayMode = displayMode
        box.lastCanvasSize = size
        return min(1.0 / 20.0, max(1.0 / 240.0, rawDelta))
    }

    private func smoothAutoGain(
        current: Double,
        target: Double,
        dt: Double,
        snap: Bool
    ) -> Double {
        if snap { return target }
        // Fast attack when level increases (target < current), silky release when level drops.
        let tau = target < current ? 0.045 : 0.22
        let alpha = 1.0 - exp(-dt / tau)
        return current + (target - current) * alpha
    }

    private func interpolatedSample(_ samples: [Float], at position: Double) -> Double {
        let maxIndex = samples.count - 1
        guard maxIndex >= 0 else { return 0.0 }
        let clamped = min(Double(maxIndex), max(0.0, position))
        let i0 = Int(clamped)
        let i1 = min(maxIndex, i0 + 1)
        let frac = clamped - Double(i0)
        let s0 = Double(samples[i0])
        let s1 = Double(samples[i1])
        return s0 + (s1 - s0) * frac
    }

    private func smoothedTriggerSample(_ samples: [Float], at index: Int) -> Float {
        // 5-tap symmetric low-pass kernel suppresses pink/brown noise false zero crossings.
        let s0 = samples[index - 2]
        let s1 = samples[index - 1]
        let s2 = samples[index]
        let s3 = samples[index + 1]
        let s4 = samples[index + 2]
        return (s0 + 2.0 * s1 + 3.0 * s2 + 2.0 * s3 + s4) * 0.11111111
    }

    private func findSubsampleTriggerPosition(
        samples: [Float],
        windowLength: Int,
        maxAbs: Float
    ) -> Double {
        let searchLimit = samples.count - windowLength - 2
        guard maxAbs > 1e-4, searchLimit > 3 else { return 0.0 }

        // Schmitt-style hysteresis: arm once smoothed signal dips below -threshold,
        // then lock onto the next rising zero-crossing with fractional interpolation.
        let armThreshold = max(1e-4, maxAbs * 0.06)
        var armed = false
        var prev = smoothedTriggerSample(samples, at: 2)
        if prev <= -armThreshold {
            armed = true
        }

        for i in 3..<searchLimit {
            let curr = smoothedTriggerSample(samples, at: i)
            if !armed && curr <= -armThreshold {
                armed = true
            } else if armed && prev < 0.0 && curr >= 0.0 {
                let delta = Double(curr - prev)
                let frac = delta > 1e-9 ? min(1.0, max(0.0, Double(-prev) / delta)) : 0.0
                return Double(i - 1) + frac
            }
            prev = curr
        }

        // Fallback to first rising crossing if wave didn't cross the hysteresis threshold.
        for i in 1..<(samples.count - windowLength) {
            let s0 = samples[i - 1]
            let s1 = samples[i]
            if s0 < 0.0 && s1 >= 0.0 {
                let delta = Double(s1 - s0)
                let frac = delta > 1e-9 ? min(1.0, max(0.0, Double(-s0) / delta)) : 0.0
                return Double(i - 1) + frac
            }
        }
        return 0.0
    }

    private func smoothPath(through points: [CGPoint], count: Int) -> Path {
        var path = Path()
        guard count >= 2 else { return path }
        path.move(to: points[0])
        if count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(count - 1) {
            let p = points[i]
            let next = points[i + 1]
            let mid = CGPoint(x: (p.x + next.x) * 0.5, y: (p.y + next.y) * 0.5)
            path.addQuadCurve(to: mid, control: p)
        }
        path.addLine(to: points[count - 1])
        return path
    }

    private func drawStereoWaveform(
        in context: inout GraphicsContext,
        size: CGSize,
        dt: Double,
        box: TelemetryScratchBox
    ) {
        let sampleCount = min(box.frame.leftSamples.count, box.frame.rightSamples.count)
        let pointCount = TelemetryScratchBox.waveformPointCount
        guard sampleCount >= 512, pointCount > 1, size.width > 1, size.height > 1 else { return }

        let windowLength = 512
        var maxAbs: Float = 0.0
        for i in 0..<sampleCount {
            let aL = abs(box.frame.leftSamples[i])
            let aR = abs(box.frame.rightSamples[i])
            if aL > maxAbs { maxAbs = aL }
            if aR > maxAbs { maxAbs = aR }
        }

        let triggerPos = findSubsampleTriggerPosition(
            samples: box.frame.leftSamples,
            windowLength: windowLength,
            maxAbs: maxAbs
        )

        let targetGain = min(3.2, 0.86 / max(0.22, Double(maxAbs)))
        box.smoothedWaveformGain = smoothAutoGain(
            current: box.smoothedWaveformGain,
            target: targetGain,
            dt: dt,
            snap: !box.hasWaveformHistory
        )

        let gainScale = box.smoothedWaveformGain
        let midY = size.height * 0.5
        let amplitudeY = size.height * 0.42
        let dx = size.width / CGFloat(pointCount - 1)
        let sampleStep = Double(windowLength - 1) / Double(pointCount - 1)
        let temporalAlpha = box.hasWaveformHistory ? (1.0 - exp(-dt / 0.032)) : 1.0

        let capacity = TelemetryScratchBox.waveformTrailCapacity
        let writeSlot = box.waveformTrailHead

        for i in 0..<pointCount {
            let pos = triggerPos + Double(i) * sampleStep
            let rawL = min(1.0, max(-1.0, interpolatedSample(box.frame.leftSamples, at: pos) * gainScale))
            let rawR = min(1.0, max(-1.0, interpolatedSample(box.frame.rightSamples, at: pos) * gainScale))

            let nextL = box.smoothedLeft[i] + (rawL - box.smoothedLeft[i]) * temporalAlpha
            let nextR = box.smoothedRight[i] + (rawR - box.smoothedRight[i]) * temporalAlpha
            box.smoothedLeft[i] = nextL
            box.smoothedRight[i] = nextR

            let x = CGFloat(i) * dx
            box.leftTrails[writeSlot][i] = CGPoint(x: x, y: midY - CGFloat(nextL) * amplitudeY)
            box.rightTrails[writeSlot][i] = CGPoint(x: x, y: midY - CGFloat(nextR) * amplitudeY)
        }
        box.hasWaveformHistory = true
        box.waveformTrailHead = (writeSlot + 1) % capacity
        box.waveformTrailCount = min(capacity, box.waveformTrailCount + 1)

        let alphaMultiplier = isPlaying || maxAbs > 1e-4 ? 1.0 : 0.45
        var glowContext = context
        glowContext.blendMode = .plusLighter

        // Draw decaying CRT phosphor persistence ribbons for both channels from oldest to newest
        // (suppressed when Reduce Motion is enabled for calm accessibility rendering).
        let total = box.waveformTrailCount
        if !reduceMotion && total > 1 {
            for ageIndex in 0..<(total - 1) {
                let slot = (writeSlot - (total - 1 - ageIndex) + capacity) % capacity
                let progress = Double(ageIndex + 1) / Double(total)
                let decay = pow(progress, 1.8)
                let haloOpacity = (0.025 + 0.13 * decay) * alphaMultiplier
                let coreOpacity = (0.045 + 0.28 * decay) * alphaMultiplier
                let haloWidth = 2.6 + CGFloat(progress) * 4.0
                let coreWidth = 1.0 + CGFloat(progress) * 1.1

                let trailRightPath = smoothPath(through: box.rightTrails[slot], count: pointCount)
                let trailLeftPath = smoothPath(through: box.leftTrails[slot], count: pointCount)

                glowContext.stroke(
                    trailRightPath,
                    with: .color(StudioTheme.rightTraceColor.opacity(haloOpacity)),
                    style: StrokeStyle(lineWidth: haloWidth, lineCap: .round, lineJoin: .round)
                )
                glowContext.stroke(
                    trailRightPath,
                    with: .color(StudioTheme.rightTraceColor.opacity(coreOpacity)),
                    style: StrokeStyle(lineWidth: coreWidth, lineCap: .round, lineJoin: .round)
                )
                glowContext.stroke(
                    trailLeftPath,
                    with: .color(StudioTheme.leftTraceColor.opacity(haloOpacity)),
                    style: StrokeStyle(lineWidth: haloWidth, lineCap: .round, lineJoin: .round)
                )
                glowContext.stroke(
                    trailLeftPath,
                    with: .color(StudioTheme.leftTraceColor.opacity(coreOpacity)),
                    style: StrokeStyle(lineWidth: coreWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }

        let leftPath = smoothPath(through: box.leftTrails[writeSlot], count: pointCount)
        let rightPath = smoothPath(through: box.rightTrails[writeSlot], count: pointCount)

        drawPhosphorTrace(
            path: rightPath,
            color: StudioTheme.rightTraceColor,
            intensity: alphaMultiplier,
            in: &glowContext
        )
        drawPhosphorTrace(
            path: leftPath,
            color: StudioTheme.leftTraceColor,
            intensity: alphaMultiplier,
            in: &glowContext
        )
    }

    private func drawLissajousGraticule(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let radius = min(size.width, size.height) * 0.41

        var axisPath = Path()
        axisPath.move(to: CGPoint(x: center.x - radius, y: center.y))
        axisPath.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        axisPath.move(to: CGPoint(x: center.x, y: center.y - radius))
        axisPath.addLine(to: CGPoint(x: center.x, y: center.y + radius))

        let diag = radius * 0.7071
        axisPath.move(to: CGPoint(x: center.x - diag, y: center.y + diag))
        axisPath.addLine(to: CGPoint(x: center.x + diag, y: center.y - diag))
        axisPath.move(to: CGPoint(x: center.x - diag, y: center.y - diag))
        axisPath.addLine(to: CGPoint(x: center.x + diag, y: center.y + diag))
        context.stroke(axisPath, with: .color(Color.white.opacity(0.09)), lineWidth: 0.65)

        let outerCircle = Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        let innerCircle = Path(ellipseIn: CGRect(
            x: center.x - radius * 0.5,
            y: center.y - radius * 0.5,
            width: radius,
            height: radius
        ))
        context.stroke(outerCircle, with: .color(Color.white.opacity(0.11)), lineWidth: 0.75)
        context.stroke(innerCircle, with: .color(Color.white.opacity(0.07)), lineWidth: 0.65)
    }

    private func drawLissajousPlot(
        in context: inout GraphicsContext,
        size: CGSize,
        dt: Double,
        box: TelemetryScratchBox
    ) {
        let sampleCount = min(box.frame.leftSamples.count, box.frame.rightSamples.count)
        let pointCount = TelemetryScratchBox.lissajousPointCount
        guard sampleCount >= pointCount, size.width > 1, size.height > 1 else { return }

        var maxAbs: Float = 0.0
        for i in 0..<sampleCount {
            let aL = abs(box.frame.leftSamples[i])
            let aR = abs(box.frame.rightSamples[i])
            if aL > maxAbs { maxAbs = aL }
            if aR > maxAbs { maxAbs = aR }
        }

        let centerX = size.width * 0.5
        let centerY = size.height * 0.5
        let radius = min(size.width, size.height) * 0.39

        if maxAbs < 1e-4 {
            box.lissajousTrailCount = 0
            let glowDot = Path(ellipseIn: CGRect(x: centerX - 6, y: centerY - 6, width: 12, height: 12))
            let coreDot = Path(ellipseIn: CGRect(x: centerX - 2.5, y: centerY - 2.5, width: 5, height: 5))
            context.fill(glowDot, with: .color(dominantBand.accentColor.opacity(0.28)))
            context.fill(coreDot, with: .color(dominantBand.accentColor))
            return
        }

        let targetGain = min(3.0, 0.90 / max(0.24, Double(maxAbs)))
        box.smoothedLissajousGain = smoothAutoGain(
            current: box.smoothedLissajousGain,
            target: targetGain,
            dt: dt,
            snap: box.lissajousTrailCount == 0
        )

        let gainScale = box.smoothedLissajousGain
        let sampleStep = Double(sampleCount - 1) / Double(pointCount - 1)

        // Sub-sample fractional indexing eliminates uneven integer decimation steps.
        for i in 0..<pointCount {
            let pos = Double(i) * sampleStep
            box.lissajousRawX[i] = min(1.0, max(-1.0, interpolatedSample(box.frame.leftSamples, at: pos) * gainScale))
            box.lissajousRawY[i] = min(1.0, max(-1.0, interpolatedSample(box.frame.rightSamples, at: pos) * gainScale))
        }

        // Write into the next slot of the CRT phosphor persistence ring buffer,
        // applying a gentle 3-tap [0.25, 0.5, 0.25] spatial filter to keep curves silky even with noise.
        let capacity = TelemetryScratchBox.lissajousTrailCapacity
        let writeSlot = box.lissajousTrailHead
        for i in 0..<pointCount {
            let xVal: Double
            let yVal: Double
            if i == 0 || i == pointCount - 1 {
                xVal = box.lissajousRawX[i]
                yVal = box.lissajousRawY[i]
            } else {
                xVal = 0.25 * box.lissajousRawX[i - 1] + 0.5 * box.lissajousRawX[i] + 0.25 * box.lissajousRawX[i + 1]
                yVal = 0.25 * box.lissajousRawY[i - 1] + 0.5 * box.lissajousRawY[i] + 0.25 * box.lissajousRawY[i + 1]
            }
            box.lissajousTrails[writeSlot][i] = CGPoint(
                x: centerX + CGFloat(xVal) * radius,
                y: centerY - CGFloat(yVal) * radius
            )
        }

        box.lissajousTrailHead = (writeSlot + 1) % capacity
        box.lissajousTrailCount = min(capacity, box.lissajousTrailCount + 1)

        // Draw rich additive CRT phosphor afterglow trails from oldest to newest.
        var glowContext = context
        glowContext.blendMode = .plusLighter

        let total = box.lissajousTrailCount
        if !reduceMotion && total > 1 {
            for ageIndex in 0..<(total - 1) {
                let slot = (writeSlot - (total - 1 - ageIndex) + capacity) % capacity
                let progress = Double(ageIndex + 1) / Double(total)
                let decay = pow(progress, 1.7)
                let haloOpacity = 0.025 + 0.14 * decay
                let coreOpacity = 0.05 + 0.34 * decay
                let trailPath = smoothPath(through: box.lissajousTrails[slot], count: pointCount)

                glowContext.stroke(
                    trailPath,
                    with: .color(dominantBand.accentColor.opacity(haloOpacity)),
                    style: StrokeStyle(lineWidth: 3.0 + CGFloat(progress) * 4.5, lineCap: .round, lineJoin: .round)
                )
                glowContext.stroke(
                    trailPath,
                    with: .color(dominantBand.accentColor.opacity(coreOpacity)),
                    style: StrokeStyle(lineWidth: 1.1 + CGFloat(progress) * 1.4, lineCap: .round, lineJoin: .round)
                )
            }
        }

        let currentPath = smoothPath(through: box.lissajousTrails[writeSlot], count: pointCount)
        drawPhosphorTrace(path: currentPath, color: dominantBand.accentColor, intensity: 1.0, in: &glowContext)
    }

    private func drawBandMonitorAmbientBars(
        in context: inout GraphicsContext,
        size: CGSize,
        frame: TelemetryFrame
    ) {
        let rmsL = LEDMeterView.normalizedMeterLevel(for: frame.rmsL)
        let rmsR = LEDMeterView.normalizedMeterLevel(for: frame.rmsR)
        let maxHeight = size.height * 0.14
        let barWidth = size.width * 0.38
        let yBottom = size.height - 8

        let leftHeight = max(2.0, CGFloat(rmsL) * maxHeight)
        let rightHeight = max(2.0, CGFloat(rmsR) * maxHeight)

        let leftRect = CGRect(
            x: 14,
            y: yBottom - leftHeight,
            width: barWidth,
            height: leftHeight
        )
        let rightRect = CGRect(
            x: size.width - 14 - barWidth,
            y: yBottom - rightHeight,
            width: barWidth,
            height: rightHeight
        )

        context.fill(
            Path(roundedRect: leftRect, cornerRadius: 2),
            with: .color(StudioTheme.leftTraceColor.opacity(0.32))
        )
        context.fill(
            Path(roundedRect: rightRect, cornerRadius: 2),
            with: .color(StudioTheme.rightTraceColor.opacity(0.32))
        )
    }

    private func drawPhosphorTrace(
        path: Path,
        color: Color,
        intensity: Double = 1.0,
        in context: inout GraphicsContext
    ) {
        context.stroke(
            path,
            with: .color(color.opacity(0.16 * intensity)),
            style: StrokeStyle(lineWidth: 9.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color.opacity(0.36 * intensity)),
            style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color.opacity(0.95 * intensity)),
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(Color.white.opacity(0.55 * intensity)),
            style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round)
        )
    }

    private var accessibilityDescription: String {
        "\(displayMode.localizedTitle), \(dominantBand.localizedTitle), \(StudioTheme.formatFrequency(dominantBeatHz)), \(clampedVoiceCount)/\(SynthSnapshot.maxVoices)"
    }
}

#if os(macOS)
/// Tracks macOS `NSWindow.occlusionState` so `OscilloscopeView` pauses GPU rendering while minimized or occluded.
private struct OscilloscopeWindowVisibilityBridge: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    func makeNSView(context: Context) -> WindowObserverNSView {
        let view = WindowObserverNSView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObserverNSView, context: Context) {
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowObserverNSView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class WindowObserverNSView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isVisible: Binding<Bool>
        private weak var observedWindow: NSWindow?

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
        }

        func attach(to window: NSWindow?) {
            guard observedWindow !== window else {
                refreshVisibility()
                return
            }
            detach()
            observedWindow = window
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleOcclusionStateChanged(_:)),
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: window
                )
            }
            refreshVisibility()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
        }

        @objc private func handleOcclusionStateChanged(_ notification: Notification) {
            refreshVisibility()
        }

        private func refreshVisibility() {
            let visible = observedWindow?.occlusionState.contains(.visible) ?? true
            if isVisible.wrappedValue != visible {
                isVisible.wrappedValue = visible
            }
        }
    }
}
#endif
