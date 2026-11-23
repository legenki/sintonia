import SwiftUI
import SynthCore

public extension Waveform {
    /// Localized hardware button label matching `Localizable.xcstrings`.
    var localizedTitle: String {
        switch self {
        case .sine: return String(localized: "Sine")
        case .sineSquared: return String(localized: "Sine²")
        case .triangle: return String(localized: "Triangle")
        case .square: return String(localized: "Square")
        case .smoothSquare: return String(localized: "Smooth Square")
        }
    }
}

public extension EntrainmentMode {
    /// Localized hardware button label matching `Localizable.xcstrings`.
    var localizedTitle: String {
        switch self {
        case .binaural: return String(localized: "Binaural")
        case .monaural: return String(localized: "Monaural")
        case .isochronic: return String(localized: "Isochronic")
        }
    }
}

/// Custom mathematical vector waveform glyph matching `SynthCore` oscillator shapes.
public struct WaveformGlyphShape: Shape {
    public let waveform: Waveform

    public init(waveform: Waveform) {
        self.waveform = waveform
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1 else { return path }

        let midY = rect.midY
        let amp = rect.height * 0.40

        switch waveform {
        case .sine:
            let steps = 56
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let y = -sin(2.0 * .pi * 1.25 * t)
                let pt = CGPoint(x: rect.minX + CGFloat(t) * rect.width, y: midY + CGFloat(y) * amp)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }

        case .sineSquared:
            let steps = 56
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let s = sin(.pi * 2.0 * t)
                let y = -(2.0 * s * s - 1.0)
                let pt = CGPoint(x: rect.minX + CGFloat(t) * rect.width, y: midY + CGFloat(y) * amp)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }

        case .triangle:
            let vertices: [(CGFloat, CGFloat)] = [
                (0.0, 0.0),
                (0.20, -1.0),
                (0.60, 1.0),
                (0.90, -0.5),
                (1.0, 0.0)
            ]
            for (index, v) in vertices.enumerated() {
                let pt = CGPoint(x: rect.minX + v.0 * rect.width, y: midY + v.1 * amp)
                if index == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }

        case .square:
            let vertices: [(CGFloat, CGFloat)] = [
                (0.0, 0.0),
                (0.0, -1.0),
                (1.0 / 3.0, -1.0),
                (1.0 / 3.0, 1.0),
                (2.0 / 3.0, 1.0),
                (2.0 / 3.0, -1.0),
                (1.0, -1.0)
            ]
            for (index, v) in vertices.enumerated() {
                let pt = CGPoint(x: rect.minX + v.0 * rect.width, y: midY + v.1 * amp)
                if index == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }

        case .smoothSquare:
            let steps = 64
            let norm = tanh(3.5)
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let y = -(tanh(3.5 * sin(2.0 * .pi * 1.25 * t)) / norm)
                let pt = CGPoint(x: rect.minX + CGFloat(t) * rect.width, y: midY + CGFloat(y) * amp)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }

        return path
    }
}

/// Custom vector icon glyph representing each `EntrainmentMode`.
public struct ModeGlyphShape: Shape {
    public let mode: EntrainmentMode

    public init(mode: EntrainmentMode) {
        self.mode = mode
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1 else { return path }

        switch mode {
        case .binaural:
            let cx = rect.midX
            let cy = rect.midY
            let r = min(rect.width, rect.height) * 0.42
            // Headphone band arc
            path.addArc(
                center: CGPoint(x: cx, y: cy + r * 0.08),
                radius: r,
                startAngle: .degrees(190),
                endAngle: .degrees(350),
                clockwise: false
            )
            // Left and right ear cups
            let cupW = max(3.5, r * 0.42)
            let cupH = max(5.5, r * 0.72)
            path.addRoundedRect(
                in: CGRect(x: cx - r - cupW * 0.35, y: cy, width: cupW, height: cupH),
                cornerSize: CGSize(width: 2, height: 2)
            )
            path.addRoundedRect(
                in: CGRect(x: cx + r - cupW * 0.65, y: cy, width: cupW, height: cupH),
                cornerSize: CGSize(width: 2, height: 2)
            )

        case .monaural:
            let cx = rect.midX
            let cy = rect.midY
            let r = min(rect.width, rect.height) * 0.42
            // Concentric blended wave rings representing single-channel acoustic sum
            path.addEllipse(in: CGRect(x: cx - r * 0.22, y: cy - r * 0.22, width: r * 0.44, height: r * 0.44))
            path.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r * 0.65,
                startAngle: .degrees(-55),
                endAngle: .degrees(55),
                clockwise: false
            )
            path.move(to: CGPoint(
                x: cx + r * 0.65 * cos(125.0 * .pi / 180.0),
                y: cy + r * 0.65 * sin(125.0 * .pi / 180.0)
            ))
            path.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r * 0.65,
                startAngle: .degrees(125),
                endAngle: .degrees(235),
                clockwise: false
            )
            path.move(to: CGPoint(
                x: cx + r * cos(-55.0 * .pi / 180.0),
                y: cy + r * sin(-55.0 * .pi / 180.0)
            ))
            path.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r,
                startAngle: .degrees(-55),
                endAngle: .degrees(55),
                clockwise: false
            )
            path.move(to: CGPoint(
                x: cx + r * cos(125.0 * .pi / 180.0),
                y: cy + r * sin(125.0 * .pi / 180.0)
            ))
            path.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r,
                startAngle: .degrees(125),
                endAngle: .degrees(235),
                clockwise: false
            )

        case .isochronic:
            // Two crisp trapezoidal amplitude pulses matching `IsochronicEnvelope`
            let bottom = rect.maxY - rect.height * 0.22
            let top = rect.minY + rect.height * 0.22
            let vertices: [(CGFloat, CGFloat)] = [
                (0.0, bottom),
                (0.08, bottom),
                (0.16, top),
                (0.36, top),
                (0.44, bottom),
                (0.56, bottom),
                (0.64, top),
                (0.84, top),
                (0.92, bottom),
                (1.0, bottom)
            ]
            for (idx, pt) in vertices.enumerated() {
                let cgPt = CGPoint(x: rect.minX + pt.0 * rect.width, y: pt.1)
                if idx == 0 { path.move(to: cgPt) } else { path.addLine(to: cgPt) }
            }
        }

        return path
    }
}

