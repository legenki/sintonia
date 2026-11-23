import PresetKit
import SwiftUI
import SynthCore

/// Automation curve editor wrapping `CurveEditorCanvas` with parameter selection,
/// interpolation/snap/zoom controls, point actions, and automatic full-screen landscape rail layout.
public struct CurveEditorView: View {
    @Binding private var preset: Preset
    @Binding private var selectedVoiceIndex: Int
    @Binding private var selectedParameter: CurveEditorParameter

    private let currentTime: Double
    private let accentColorOverride: Color?

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var selectedPointIndex: Int? = 0
    @State private var timeZoom: CGFloat = 1.0
    @State private var panFraction: CGFloat = 0.0
    @State private var snapToMinute: Bool = false
    @State private var haptics = StudioControlHaptics()

    @GestureState private var isPanBarDragging = false
    @State private var panBarStartFraction: CGFloat?

    public init(
        preset: Binding<Preset>,
        selectedVoiceIndex: Binding<Int>,
        selectedParameter: Binding<CurveEditorParameter>,
        currentTime: Double = 0.0,
        accentColor: Color? = nil
    ) {
        self._preset = preset
        self._selectedVoiceIndex = selectedVoiceIndex
        self._selectedParameter = selectedParameter
        self.currentTime = currentTime
        self.accentColorOverride = accentColor
    }

    private var isCompactLandscape: Bool {
        verticalSizeClass == .compact
    }

    private var safeVoiceIndex: Int {
        guard !preset.voices.isEmpty else { return 0 }
        return min(max(0, selectedVoiceIndex), preset.voices.count - 1)
    }

    private var safeVoice: Voice? {
        guard preset.voices.indices.contains(safeVoiceIndex) else { return nil }
        return preset.voices[safeVoiceIndex]
    }

    private var activeAccentColor: Color {
        accentColorOverride ?? selectedParameter.accentColor
    }

