import PresetKit
import SwiftUI
import SynthCore

/// Derived sparkline contour and dominant brainwave metadata for a `Preset`.
public struct PresetSparklineSummary: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let fraction: Double
        public let beatHz: Double
        public let normalizedY: Double
    }

    public let samples: [Sample]
    public let dominantBeatHz: Double
    public let dominantBand: BrainwaveBand
    public let minBeatHz: Double
    public let maxBeatHz: Double

    /// Samples the primary audible voice's compiled `beatCurve` across the preset duration.
    public static func analyze(_ preset: Preset, sampleCount: Int = 48) -> PresetSparklineSummary {
        let count = max(2, sampleCount)
        let snapshot = SnapshotCompiler.compile(preset)
        let duration = snapshot.durationSec > 0 ? snapshot.durationSec : max(1.0, preset.durationSec)

        guard let primaryVoice = selectPrimaryVoice(from: snapshot.voices, duration: duration) else {
            let flatSamples = (0..<count).map { index in
                Sample(fraction: Double(index) / Double(count - 1), beatHz: 0.0, normalizedY: 0.5)
            }
            return PresetSparklineSummary(
                samples: flatSamples,
                dominantBeatHz: 0.0,
                dominantBand: .delta,
                minBeatHz: 0.0,
                maxBeatHz: 0.0
            )
        }

        var rawBeats: [Double] = []
        rawBeats.reserveCapacity(count)

        for index in 0..<count {
            let fraction = Double(index) / Double(count - 1)
            let timeSec = fraction * duration
            let rawBeat = primaryVoice.beatCurve.evaluate(at: timeSec)
            let beatHz = rawBeat.isFinite ? max(0.0, rawBeat) : 0.0
            rawBeats.append(beatHz)
        }

        let minHz = rawBeats.min() ?? 0.0
        let maxHz = rawBeats.max() ?? 0.0
        let span = maxHz - minHz

        let samples: [Sample] = rawBeats.enumerated().map { index, beatHz in
            let fraction = Double(index) / Double(count - 1)
            let normalizedY: Double
            if span > 0.25 {
                let scaled = (beatHz - minHz) / span
                normalizedY = 0.16 + scaled * 0.68
            } else {
                normalizedY = 0.5
            }
            return Sample(fraction: fraction, beatHz: beatHz, normalizedY: normalizedY)
        }

        let sortedBeats = rawBeats.sorted()
        let dominantBeat = sortedBeats[sortedBeats.count / 2]
        let dominantBand = BrainwaveBand.from(frequencyHz: dominantBeat)

        return PresetSparklineSummary(
            samples: samples,
            dominantBeatHz: dominantBeat,
            dominantBand: dominantBand,
            minBeatHz: minHz,
            maxBeatHz: maxHz
        )
    }

    private static func selectPrimaryVoice(from voices: [VoiceSnapshot], duration: Double) -> VoiceSnapshot? {
        let capped = Array(voices.prefix(SynthSnapshot.maxVoices))
        guard !capped.isEmpty else { return nil }

        let hasSolo = capped.contains { $0.isEnabled && $0.isSolo }
        let audible = capped.filter { $0.isEnabled && !$0.isMuted && (!hasSolo || $0.isSolo) }
        let enabled = capped.filter(\.isEnabled)
        let candidates = !audible.isEmpty ? audible : (!enabled.isEmpty ? enabled : capped)

        let probeFractions = [0.0, 0.25, 0.5, 0.75, 1.0]
        var bestVoice = candidates[0]
        var bestAverageVolume = -Double.infinity

        for voice in candidates {
            var totalVolume = 0.0
            for fraction in probeFractions {
                let rawVol = voice.volumeCurve.evaluate(at: fraction * duration)
                let clamped = rawVol.isFinite ? min(1.0, max(0.0, rawVol)) : 0.0
                totalVolume += clamped
            }
            let average = totalVolume / Double(probeFractions.count)
            if average > bestAverageVolume {
                bestAverageVolume = average
                bestVoice = voice
            }
        }

        return bestVoice
    }
}

/// Lightweight `Canvas` rendering a preset's primary voice `beatCurve` contour
/// colored by its dominant brainwave band.
public struct PresetSparklineView: View {
    private let summary: PresetSparklineSummary
    private let bandOverride: BrainwaveBand?

    public init(preset: Preset, bandOverride: BrainwaveBand? = nil) {
        self.summary = PresetSparklineSummary.analyze(preset)
        self.bandOverride = bandOverride
    }

    public init(summary: PresetSparklineSummary, bandOverride: BrainwaveBand? = nil) {
        self.summary = summary
        self.bandOverride = bandOverride
    }

    private var accentColor: Color {
        (bandOverride ?? summary.dominantBand).accentColor
    }

    public var body: some View {
        Canvas { context, size in
            drawContour(in: &context, size: size)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioTheme.recessedWell)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Beat Frequency"))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let band = bandOverride ?? summary.dominantBand
        if abs(summary.maxBeatHz - summary.minBeatHz) > 0.25 {
            let minText = StudioTheme.formatFrequencyNumber(summary.minBeatHz)
            let maxText = StudioTheme.formatFrequency(summary.maxBeatHz)
            return "\(band.localizedTitle), \(minText)–\(maxText)"
        }
        return "\(band.localizedTitle), \(StudioTheme.formatFrequency(summary.dominantBeatHz))"
    }

    private func drawContour(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 4, size.height > 4 else { return }

        // Midline reference graticule
        let midY = size.height * 0.5
        var graticule = Path()
        graticule.move(to: CGPoint(x: 0, y: midY))
        graticule.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(graticule, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)

        let samples = summary.samples
        guard samples.count >= 2 else { return }

        let insetX: CGFloat = 5.0
        let insetY: CGFloat = 5.0
        let usableWidth = max(1.0, size.width - insetX * 2.0)
        let usableHeight = max(2.0, size.height - insetY * 2.0)

        var linePath = Path()
        var fillPath = Path()
        var firstPoint = CGPoint.zero
        var lastPoint = CGPoint.zero

        for (index, sample) in samples.enumerated() {
            let x = insetX + CGFloat(sample.fraction) * usableWidth
            let y = size.height - insetY - CGFloat(sample.normalizedY) * usableHeight
            let point = CGPoint(x: x, y: y)

            if index == 0 {
                firstPoint = point
                linePath.move(to: point)
                fillPath.move(to: CGPoint(x: point.x, y: size.height))
                fillPath.addLine(to: point)
            } else {
                linePath.addLine(to: point)
                fillPath.addLine(to: point)
            }
            lastPoint = point
        }

        fillPath.addLine(to: CGPoint(x: lastPoint.x, y: size.height))
        fillPath.closeSubpath()

        context.fill(
            fillPath,
            with: .linearGradient(
                Gradient(colors: [accentColor.opacity(0.24), accentColor.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        context.stroke(
            linePath,
            with: .color(accentColor.opacity(0.32)),
            style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round)
        )

        context.stroke(
            linePath,
            with: .color(accentColor),
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        )

        let dotRadius: CGFloat = 2.0
        for endpoint in [firstPoint, lastPoint] {
            let dotRect = CGRect(
                x: endpoint.x - dotRadius,
                y: endpoint.y - dotRadius,
                width: dotRadius * 2.0,
                height: dotRadius * 2.0
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(accentColor))
        }
    }
}