/// Shared GarageBand backlit pushbutton frame used by both `WaveformPicker` and `ModePicker`.
private struct BacklitHardwareKeycap<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let showsLabel: Bool
    let action: () -> Void
    @ViewBuilder let icon: (_ isSelected: Bool) -> Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: showsLabel ? 4 : 0) {
                Capsule()
                    .fill(isSelected ? accentColor : StudioTheme.ledOff)
                    .frame(width: 16, height: 2.5)
                    .shadow(color: isSelected ? accentColor.opacity(0.9) : .clear, radius: 4)

                icon(isSelected)

                if showsLabel {
                    Text(title)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? StudioTheme.primaryText : StudioTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(
                                colors: [
                                    accentColor.opacity(0.24),
                                    StudioTheme.elevatedSurface,
                                    StudioTheme.obsidianSurface
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [
                                    StudioTheme.elevatedSurface.opacity(0.72),
                                    StudioTheme.obsidianSurface
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? accentColor.opacity(0.7) : StudioTheme.hairlineHighlight,
                        lineWidth: isSelected ? 1.15 : 0.75
                    )
            }
            .shadow(
                color: isSelected ? accentColor.opacity(0.22) : Color.black.opacity(0.35),
                radius: isSelected ? 6 : 2,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 5-option backlit GarageBand pushbutton selector for carrier `Waveform` shapes.
public struct WaveformPicker: View {
    @Binding private var selection: Waveform
    private let accentColor: Color
    private let showsLabels: Bool

    @State private var haptics = StudioControlHaptics()

    public init(
        selection: Binding<Waveform>,
        accentColor: Color = StudioTheme.alphaColor,
        showsLabels: Bool = true
    ) {
        self._selection = selection
        self.accentColor = accentColor
        self.showsLabels = showsLabels
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Waveform.allCases, id: \.self) { waveform in
                let isSelected = selection == waveform
                BacklitHardwareKeycap(
                    title: waveform.localizedTitle,
                    isSelected: isSelected,
                    accentColor: accentColor,
                    showsLabel: showsLabels
                ) {
                    guard selection != waveform else { return }
                    haptics.prepare()
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection = waveform
                    }
                    haptics.fireImpact(.light, intensity: 0.65)
                } icon: { selected in
                    WaveformGlyphShape(waveform: waveform)
                        .stroke(
                            selected ? accentColor : StudioTheme.secondaryText,
                            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 26, height: 14)
                        .shadow(color: selected ? accentColor.opacity(0.6) : .clear, radius: 3)
                }
            }
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.recessedWell)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Waveform"))
    }
}

/// 3-option backlit GarageBand pushbutton selector for `EntrainmentMode` (`Binaural` / `Monaural` / `Isochronic`).
public struct ModePicker: View {
    @Binding private var selection: EntrainmentMode
    private let accentColor: Color

    @State private var haptics = StudioControlHaptics()

    public init(
        selection: Binding<EntrainmentMode>,
        accentColor: Color = StudioTheme.alphaColor
    ) {
        self._selection = selection
        self.accentColor = accentColor
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(EntrainmentMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                BacklitHardwareKeycap(
                    title: mode.localizedTitle,
                    isSelected: isSelected,
                    accentColor: accentColor,
                    showsLabel: true
                ) {
                    guard selection != mode else { return }
                    haptics.prepare()
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection = mode
                    }
                    haptics.fireImpact(.light, intensity: 0.65)
                } icon: { selected in
                    ModeGlyphShape(mode: mode)
                        .stroke(
                            selected ? accentColor : StudioTheme.secondaryText,
                            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 24, height: 16)
                        .shadow(color: selected ? accentColor.opacity(0.6) : .clear, radius: 3)
                }
            }
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.recessedWell)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Mode"))
    }
}
