import SwiftUI
import SynthCore
import UIKit

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
    static let lissajousPointCount = 384

    var frame = TelemetryFrame()
    var leftPoints = [CGPoint](repeating: .zero, count: TelemetryScratchBox.waveformPointCount)
    var rightPoints = [CGPoint](repeating: .zero, count: TelemetryScratchBox.waveformPointCount)
    var lissajousPoints = [CGPoint](repeating: .zero, count: TelemetryScratchBox.lissajousPointCount)
}

/// 60–120 fps studio CRT/OLED oscilloscope backed by `TelemetryRingBuffer`.
/// Tap to cycle `.waveform`, `.lissajous`, and `.bandMonitor` modes.
public struct OscilloscopeView: View {
    private let telemetryBuffer: TelemetryRingBuffer
    private let dominantBeatHz: Double
    private let dominantBand: BrainwaveBand
    private let activeVoiceCount: Int
    private let isPlaying: Bool

    @State private var displayMode: OscilloscopeDisplayMode
    @State private var scratch = TelemetryScratchBox()
    @State private var modeCycleHaptic = UIImpactFeedbackGenerator(style: .light)

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

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StudioTheme.recessedWell)

            TimelineView(.animation(paused: !isPlaying)) { _ in
                Canvas { context, size in
                    let box = scratch
                    telemetryBuffer.readLatest(into: &box.frame)

                    switch displayMode {
                    case .waveform:
                        drawWaveformGraticule(in: &context, size: size)
                        drawStereoWaveform(in: &context, size: size, box: box)
                    case .lissajous:
                        drawLissajousGraticule(in: &context, size: size)
                        drawLissajousPlot(in: &context, size: size, box: box)
                    case .bandMonitor:
                        drawWaveformGraticule(in: &context, size: size, subtle: true)
                        drawBandMonitorAmbientBars(in: &context, size: size, frame: box.frame)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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
            modeCycleHaptic.prepare()
            withAnimation(.easeInOut(duration: 0.18)) {
                displayMode = displayMode.next()
            }
            modeCycleHaptic.impactOccurred(intensity: 0.65)
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

    private func drawStereoWaveform(
        in context: inout GraphicsContext,
        size: CGSize,
        box: TelemetryScratchBox
    ) {
        let sampleCount = box.frame.leftSamples.count
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

        // Rising zero-crossing trigger on Left channel stabilizes stationary carrier cycles
        // while allowing Right channel binaural phase drift to glide cleanly.
        var triggerIndex = 0
        if maxAbs > 1e-4 {
            let searchLimit = sampleCount - windowLength
            for i in 1..<searchLimit {
                if box.frame.leftSamples[i - 1] < 0.0 && box.frame.leftSamples[i] >= 0.0 {
                    triggerIndex = i
                    break
                }
            }
        }

        let gainScale = min(3.2, 0.86 / max(0.22, Double(maxAbs)))
        let midY = size.height * 0.5
        let dx = size.width / CGFloat(pointCount - 1)
        let stride = windowLength / pointCount

        for i in 0..<pointCount {
            let idx = min(sampleCount - 1, triggerIndex + i * stride)
            let x = CGFloat(i) * dx
            let sampleL = Double(box.frame.leftSamples[idx])
            let sampleR = Double(box.frame.rightSamples[idx])
            let clampedL = min(1.0, max(-1.0, sampleL * gainScale))
            let clampedR = min(1.0, max(-1.0, sampleR * gainScale))

            box.leftPoints[i] = CGPoint(x: x, y: midY - CGFloat(clampedL) * (size.height * 0.42))
            box.rightPoints[i] = CGPoint(x: x, y: midY - CGFloat(clampedR) * (size.height * 0.42))
        }

        var leftPath = Path()
        leftPath.addLines(box.leftPoints)
        var rightPath = Path()
        rightPath.addLines(box.rightPoints)

        let alphaMultiplier = isPlaying || maxAbs > 1e-4 ? 1.0 : 0.45
        drawPhosphorTrace(path: rightPath, color: StudioTheme.rightTraceColor.opacity(alphaMultiplier), in: &context)
        drawPhosphorTrace(path: leftPath, color: StudioTheme.leftTraceColor.opacity(alphaMultiplier), in: &context)
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
            let glowDot = Path(ellipseIn: CGRect(x: centerX - 6, y: centerY - 6, width: 12, height: 12))
            let coreDot = Path(ellipseIn: CGRect(x: centerX - 2.5, y: centerY - 2.5, width: 5, height: 5))
            context.fill(glowDot, with: .color(dominantBand.accentColor.opacity(0.28)))
            context.fill(coreDot, with: .color(dominantBand.accentColor))
            return
        }

        let gainScale = min(3.0, 0.90 / max(0.24, Double(maxAbs)))
        let lastSampleIndex = sampleCount - 1

        for i in 0..<pointCount {
            let sampleIdx = (i * lastSampleIndex) / (pointCount - 1)
            let xVal = min(1.0, max(-1.0, Double(box.frame.leftSamples[sampleIdx]) * gainScale))
            let yVal = min(1.0, max(-1.0, Double(box.frame.rightSamples[sampleIdx]) * gainScale))
            box.lissajousPoints[i] = CGPoint(
                x: centerX + CGFloat(xVal) * radius,
                y: centerY - CGFloat(yVal) * radius
            )
        }

        var path = Path()
        path.addLines(box.lissajousPoints)
        drawPhosphorTrace(path: path, color: dominantBand.accentColor, in: &context)
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
        in context: inout GraphicsContext
    ) {
        context.stroke(
            path,
            with: .color(color.opacity(0.22)),
            style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color.opacity(0.42)),
            style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }

    private var accessibilityDescription: String {
        "\(displayMode.localizedTitle), \(dominantBand.localizedTitle), \(StudioTheme.formatFrequency(dominantBeatHz)), \(clampedVoiceCount)/\(SynthSnapshot.maxVoices)"
    }
}
