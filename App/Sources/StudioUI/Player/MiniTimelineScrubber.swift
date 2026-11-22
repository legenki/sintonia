import PresetKit
import SwiftUI
import SynthCore
import UIKit

/// Interactive session beat-frequency sparkline timeline with elapsed progress fill,
/// elapsed/remaining readouts, and drag-to-seek scrubbing.
public struct MiniTimelineScrubber: View {
    private let engine: AudioEngineController

    @State private var samples: [SparklineSample]
    @GestureState private var isScrubbing = false
    @State private var scrubTime: Double = 0.0
    @State private var lastSeekCommittedTime: Double = -.infinity
    @State private var scrubHaptic = UIImpactFeedbackGenerator(style: .light)

    private struct SparklineSample: Equatable {
        let fraction: Double
        let beatHz: Double
        let normalizedY: Double
    }

    private static let sampleCount = 96

    public init(engine: AudioEngineController) {
        self.engine = engine
        self._samples = State(initialValue: Self.buildSamples(for: engine.currentPreset))
    }

    private var effectiveDuration: Double {
        let raw = engine.duration > 0 ? engine.duration : engine.currentPreset.durationSec
        return raw.isFinite && raw > 0 ? raw : 1.0
    }

    private var displayedTime: Double {
        let raw = isScrubbing ? scrubTime : engine.currentTime
        guard raw.isFinite else { return 0.0 }
        return min(effectiveDuration, max(0.0, raw))
    }

    private var progress: Double {
        min(1.0, max(0.0, displayedTime / effectiveDuration))
    }

    private var displayedBeatHz: Double {
        guard !samples.isEmpty else { return engine.dominantBeatHz }
        let idx = min(samples.count - 1, max(0, Int((progress * Double(samples.count - 1)).rounded())))
        return isScrubbing ? samples[idx].beatHz : engine.dominantBeatHz
    }

    private var accentColor: Color {
        BrainwaveBand.from(frequencyHz: displayedBeatHz).accentColor
    }