    private var activeCurve: EnvelopeCurve {
        switch selectedParameter {
        case .beatHz:
            return safeVoice?.beatCurve ?? EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear)
        case .carrierHz:
            return safeVoice?.carrierCurve ?? EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 200)], interpolation: .linear)
        case .voiceVolume:
            return safeVoice?.volumeCurve ?? EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.7)], interpolation: .linear)
        case .noiseVolume:
            return preset.noise.volumeCurve
        case .noiseColor:
            return preset.noise.smoothnessCurve
        }
    }

    private var activeCurveBinding: Binding<EnvelopeCurve> {
        Binding(
            get: { activeCurve },
            set: { newCurve in
                switch selectedParameter {
                case .beatHz:
                    guard preset.voices.indices.contains(safeVoiceIndex) else { return }
                    preset.voices[safeVoiceIndex].beatCurve = newCurve
                case .carrierHz:
                    guard preset.voices.indices.contains(safeVoiceIndex) else { return }
                    preset.voices[safeVoiceIndex].carrierCurve = newCurve
                case .voiceVolume:
                    guard preset.voices.indices.contains(safeVoiceIndex) else { return }
                    preset.voices[safeVoiceIndex].volumeCurve = newCurve
                case .noiseVolume:
                    preset.noise.volumeCurve = newCurve
                case .noiseColor:
                    preset.noise.smoothnessCurve = newCurve
                }
            }
        )
    }

    private var sortedActivePoints: [CurvePoint] {
        activeCurve.points.sorted { $0.timeSec < $1.timeSec }
    }

    private var selectedPoint: CurvePoint? {
        let points = sortedActivePoints
        guard let idx = selectedPointIndex, points.indices.contains(idx) else { return nil }
        return points[idx]
    }

    private var trackingSourceIndexIfOverridden: Int? {
        guard let voice = safeVoice, let rule = voice.trackingRule else { return nil }
        switch (selectedParameter, rule.targetParameter) {
        case (.carrierHz, .carrier), (.beatHz, .beat):
            return preset.voices.indices.contains(rule.sourceVoiceIndex) ? rule.sourceVoiceIndex : nil
        default:
            return nil
        }
    }

    public var body: some View {
        Group {
            if isCompactLandscape {
                landscapeStudioLayout
            } else {
                portraitStudioLayout
            }
        }
        .onChange(of: selectedParameter) { _, _ in
            resetPointSelectionForActiveCurve()
        }
        .onChange(of: safeVoiceIndex) { _, _ in
            resetPointSelectionForActiveCurve()
        }
        .onChange(of: activeCurve.points.count) { _, count in
            if count == 0 {
                selectedPointIndex = nil
            } else if let idx = selectedPointIndex, idx >= count {
                selectedPointIndex = count - 1
            }
        }
        .onChange(of: isPanBarDragging) { _, dragging in
            if !dragging {
                panBarStartFraction = nil
            }
        }
    }

    // MARK: - Portrait & Landscape Layouts

    private var portraitStudioLayout: some View {
        VStack(spacing: 10) {
            portraitParameterStrip
            portraitControlsBar

            if let sourceIdx = trackingSourceIndexIfOverridden {
                trackedOverrideNotice(sourceIndex: sourceIdx)
            }

            canvasArea
                .frame(minHeight: 230, maxHeight: .infinity)
        }
    }

    private var landscapeStudioLayout: some View {
        HStack(spacing: 10) {
            landscapeParameterRail
                .frame(width: 214)

            VStack(spacing: 6) {
                if let sourceIdx = trackingSourceIndexIfOverridden {
                    trackedOverrideNotice(sourceIndex: sourceIdx)
                }

                canvasArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Portrait Controls

    private var portraitParameterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CurveEditorParameter.allCases) { param in
                    let isSelected = selectedParameter == param
                    Button {
                        haptics.prepare()
                        selectedParameter = param
                        haptics.fireModeShift()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(param.accentColor)
                                .frame(width: 6, height: 6)
                            Text(param.shortTitleKey)
                                .font(.caption.weight(isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? StudioTheme.primaryText : StudioTheme.secondaryText)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            Capsule()
                                .fill(isSelected ? param.accentColor.opacity(0.2) : StudioTheme.recessedWell)
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    isSelected ? param.accentColor.opacity(0.7) : StudioTheme.hairlineHighlight,
                                    lineWidth: isSelected ? 1.0 : 0.75
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var portraitControlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if selectedParameter.isVoiceParameter, preset.voices.count > 1 {
                    voiceMenuSelector
                }

                interpolationSwitcher

                Spacer(minLength: 4)

                snapToggleButton
                zoomControlsPill
            }

            HStack(spacing: 8) {
                selectedPointBadge

                Spacer(minLength: 4)

                addPointButton
                deletePointButton
            }
        }
    }

    // MARK: - Landscape Side Parameter Rail

    private var landscapeParameterRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if selectedParameter.isVoiceParameter, !preset.voices.isEmpty {
                    if preset.voices.count > 1 {
                        voiceMenuSelector
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let voice = safeVoice {
                        HStack(spacing: 5) {
                            Text("Ch \(safeVoiceIndex + 1)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(activeAccentColor)
                            Text(verbatim: "• \(voice.name)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(StudioTheme.secondaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(StudioTheme.recessedWell))
                    }
                }

                VStack(spacing: 5) {
                    ForEach(CurveEditorParameter.allCases) { param in
                        let isSelected = selectedParameter == param
                        Button {
                            haptics.prepare()
                            selectedParameter = param
                            haptics.fireModeShift()
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(isSelected ? param.accentColor : Color.clear)
                                    .frame(width: 3, height: 18)

                                Circle()
                                    .fill(param.accentColor)
                                    .frame(width: 6, height: 6)

                                Text(param.shortTitleKey)
                                    .font(.caption.weight(isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? StudioTheme.primaryText : StudioTheme.secondaryText)
                                    .lineLimit(1)

                                Spacer(minLength: 4)

                                Text(verbatim: param.formatValue(currentValue(for: param)))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(isSelected ? param.accentColor : StudioTheme.mutedText)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? param.accentColor.opacity(0.16) : StudioTheme.recessedWell.opacity(0.8))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? param.accentColor.opacity(0.55) : StudioTheme.hairlineHighlight,
                                        lineWidth: 0.75
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }

                Divider()
                    .overlay(StudioTheme.hairlineHighlight)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Interpolation")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudioTheme.mutedText)

                    interpolationSwitcher
                }

                HStack(spacing: 6) {
                    snapToggleButton
                    Spacer(minLength: 2)
                    zoomControlsPill
                }

                Divider()
                    .overlay(StudioTheme.hairlineHighlight)

                VStack(alignment: .leading, spacing: 6) {
                    selectedPointBadge

                    HStack(spacing: 6) {
                        addPointButton
                            .frame(maxWidth: .infinity)
                        deletePointButton
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(10)
        }
        .studioRackCard(cornerRadius: 14)
    }

    // MARK: - Canvas & Zoom Pan Strip

    private var canvasArea: some View {
        VStack(spacing: 6) {
            CurveEditorCanvas(
                curve: activeCurveBinding,
                selectedPointIndex: $selectedPointIndex,
                timeZoom: $timeZoom,
                panFraction: $panFraction,
                durationSec: preset.durationSec,
                valueRange: selectedParameter.valueRange,
                currentTime: currentTime,
                snapToMinute: snapToMinute,
                accentColor: activeAccentColor,
                isBeatFrequency: selectedParameter == .beatHz,
                valueFormatter: selectedParameter.formatValue,
                axisLabelFormatter: selectedParameter.formatAxisLabel
            )

            if timeZoom > 1.01 {
                overviewPanStrip
            }
        }
    }

    private var overviewPanStrip: some View {
        GeometryReader { proxy in
            let width = max(1.0, proxy.size.width)
            let visibleSpanFrac = min(1.0, 1.0 / Double(max(1.0, timeZoom)))
            let clampedPan = min(max(0.0, 1.0 - visibleSpanFrac), max(0.0, Double(panFraction)))
            let thumbW = max(24.0, CGFloat(visibleSpanFrac) * width)
            let maxOffset = max(0.0, width - thumbW)
            let thumbX = maxOffset > 0 ? CGFloat(clampedPan / max(1e-6, 1.0 - visibleSpanFrac)) * maxOffset : 0.0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StudioTheme.recessedWell)
                    .overlay {
                        Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
                    }

                Capsule()
                    .fill(activeAccentColor.opacity(isPanBarDragging ? 0.45 : 0.30))
                    .overlay {
                        Capsule().strokeBorder(activeAccentColor.opacity(0.75), lineWidth: 0.9)
                    }
                    .frame(width: thumbW, height: 14)
                    .offset(x: thumbX)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPanBarDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        if panBarStartFraction == nil {
                            panBarStartFraction = panFraction
                        }
                        let start = panBarStartFraction ?? panFraction
                        let maxPan = max(0.0, 1.0 - visibleSpanFrac)
                        guard maxOffset > 0 else { return }
                        let deltaFrac = Double(gesture.translation.width / maxOffset) * maxPan
                        panFraction = CGFloat(min(maxPan, max(0.0, Double(start) + deltaFrac)))
                    }
                    .onEnded { _ in
                        panBarStartFraction = nil
                    }
            )
        }
        .frame(height: 18)
    }

    // MARK: - Subcontrols

    private var voiceMenuSelector: some View {
        Menu {
            ForEach(preset.voices.indices, id: \.self) { idx in
                Button {
                    selectedVoiceIndex = idx
                } label: {
                    HStack {
                        Text(verbatim: "\(String(localized: "Ch \(idx + 1)")) • \(preset.voices[idx].name)")
                        if idx == safeVoiceIndex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Ch \(safeVoiceIndex + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(StudioTheme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(StudioTheme.elevatedSurface))
            .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
        }
    }

    private var interpolationSwitcher: some View {
        HStack(spacing: 3) {
            interpolationOption(.linear, title: "Linear")
            interpolationOption(.smoothStep, title: "Smooth S-Curve")
        }
        .padding(3)
        .background(Capsule().fill(StudioTheme.recessedWell))
        .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
    }

    private func interpolationOption(_ mode: CurveInterpolation, title: LocalizedStringKey) -> some View {
        let isSelected = activeCurve.interpolation == mode
        return Button {
            haptics.prepare()
            var updated = activeCurve
            updated.interpolation = mode
            activeCurveBinding.wrappedValue = updated
            haptics.fireModeShift()
        } label: {
            Text(title)
                .font(.caption2.weight(isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? StudioTheme.primaryText : StudioTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        Capsule().fill(activeAccentColor.opacity(0.24))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var snapToggleButton: some View {
        Button {
            haptics.prepare()
            snapToMinute.toggle()
            haptics.fireModeShift()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "magnet")
                    .font(.caption2.weight(.semibold))
                Text("Snap 1 min")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(snapToMinute ? activeAccentColor : StudioTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(snapToMinute ? activeAccentColor.opacity(0.18) : StudioTheme.recessedWell)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        snapToMinute ? activeAccentColor.opacity(0.6) : StudioTheme.hairlineHighlight,
                        lineWidth: 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(snapToMinute ? .isSelected : [])
    }

    private var zoomControlsPill: some View {
        HStack(spacing: 4) {
            Button {
                adjustZoom(by: 0.5)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(timeZoom <= 1.01)
            .opacity(timeZoom <= 1.01 ? 0.4 : 1.0)
            .accessibilityLabel(Text("Zoom"))

            Button {
                timeZoom = 1.0
                panFraction = 0.0
                haptics.fireReset()
            } label: {
                Text(verbatim: String(format: "%.1f×", Double(timeZoom)))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(timeZoom > 1.01 ? activeAccentColor : StudioTheme.secondaryText)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)

            Button {
                adjustZoom(by: 2.0)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(timeZoom >= 15.99)
            .opacity(timeZoom >= 15.99 ? 0.4 : 1.0)
            .accessibilityLabel(Text("Zoom"))
        }
        .foregroundStyle(StudioTheme.primaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(StudioTheme.recessedWell))
        .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
    }

    private var selectedPointBadge: some View {
        Group {
            if let pt = selectedPoint {
                Text(verbatim: "\(StudioTheme.formatTime(pt.timeSec)) • \(selectedParameter.formatValue(pt.value))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(StudioTheme.recessedWell))
                    .overlay(Capsule().strokeBorder(activeAccentColor.opacity(0.45), lineWidth: 0.75))
            } else {
                Text(verbatim: selectedParameter.formatValue(currentValue(for: selectedParameter)))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(StudioTheme.recessedWell))
            }
        }
    }

    private var addPointButton: some View {
        Button {
            addPointAtPlayhead()
        } label: {
            Label("Add Point", systemImage: "plus")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(activeAccentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(activeAccentColor.opacity(0.16)))
                .overlay(Capsule().strokeBorder(activeAccentColor.opacity(0.45), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    private var deletePointButton: some View {
        let canDelete = sortedActivePoints.count > 1 && selectedPointIndex != nil
        return Button(role: .destructive) {
            deleteSelectedPoint()
        } label: {
            Label("Delete Point", systemImage: "trash")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(canDelete ? StudioTheme.ledRed : StudioTheme.mutedText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(canDelete ? StudioTheme.ledRed.opacity(0.14) : StudioTheme.recessedWell)
                )
                .overlay(
                    Capsule().strokeBorder(
                        canDelete ? StudioTheme.ledRed.opacity(0.45) : StudioTheme.hairlineHighlight,
                        lineWidth: 0.75
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
    }

    private func trackedOverrideNotice(sourceIndex: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudioTheme.betaColor)
            Text("Tracked from Ch \(sourceIndex + 1)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioTheme.primaryText)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioTheme.betaColor.opacity(0.14)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(StudioTheme.betaColor.opacity(0.45), lineWidth: 0.75)
        )
    }

    // MARK: - Actions & Helpers

    private func currentValue(for param: CurveEditorParameter) -> Double {
        let t = max(0.0, currentTime.isFinite ? currentTime : 0.0)
        switch param {
        case .beatHz:
            return safeVoice?.beatCurve.evaluate(at: t) ?? 10.0
        case .carrierHz:
            return safeVoice?.carrierCurve.evaluate(at: t) ?? 200.0
        case .voiceVolume:
            return safeVoice?.volumeCurve.evaluate(at: t) ?? 0.7
        case .noiseVolume:
            return preset.noise.volumeCurve.evaluate(at: t)
        case .noiseColor:
            return preset.noise.smoothnessCurve.evaluate(at: t)
        }
    }

    private func resetPointSelectionForActiveCurve() {
        let count = sortedActivePoints.count
        selectedPointIndex = count > 0 ? 0 : nil
    }

    private func adjustZoom(by factor: CGFloat) {
        let oldZoom = timeZoom
        let newZoom = min(16.0, max(1.0, oldZoom * factor))
        let oldSpan = 1.0 / Double(max(1.0, oldZoom))
        let newSpan = 1.0 / Double(newZoom)
        let center = Double(panFraction) + oldSpan * 0.5
        timeZoom = newZoom
        panFraction = CGFloat(min(max(0.0, 1.0 - newSpan), max(0.0, center - newSpan * 0.5)))
        haptics.fireStep()
    }

    private func addPointAtPlayhead() {
        let duration = max(1.0, preset.durationSec.isFinite ? preset.durationSec : 60.0)
        var targetTime = min(duration, max(0.0, currentTime.isFinite ? currentTime : 0.0))
        if snapToMinute {
            targetTime = min(duration, max(0.0, (targetTime / 60.0).rounded() * 60.0))
        }

        let existing = sortedActivePoints
        if existing.contains(where: { abs($0.timeSec - targetTime) < 0.5 }) {
            let candidate = min(duration, targetTime + (snapToMinute ? 60.0 : max(1.0, duration * 0.05)))
            if !existing.contains(where: { abs($0.timeSec - candidate) < 0.5 }) {
                targetTime = candidate
            }
        }

        let val = activeCurve.evaluate(at: targetTime)
        let range = selectedParameter.valueRange
        let clampedVal = min(range.upperBound, max(range.lowerBound, val.isFinite ? val : range.lowerBound))

        var updated = activeCurve
        var tagged: [(isNew: Bool, point: CurvePoint)] = existing.map { (false, $0) }
        tagged.append((true, CurvePoint(timeSec: targetTime, value: clampedVal)))
        tagged.sort { lhs, rhs in
            if lhs.point.timeSec != rhs.point.timeSec {
                return lhs.point.timeSec < rhs.point.timeSec
            }
            return !lhs.isNew && rhs.isNew
        }
        updated.points = tagged.map(\.point)
        activeCurveBinding.wrappedValue = updated
        selectedPointIndex = tagged.firstIndex(where: \.isNew)
        haptics.fireStep()
    }

    private func deleteSelectedPoint() {
        let points = sortedActivePoints
        guard points.count > 1,
              let idx = selectedPointIndex,
              points.indices.contains(idx) else {
            return
        }
        var updated = activeCurve
        var remaining = points
        remaining.remove(at: idx)
        updated.points = remaining
        activeCurveBinding.wrappedValue = updated
        selectedPointIndex = min(idx, remaining.count - 1)
        haptics.fireReset()
    }
}
