import SwiftUI

/// GarageBand-inspired rotary hardware knob with glowing LED arc, brushed metal cap,
/// horizontal-offset fine-tuning (`> 36 pt` -> `0.2×`), double-tap reset, and detent haptics.
public struct StudioKnob: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let defaultValue: Double
    private let title: String
    private let valueFormatter: (Double) -> String
    private let accentColor: Color
    private let size: CGFloat

    @GestureState private var isGestureActive = false
    @State private var isDragging = false
    @State private var isFineTuning = false
    @State private var isHovered = false
    @State private var lastTranslationY: CGFloat = 0
    @State private var workingNormalized: Double = 0
    @State private var haptics = StudioControlHaptics()

    private static let totalSweepDegrees: Double = 270.0
    private static let startAngleDegrees: Double = 135.0
    private static let fullDragTravelPt: CGFloat = 160.0
    private static let fineTuningThresholdPt: CGFloat = 36.0
    private static let fineTuningScale: Double = 0.2

    public init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        title: String,
        valueFormatter: @escaping (Double) -> String,
        accentColor: Color = StudioTheme.alphaColor,
        size: CGFloat = 64
    ) {
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.title = title
        self.valueFormatter = valueFormatter
        self.accentColor = accentColor
        self.size = max(44, size)
    }

    private var span: Double {
        max(0.0, range.upperBound - range.lowerBound)
    }

    private var clampedValue: Double {
        guard value.isFinite else { return clampedDefaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private var clampedDefaultValue: Double {
        let fallback = range.lowerBound
        guard defaultValue.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, defaultValue))
    }

    private var normalized: Double {
        guard span > 0 else { return 0.0 }
        return min(1.0, max(0.0, (clampedValue - range.lowerBound) / span))
    }

    private var isBipolar: Bool {
        range.lowerBound < 0 && range.upperBound > 0
            && abs(range.lowerBound + range.upperBound) <= span * 0.05
    }

    private var bipolarOriginNormalized: Double {
        guard span > 0 else { return 0.5 }
        return min(1.0, max(0.0, (0.0 - range.lowerBound) / span))
    }

    private var arcStartFraction: Double {
        let sweepFraction = Self.totalSweepDegrees / 360.0
        if isBipolar {
            return min(bipolarOriginNormalized, normalized) * sweepFraction
        }
        return 0.0
    }

    private var arcEndFraction: Double {
        let sweepFraction = Self.totalSweepDegrees / 360.0
        if isBipolar {
            return max(bipolarOriginNormalized, normalized) * sweepFraction
        }
        return normalized * sweepFraction
    }

    private var pointerRotationDegrees: Double {
        normalized * Self.totalSweepDegrees - 135.0
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                scaleTickRing
                ledTrackAndArc
                metallicRotaryCap

                if isDragging && isFineTuning {
                    fineTuningBadge
                        .offset(y: -(size * 0.5 + 14))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: size + 22, height: size + 22)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { hovering in
                isHovered = hovering
            }
            #endif
            .onTapGesture(count: 2) {
                resetToDefault()
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .updating($isGestureActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        handleDragChanged(gesture)
                    }
                    .onEnded { _ in
                        isDragging = false
                        isFineTuning = false
                    }
            )
            .onChange(of: isGestureActive) { _, active in
                if !active {
                    isDragging = false
                    isFineTuning = false
                }
            }

            VStack(spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(valueFormatter(clampedValue))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isDragging ? accentColor : StudioTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background {
                        Capsule()
                            .fill(StudioTheme.recessedWell.opacity(0.9))
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                isDragging
                                    ? accentColor.opacity(0.45)
                                    : (isHovered ? accentColor.opacity(0.32) : StudioTheme.hairlineHighlight),
                                lineWidth: 0.75
                            )
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(valueFormatter(clampedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                stepNormalized(by: 0.05)
            case .decrement:
                stepNormalized(by: -0.05)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: Text("Reset")) {
            resetToDefault()
        }
        .animation(.easeOut(duration: 0.14), value: isFineTuning)
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .animation(.easeOut(duration: 0.14), value: isHovered)
    }

    private var scaleTickRing: some View {
        let tickCount = 21
        let ringDiameter = size + 16
        let outerRadius = ringDiameter * 0.5

        return ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let fraction = Double(index) / Double(tickCount - 1)
                let angle = fraction * Self.totalSweepDegrees - 135.0
                let isMajor = index % 2 == 0
                let isLit = isTickLit(fraction: fraction)

                Capsule()
                    .fill(isLit ? accentColor : StudioTheme.mutedText.opacity(isMajor ? 0.65 : 0.35))
                    .frame(width: isMajor ? 2.0 : 1.25, height: isMajor ? 5.5 : 3.5)
                    .offset(y: -(outerRadius - (isMajor ? 2.75 : 1.75)))
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    private var ledTrackAndArc: some View {
        let arcDiameter = size + 6
        let strokeWidth: CGFloat = isDragging ? 3.5 : 3.0

        return ZStack {
            Circle()
                .trim(from: 0.0, to: Self.totalSweepDegrees / 360.0)
                .stroke(
                    StudioTheme.recessedWell,
                    style: StrokeStyle(lineWidth: strokeWidth + 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(Self.startAngleDegrees))

            Circle()
                .trim(from: arcStartFraction, to: arcEndFraction)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(Self.startAngleDegrees))
                .shadow(
                    color: accentColor.opacity(isDragging ? 0.85 : (isHovered ? 0.65 : 0.45)),
                    radius: isDragging ? 6 : (isHovered ? 4.5 : 3)
                )
        }
        .frame(width: arcDiameter, height: arcDiameter)
    }

    private var metallicRotaryCap: some View {
        let capDiameter = size - 6

        return ZStack {
            Circle()
                .fill(StudioTheme.recessedWell)
                .frame(width: size, height: size)
                .shadow(color: StudioTheme.hardwareShadow, radius: 6, x: 0, y: 4)

            Circle()
                .fill(StudioTheme.brushedMetalGradient)
                .frame(width: size - 2, height: size - 2)
                .overlay {
                    Circle()
                        .strokeBorder(StudioTheme.metallicRimGradient, lineWidth: 1.0)
                }

            Circle()
                .fill(StudioTheme.knobCapGradient)
                .frame(width: capDiameter, height: capDiameter)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isFineTuning
                                ? accentColor.opacity(0.7)
                                : (isHovered ? accentColor.opacity(0.45) : Color.white.opacity(0.16)),
                            lineWidth: (isFineTuning || isHovered) ? 1.25 : 0.85
                        )
                }

            Capsule()
                .fill(accentColor)
                .frame(width: 2.6, height: capDiameter * 0.28)
                .shadow(color: accentColor.opacity(0.85), radius: 2.5)
                .offset(y: -(capDiameter * 0.30))
                .rotationEffect(.degrees(pointerRotationDegrees))
        }
    }

    private var fineTuningBadge: some View {
        Text(verbatim: "0.2×")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(StudioTheme.chassisGraphite)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(accentColor))
            .shadow(color: accentColor.opacity(0.6), radius: 4)
            .accessibilityHidden(true)
    }

    private func isTickLit(fraction: Double) -> Bool {
        if isBipolar {
            let low = min(bipolarOriginNormalized, normalized) - 0.015
            let high = max(bipolarOriginNormalized, normalized) + 0.015
            return fraction >= low && fraction <= high
        }
        return fraction <= normalized + 0.015
    }

    private func handleDragChanged(_ gesture: DragGesture.Value) {
        guard span > 0 else { return }

        if !isDragging {
            isDragging = true
            lastTranslationY = gesture.translation.height
            workingNormalized = normalized
            haptics.prepare()
        }

        let dy = gesture.translation.height - lastTranslationY
        lastTranslationY = gesture.translation.height

        let fineEngaged = abs(gesture.translation.width) > Self.fineTuningThresholdPt
            || StudioControlHaptics.isFineTuningModifierPressed
        if fineEngaged != isFineTuning {
            isFineTuning = fineEngaged
            haptics.fireModeShift()
        }

        let sensitivity = fineEngaged ? Self.fineTuningScale : 1.0
        let deltaNormalized = (Double(-dy) / Double(Self.fullDragTravelPt)) * sensitivity
        let prevNormalized = workingNormalized
        let nextNormalized = min(1.0, max(0.0, prevNormalized + deltaNormalized))

        haptics.handleNormalizedTransition(
            from: prevNormalized,
            to: nextNormalized,
            isBipolar: isBipolar
        )

        workingNormalized = nextNormalized
        value = range.lowerBound + nextNormalized * span
    }

    private func stepNormalized(by delta: Double) {
        guard span > 0 else { return }
        let nextNormalized = min(1.0, max(0.0, normalized + delta))
        value = range.lowerBound + nextNormalized * span
        haptics.fireStep()
    }

    private func resetToDefault() {
        value = clampedDefaultValue
        workingNormalized = normalized
        haptics.fireReset()
    }
}