    public var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StudioTheme.recessedWell)

                    Canvas { context, canvasSize in
                        drawSparkline(in: &context, size: canvasSize)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if isScrubbing {
                        scrubPreviewPill(width: size.width)
                            .offset(y: -26)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isScrubbing ? accentColor.opacity(0.55) : StudioTheme.hairlineHighlight,
                            lineWidth: isScrubbing ? 1.0 : 0.75
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isScrubbing) { _, state, _ in
                            state = true
                        }
                        .onChanged { gesture in
                            handleDragChanged(locationX: gesture.location.x, width: size.width)
                        }
                        .onEnded { gesture in
                            handleDragEnded(locationX: gesture.location.x, width: size.width)
                        }
                )
            }
            .frame(height: 44)

            HStack(spacing: 8) {
                Text(verbatim: StudioTheme.formatTime(displayedTime))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isScrubbing ? accentColor : StudioTheme.primaryText)

                Spacer(minLength: 4)

                Text(verbatim: StudioTheme.formatFrequency(displayedBeatHz))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.mutedText)

                Spacer(minLength: 4)

                Text(verbatim: "-\(StudioTheme.formatTime(max(0.0, effectiveDuration - displayedTime)))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(.horizontal, 2)
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                scrubHaptic.prepare()
                scrubHaptic.impactOccurred(intensity: 0.45)
            }
        }
        .onChange(of: engine.currentPreset) { _, newPreset in
            samples = Self.buildSamples(for: newPreset)
        }
        .animation(.easeOut(duration: 0.14), value: isScrubbing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Timeline"))
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            let step = min(30.0, max(5.0, effectiveDuration * 0.02))
            switch direction {
            case .increment:
                engine.seek(to: displayedTime + step)
            case .decrement:
                engine.seek(to: displayedTime - step)
            @unknown default:
                break
            }
        }
    }

    private func scrubPreviewPill(width: CGFloat) -> some View {
        let clampedX = min(max(36, CGFloat(progress) * width), max(36, width - 36))
        return Text(verbatim: "\(StudioTheme.formatTime(displayedTime)) • \(StudioTheme.formatFrequency(displayedBeatHz))")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(StudioTheme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(StudioTheme.elevatedSurface)
                    .shadow(color: StudioTheme.hardwareShadow, radius: 4, x: 0, y: 2)
            }
            .overlay {
                Capsule()
                    .strokeBorder(accentColor.opacity(0.65), lineWidth: 0.85)
            }
            .position(x: clampedX, y: 10)
            .allowsHitTesting(false)
    }

    private func drawSparkline(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }

        // Midline reference graticule
        var gridPath = Path()
        let midY = size.height * 0.5
        gridPath.move(to: CGPoint(x: 0, y: midY))
        gridPath.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(gridPath, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)

        let playheadX = CGFloat(progress) * size.width

        // Subtle elapsed tint background
        if playheadX > 0 {
            let elapsedRect = CGRect(x: 0, y: 0, width: playheadX, height: size.height)
            context.fill(Path(elapsedRect), with: .color(accentColor.opacity(0.08)))
        }

        guard samples.count >= 2 else { return }

        let insetY: CGFloat = 6.0
        let usableHeight = max(4.0, size.height - insetY * 2.0)

        var fullLine = Path()
        var points: [CGPoint] = []
        points.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            let x = CGFloat(sample.fraction) * size.width
            let y = size.height - insetY - CGFloat(sample.normalizedY) * usableHeight
            let pt = CGPoint(x: x, y: y)
            points.append(pt)
            if index == 0 {
                fullLine.move(to: pt)
            } else {
                fullLine.addLine(to: pt)
            }
        }

        // Remaining (full) sparkline trace in subtle muted slate
        context.stroke(
            fullLine,
            with: .color(StudioTheme.mutedText.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )

        // Elapsed portion fill and luminous accent trace
        if playheadX > 0.5 {
            let playheadY = interpolatedY(atFraction: progress, points: points, fallback: midY)

            var elapsedLine = Path()
            var elapsedArea = Path()
            var started = false

            for (index, sample) in samples.enumerated() {
                if sample.fraction <= progress {
                    let pt = points[index]
                    if !started {
                        elapsedLine.move(to: pt)
                        elapsedArea.move(to: CGPoint(x: pt.x, y: size.height))
                        elapsedArea.addLine(to: pt)
                        started = true
                    } else {
                        elapsedLine.addLine(to: pt)
                        elapsedArea.addLine(to: pt)
                    }
                }
            }

            let playheadPoint = CGPoint(x: playheadX, y: playheadY)
            if started {
                elapsedLine.addLine(to: playheadPoint)
                elapsedArea.addLine(to: playheadPoint)
                elapsedArea.addLine(to: CGPoint(x: playheadX, y: size.height))
                elapsedArea.closeSubpath()

                context.fill(
                    elapsedArea,
                    with: .linearGradient(
                        Gradient(colors: [accentColor.opacity(0.28), accentColor.opacity(0.03)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                context.stroke(
                    elapsedLine,
                    with: .color(accentColor.opacity(0.32)),
                    style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    elapsedLine,
                    with: .color(accentColor),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // Playhead hairline and glowing node
        var playheadLine = Path()
        playheadLine.move(to: CGPoint(x: playheadX, y: 2))
        playheadLine.addLine(to: CGPoint(x: playheadX, y: size.height - 2))
        context.stroke(playheadLine, with: .color(StudioTheme.primaryText.opacity(0.88)), lineWidth: 1.4)

        let playheadY = interpolatedY(atFraction: progress, points: points, fallback: midY)
        let knobRadius: CGFloat = isScrubbing ? 4.5 : 3.5
        let haloRadius: CGFloat = knobRadius + 3.0
        context.fill(
            Path(ellipseIn: CGRect(
                x: playheadX - haloRadius,
                y: playheadY - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )),
            with: .color(accentColor.opacity(0.35))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: playheadX - knobRadius,
                y: playheadY - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )),
            with: .color(StudioTheme.primaryText)
        )
    }

    private func interpolatedY(atFraction fraction: Double, points: [CGPoint], fallback: CGFloat) -> CGFloat {
        guard !points.isEmpty else { return fallback }
        guard points.count > 1 else { return points[0].y }
        let clamped = min(1.0, max(0.0, fraction))
        let scaled = clamped * Double(points.count - 1)
        let lower = Int(floor(scaled))
        let upper = min(points.count - 1, lower + 1)
        let t = CGFloat(scaled - Double(lower))
        return points[lower].y * (1.0 - t) + points[upper].y * t
    }

    private func handleDragChanged(locationX: CGFloat, width: CGFloat) {
        let safeWidth = max(1.0, width)
        let fraction = min(1.0, max(0.0, Double(locationX / safeWidth)))
        let targetTime = fraction * effectiveDuration

        scrubTime = targetTime

        if abs(targetTime - lastSeekCommittedTime) >= 0.25 {
            lastSeekCommittedTime = targetTime
            engine.seek(to: targetTime)
        }
    }

    private func handleDragEnded(locationX: CGFloat, width: CGFloat) {
        let safeWidth = max(1.0, width)
        let fraction = min(1.0, max(0.0, Double(locationX / safeWidth)))
        let targetTime = fraction * effectiveDuration

        lastSeekCommittedTime = targetTime
        engine.seek(to: targetTime)
        scrubHaptic.impactOccurred(intensity: 0.55)
    }

    private var accessibilityValueText: String {
        let elapsed = StudioTheme.formatTime(displayedTime)
        let remaining = StudioTheme.formatTime(max(0.0, effectiveDuration - displayedTime))
        return "\(elapsed), -\(remaining), \(StudioTheme.formatFrequency(displayedBeatHz))"
    }

    private static func buildSamples(for preset: Preset) -> [SparklineSample] {
        let snapshot = SnapshotCompiler.compile(preset)
        let duration = snapshot.durationSec > 0 ? snapshot.durationSec : max(1.0, preset.durationSec)
        let voices = Array(snapshot.voices.prefix(SynthSnapshot.maxVoices))
        let hasSolo = voices.contains { $0.isEnabled && $0.isSolo }
        let audibleVoices = voices.filter { $0.isEnabled && !$0.isMuted && (!hasSolo || $0.isSolo) }

        var rawBeats: [Double] = []
        rawBeats.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let fraction = Double(i) / Double(sampleCount - 1)
            let t = fraction * duration

            var bestVol = -Double.infinity
            var bestBeat = 0.0
            for voice in audibleVoices {
                let vol = min(1.0, max(0.0, voice.volumeCurve.evaluate(at: t)))
                let beat = max(0.0, voice.beatCurve.evaluate(at: t))
                if vol > bestVol {
                    bestVol = vol
                    bestBeat = beat
                }
            }
            rawBeats.append(bestBeat)
        }

        let minHz = rawBeats.min() ?? 0.0
        let maxHz = rawBeats.max() ?? 0.0
        let span = maxHz - minHz

        return rawBeats.enumerated().map { index, beatHz in
            let fraction = Double(index) / Double(sampleCount - 1)
            let normalizedY: Double
            if span > 0.25 {
                let rawNorm = (beatHz - minHz) / span
                normalizedY = 0.14 + rawNorm * 0.72
            } else {
                normalizedY = 0.5
            }
            return SparklineSample(fraction: fraction, beatHz: beatHz, normalizedY: normalizedY)
        }
    }
}
