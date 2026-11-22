import SwiftUI

/// Axis orientation for `StudioFader`.
public enum StudioFaderOrientation: Sendable, Equatable {
    case vertical
    case horizontal
}

/// GarageBand-inspired channel fader featuring a metallic thumb cap on a recessed groove,
/// dB calibration tick marks, live dragging haptic detents, fine-tuning, and double-tap reset.
public struct StudioFader: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let defaultValue: Double
    private let title: String?
    private let accentColor: Color
    private let orientation: StudioFaderOrientation
    private let showsScaleMarks: Bool
    private let valueFormatter: ((Double) -> String)?

    @State private var isDragging = false
    @State private var isFineTuning = false
    @State private var lastDragOffset: CGFloat = 0
    @State private var workingNormalized: Double = 0
    @State private var haptics = StudioControlHaptics()

    private static let fineTuningThresholdPt: CGFloat = 36.0
    private static let fineTuningScale: Double = 0.2

    public init(
        value: Binding<Double>,
        range: ClosedRange<Double> = 0.0...1.0,
        defaultValue: Double = 0.8,
        title: String? = nil,
        accentColor: Color = StudioTheme.alphaColor,
        orientation: StudioFaderOrientation = .vertical,
        showsScaleMarks: Bool = true,
        valueFormatter: ((Double) -> String)? = nil
    ) {
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.title = title
        self.accentColor = accentColor
        self.orientation = orientation
        self.showsScaleMarks = showsScaleMarks
        self.valueFormatter = valueFormatter
    }

    private var span: Double {
        max(0.0, range.upperBound - range.lowerBound)
    }

    private var clampedValue: Double {
        guard value.isFinite else { return clampedDefaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private var clampedDefaultValue: Double {
        guard defaultValue.isFinite else { return range.lowerBound }
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

    private var formattedValue: String {
        if let valueFormatter {
            return valueFormatter(clampedValue)
        }
        if range.lowerBound >= 0.0 && range.upperBound <= 2.0 {
            return StudioTheme.formatDecibels(linearGain: clampedValue)
        }
        return String(format: "%.0f%%", normalized * 100.0)
    }

    public var body: some View {
        Group {
            switch orientation {
            case .vertical:
                VStack(spacing: 6) {
                    if let title {
                        Text(LocalizedStringKey(title))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(StudioTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    faderTrackArea
                        .frame(minWidth: showsScaleMarks ? 48 : 34)

                    if valueFormatter != nil || title != nil {
                        valueBadge
                    }
                }

            case .horizontal:
                VStack(spacing: 6) {
                    if title != nil || valueFormatter != nil {
                        HStack(spacing: 8) {
                            if let title {
                                Text(LocalizedStringKey(title))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(StudioTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            valueBadge
                        }
                    }

                    faderTrackArea
                        .frame(height: showsScaleMarks ? 44 : 32)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title ?? "Volume")))
        .accessibilityValue(formattedValue)
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
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .animation(.easeOut(duration: 0.14), value: isFineTuning)
    }

    private var valueBadge: some View {
        Text(formattedValue)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(isDragging ? accentColor : StudioTheme.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(StudioTheme.recessedWell.opacity(0.9))
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isDragging ? accentColor.opacity(0.45) : StudioTheme.hairlineHighlight,
                        lineWidth: 0.75
                    )
            }
    }

    private var faderTrackArea: some View {
        GeometryReader { proxy in
            let size = proxy.size
            switch orientation {
            case .vertical:
                verticalTrackContent(in: size)
            case .horizontal:
                horizontalTrackContent(in: size)
            }
        }
    }

    private func verticalTrackContent(in size: CGSize) -> some View {
        let capWidth: CGFloat = min(36, max(24, size.width - (showsScaleMarks ? 14 : 4)))
        let capHeight: CGFloat = 20
        let travel = max(1.0, size.height - capHeight)
        let centerY = size.height - capHeight * 0.5 - CGFloat(normalized) * travel
        let grooveWidth: CGFloat = 6

        return ZStack {
            if showsScaleMarks {
                verticalScaleMarks(size: size, capHeight: capHeight, travel: travel)
            }

            // Recessed groove well
            Capsule()
                .fill(StudioTheme.recessedWell)
                .frame(width: grooveWidth, height: max(12, size.height - 6))
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                }

            // Active fill inside groove
            let activeHeight = max(0, (size.height - capHeight * 0.5) - centerY)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: grooveWidth - 2, height: activeHeight)
                    .shadow(color: accentColor.opacity(isDragging ? 0.65 : 0.3), radius: 4)
            }
            .frame(height: travel)

            // Metallic thumb cap
            metallicThumbCap(width: capWidth, height: capHeight, vertical: true)
                .position(x: size.width * 0.5, y: centerY)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            resetToDefault()
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { gesture in
                    handleDragChanged(
                        primaryTranslation: -gesture.translation.height,
                        perpendicularTranslation: gesture.translation.width,
                        travelLength: travel
                    )
                }
                .onEnded { _ in
                    isDragging = false
                    isFineTuning = false
                }
        )
    }

    private func horizontalTrackContent(in size: CGSize) -> some View {
        let capWidth: CGFloat = 20
        let capHeight: CGFloat = min(30, max(22, size.height - (showsScaleMarks ? 12 : 4)))
        let travel = max(1.0, size.width - capWidth)
        let centerX = capWidth * 0.5 + CGFloat(normalized) * travel
        let grooveHeight: CGFloat = 6

        return ZStack {
            if showsScaleMarks {
                horizontalScaleMarks(size: size, capWidth: capWidth, travel: travel)
            }

            Capsule()
                .fill(StudioTheme.recessedWell)
                .frame(width: max(12, size.width - 6), height: grooveHeight)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                }

            let activeWidth = max(0, centerX - capWidth * 0.5)
            HStack(spacing: 0) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.45), accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: activeWidth, height: grooveHeight - 2)
                    .shadow(color: accentColor.opacity(isDragging ? 0.65 : 0.3), radius: 4)
                Spacer(minLength: 0)
            }
            .frame(width: travel)

            metallicThumbCap(width: capWidth, height: capHeight, vertical: false)
                .position(x: centerX, y: size.height * 0.5)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            resetToDefault()
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { gesture in
                    handleDragChanged(
                        primaryTranslation: gesture.translation.width,
                        perpendicularTranslation: gesture.translation.height,
                        travelLength: travel
                    )
                }
                .onEnded { _ in
                    isDragging = false
                    isFineTuning = false
                }
        )
    }

    private func metallicThumbCap(width: CGFloat, height: CGFloat, vertical: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack {
            shape
                .fill(StudioTheme.faderCapGradient)
                .frame(width: width, height: height)
                .shadow(color: StudioTheme.hardwareShadow, radius: 5, x: 0, y: 3)
                .overlay {
                    if isFineTuning {
                        shape.strokeBorder(accentColor.opacity(0.85), lineWidth: 1.25)
                    } else {
                        shape.strokeBorder(StudioTheme.metallicRimGradient, lineWidth: 0.9)
                    }
                }

            if vertical {
                VStack(spacing: 2.5) {
                    gripLine(width: width * 0.66, height: 1.0, color: Color.black.opacity(0.45))
                    gripLine(width: width * 0.78, height: 1.8, color: accentColor)
                        .shadow(color: accentColor.opacity(0.8), radius: 2)
                    gripLine(width: width * 0.66, height: 1.0, color: Color.black.opacity(0.45))
                }
            } else {
                HStack(spacing: 2.5) {
                    gripLine(width: 1.0, height: height * 0.66, color: Color.black.opacity(0.45))
                    gripLine(width: 1.8, height: height * 0.78, color: accentColor)
                        .shadow(color: accentColor.opacity(0.8), radius: 2)
                    gripLine(width: 1.0, height: height * 0.66, color: Color.black.opacity(0.45))
                }
            }
        }
    }

    private func gripLine(width: CGFloat, height: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: height)
    }

    private func verticalScaleMarks(size: CGSize, capHeight: CGFloat, travel: CGFloat) -> some View {
        let ticks = scaleTickDefinitions()
        let showLabels = size.width >= 54

        return ZStack {
            ForEach(ticks) { tick in
                let y = size.height - capHeight * 0.5 - CGFloat(tick.position) * travel
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(tick.isMajor ? StudioTheme.secondaryText.opacity(0.7) : StudioTheme.mutedText.opacity(0.4))
                        .frame(width: tick.isMajor ? 6 : 3.5, height: tick.isMajor ? 1.2 : 0.8)
                    Spacer()
                    Rectangle()
                        .fill(tick.isMajor ? StudioTheme.secondaryText.opacity(0.7) : StudioTheme.mutedText.opacity(0.4))
                        .frame(width: tick.isMajor ? 6 : 3.5, height: tick.isMajor ? 1.2 : 0.8)
                }
                .frame(width: min(size.width - 2, 46))
                .position(x: size.width * 0.5, y: y)

                if showLabels, let label = tick.label {
                    Text(verbatim: label)
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.mutedText)
                        .position(x: 8, y: y)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func horizontalScaleMarks(size: CGSize, capWidth: CGFloat, travel: CGFloat) -> some View {
        let ticks = scaleTickDefinitions()
        return ZStack {
            ForEach(ticks) { tick in
                let x = capWidth * 0.5 + CGFloat(tick.position) * travel
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(tick.isMajor ? StudioTheme.secondaryText.opacity(0.7) : StudioTheme.mutedText.opacity(0.4))
                        .frame(width: tick.isMajor ? 1.2 : 0.8, height: tick.isMajor ? 5 : 3)
                    Spacer()
                    Rectangle()
                        .fill(tick.isMajor ? StudioTheme.secondaryText.opacity(0.7) : StudioTheme.mutedText.opacity(0.4))
                        .frame(width: tick.isMajor ? 1.2 : 0.8, height: tick.isMajor ? 5 : 3)
                }
                .frame(height: min(size.height - 2, 34))
                .position(x: x, y: size.height * 0.5)
            }
        }
        .accessibilityHidden(true)
    }

    private struct FaderTick: Identifiable {
        let id: Int
        let position: Double
        let isMajor: Bool
        let label: String?
    }

    private func scaleTickDefinitions() -> [FaderTick] {
        if abs(range.lowerBound) < 1e-6 && abs(range.upperBound - 1.0) < 1e-6 {
            return [
                FaderTick(id: 0, position: 1.0, isMajor: true, label: "0"),
                FaderTick(id: 1, position: 0.85, isMajor: false, label: nil),
                FaderTick(id: 2, position: 0.708, isMajor: true, label: "-3"),
                FaderTick(id: 3, position: 0.60, isMajor: false, label: nil),
                FaderTick(id: 4, position: 0.501, isMajor: true, label: "-6"),
                FaderTick(id: 5, position: 0.375, isMajor: false, label: nil),
                FaderTick(id: 6, position: 0.251, isMajor: true, label: "-12"),
                FaderTick(id: 7, position: 0.125, isMajor: false, label: nil),
                FaderTick(id: 8, position: 0.0, isMajor: true, label: "-∞")
            ]
        }

        return (0...8).map { index in
            let fraction = Double(index) / 8.0
            let isMajor = index % 2 == 0
            return FaderTick(id: index, position: fraction, isMajor: isMajor, label: nil)
        }
    }

    private func handleDragChanged(
        primaryTranslation: CGFloat,
        perpendicularTranslation: CGFloat,
        travelLength: CGFloat
    ) {
        guard span > 0 else { return }

        if !isDragging {
            isDragging = true
            lastDragOffset = primaryTranslation
            workingNormalized = normalized
            haptics.prepare()
        }

        let deltaPt = primaryTranslation - lastDragOffset
        lastDragOffset = primaryTranslation

        let fineEngaged = abs(perpendicularTranslation) > Self.fineTuningThresholdPt
        if fineEngaged != isFineTuning {
            isFineTuning = fineEngaged
            haptics.fireModeShift()
        }

        let sensitivity = fineEngaged ? Self.fineTuningScale : 1.0
        let deltaNorm = (Double(deltaPt) / Double(max(44.0, travelLength))) * sensitivity
        let prevNormalized = workingNormalized
        let nextNormalized = min(1.0, max(0.0, prevNormalized + deltaNorm))

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
