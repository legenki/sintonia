import PresetKit
import SwiftUI
import SynthCore

/// Shared curve-shifting and volume-scaling helpers used across Studio inspectors and channel strips.
internal enum StudioCurveAdjustment {
    static func shiftCurve(
        _ curve: EnvelopeCurve,
        toNewValue newValue: Double,
        at timeSec: Double,
        clampedTo range: ClosedRange<Double>
    ) -> EnvelopeCurve {
        let clampedTarget = min(range.upperBound, max(range.lowerBound, newValue.isFinite ? newValue : range.lowerBound))
        let safeTime = timeSec.isFinite ? max(0.0, timeSec) : 0.0
        var updated = curve
        if updated.points.isEmpty {
            updated.points = [CurvePoint(timeSec: 0.0, value: clampedTarget)]
            return updated
        }

        let currentValue = updated.evaluate(at: safeTime)
        let delta = clampedTarget - (currentValue.isFinite ? currentValue : clampedTarget)
        updated.points = updated.points.map { point in
            let shifted = point.value + delta
            let clamped = shifted.isFinite ? min(range.upperBound, max(range.lowerBound, shifted)) : clampedTarget
            return CurvePoint(timeSec: point.timeSec, value: clamped)
        }
        return updated
    }

    static func adjustVolumeCurve(
        _ curve: EnvelopeCurve,
        toNewValue newValue: Double,
        at timeSec: Double
    ) -> EnvelopeCurve {
        let range = PresetLimits.unitRange
        let clampedTarget = min(range.upperBound, max(range.lowerBound, newValue.isFinite ? newValue : range.lowerBound))
        let safeTime = timeSec.isFinite ? max(0.0, timeSec) : 0.0
        var updated = curve
        if updated.points.isEmpty {
            updated.points = [CurvePoint(timeSec: 0.0, value: clampedTarget)]
            return updated
        }

        let currentValue = updated.evaluate(at: safeTime)
        if currentValue.isFinite, currentValue > 0.02, clampedTarget >= 0.02 {
            let factor = clampedTarget / currentValue
            updated.points = updated.points.map { point in
                let scaled = point.value * factor
                let clamped = scaled.isFinite ? min(range.upperBound, max(range.lowerBound, scaled)) : clampedTarget
                return CurvePoint(timeSec: point.timeSec, value: clamped)
            }
            return updated
        }
        return shiftCurve(updated, toNewValue: clampedTarget, at: safeTime, clampedTo: range)
    }
}

/// Hardware inspector for a single synthesis `Voice` (`ModePicker`, `WaveformPicker`,
/// oscillator/isochronic knobs, and cycle-free `VoiceTrackingRule` configuration).
public struct VoiceInspectorView: View {
    @Binding private var voice: Voice
    private let voiceIndex: Int
    private let allVoices: [Voice]
    private let currentTime: Double
    private let accentColor: Color
    private let onEditCurve: ((CurveEditorParameter) -> Void)?

    @FocusState private var isVoiceNameFocused: Bool
    @State private var haptics = StudioControlHaptics()

    public init(
        voice: Binding<Voice>,
        voiceIndex: Int,
        allVoices: [Voice],
        currentTime: Double = 0.0,
        accentColor: Color = StudioTheme.alphaColor,
        onEditCurve: ((CurveEditorParameter) -> Void)? = nil
    ) {
        self._voice = voice
        self.voiceIndex = voiceIndex
        self.allVoices = allVoices
        self.currentTime = currentTime
        self.accentColor = accentColor
        self.onEditCurve = onEditCurve
    }

    private var safeTime: Double {
        currentTime.isFinite ? max(0.0, currentTime) : 0.0
    }

    private var currentCarrierHz: Double {
        Self.effectiveFrequency(
            forVoiceAt: voiceIndex,
            parameter: .carrier,
            currentVoice: voice,
            allVoices: allVoices,
            at: safeTime
        )
    }

    private var currentBeatHz: Double {
        Self.effectiveFrequency(
            forVoiceAt: voiceIndex,
            parameter: .beat,
            currentVoice: voice,
            allVoices: allVoices,
            at: safeTime
        )
    }

    private var currentBeatBandColor: Color {
        BrainwaveBand.from(frequencyHz: currentBeatHz).accentColor
    }

    private var validTrackingSources: [Int] {
        Self.validTrackingSourceIndices(for: voiceIndex, in: allVoices)
    }

    private var isCarrierTracked: Bool {
        voice.trackingRule?.targetParameter == .carrier
    }

    private var isBeatTracked: Bool {
        voice.trackingRule?.targetParameter == .beat
    }

    public var body: some View {
        VStack(spacing: 12) {
            voiceIdentityCard
            synthesisModeAndWaveformCard
            oscillatorKnobsCard
            trackingSectionCard
        }
    }

    // MARK: - Identity & Enable Card

    private var voiceIdentityCard: some View {
        HStack(spacing: 10) {
            Text("Ch \(voiceIndex + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(StudioTheme.chassisGraphite)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(currentBeatBandColor))

            TextField("Voice Name", text: $voice.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.primaryText)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()
                .focused($isVoiceNameFocused)
                .focusedValue(\.isTextInputFocused, isVoiceNameFocused)
                .focusedSceneValue(\.isTextInputFocused, isVoiceNameFocused ? true : nil)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(StudioTheme.recessedWell)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75)
                }

            Toggle("Enabled", isOn: $voice.isEnabled)
                .labelsHidden()
                .tint(currentBeatBandColor)
                .accessibilityLabel(Text("Enabled"))
        }
        .padding(12)
        .studioRackCard(cornerRadius: 16)
    }

    // MARK: - Mode & Waveform Card

    private var synthesisModeAndWaveformCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mode")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textCase(.uppercase)
                Spacer()
                if let onEditCurve {
                    HStack(spacing: 6) {
                        curveShortcutChip(title: "Beat", parameter: .beatHz, action: onEditCurve)
                        curveShortcutChip(title: "Carrier", parameter: .carrierHz, action: onEditCurve)
                    }
                }
            }

            ModePicker(selection: $voice.mode, accentColor: accentColor)

            Text("Waveform")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudioTheme.secondaryText)
                .textCase(.uppercase)
                .padding(.top, 2)

            WaveformPicker(selection: $voice.waveform, accentColor: accentColor)
        }
        .padding(12)
        .studioRackCard(cornerRadius: 16)
    }

    private func curveShortcutChip(
        title: LocalizedStringKey,
        parameter: CurveEditorParameter,
        action: @escaping (CurveEditorParameter) -> Void
    ) -> some View {
        Button {
            action(parameter)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(parameter.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(parameter.accentColor.opacity(0.14)))
            .overlay(Capsule().strokeBorder(parameter.accentColor.opacity(0.45), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Oscillator & Isochronic Knobs

    private var oscillatorKnobsCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    StudioKnob(
                        value: carrierBinding,
                        range: PresetLimits.carrierHzRange,
                        defaultValue: 200.0,
                        title: "Carrier",
                        valueFormatter: StudioTheme.formatFrequency,
                        accentColor: StudioTheme.deltaColor,
                        size: 56
                    )
                    .disabled(isCarrierTracked)
                    .opacity(isCarrierTracked ? 0.52 : 1.0)

                    if isCarrierTracked {
                        trackedBadge
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    StudioKnob(
                        value: beatBinding,
                        range: PresetLimits.beatHzRange,
                        defaultValue: 10.0,
                        title: "Beat",
                        valueFormatter: StudioTheme.formatFrequency,
                        accentColor: currentBeatBandColor,
                        size: 56
                    )
                    .disabled(isBeatTracked)
                    .opacity(isBeatTracked ? 0.52 : 1.0)

                    if isBeatTracked {
                        trackedBadge
                    }
                }
                .frame(maxWidth: .infinity)

                StudioKnob(
                    value: $voice.pan,
                    range: PresetLimits.panRange,
                    defaultValue: 0.0,
                    title: "Pan",
                    valueFormatter: formatPan,
                    accentColor: accentColor,
                    size: 56
                )
                .opacity(voice.mode == .binaural ? 0.62 : 1.0)
                .frame(maxWidth: .infinity)
            }

            if voice.mode == .binaural {
                Text("Binaural mode uses L/R ear separation instead of pan")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if voice.mode == .isochronic {
                Divider()
                    .overlay(StudioTheme.hairlineHighlight)

                HStack(spacing: 12) {
                    StudioKnob(
                        value: $voice.isochronicSoftness,
                        range: PresetLimits.isochronicSoftnessRange,
                        defaultValue: 0.5,
                        title: "Isochronic Softness",
                        valueFormatter: formatPercent,
                        accentColor: currentBeatBandColor,
                        size: 54
                    )
                    .frame(maxWidth: .infinity)

                    StudioKnob(
                        value: $voice.isochronicDutyCycle,
                        range: PresetLimits.isochronicDutyCycleRange,
                        defaultValue: 0.5,
                        title: "Isochronic Duty Cycle",
                        valueFormatter: formatPercent,
                        accentColor: currentBeatBandColor,
                        size: 54
                    )
                    .frame(maxWidth: .infinity)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .studioRackCard(cornerRadius: 16)
        .animation(.easeInOut(duration: 0.18), value: voice.mode)
    }

    private var trackedBadge: some View {
        Text("Tracked")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(StudioTheme.betaColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(StudioTheme.betaColor.opacity(0.16)))
    }

    // MARK: - Acyclic Tracking Section

    private var trackingSectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tracking", systemImage: "link")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textCase(.uppercase)

                Spacer(minLength: 8)

                sourceVoiceMenu
            }

            if let rule = voice.trackingRule {
                if !validTrackingSources.contains(rule.sourceVoiceIndex) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StudioTheme.betaColor)
                        Text("Source Voice")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.secondaryText)
                        Spacer()
                        Button("Reset") {
                            voice.trackingRule = nil
                            haptics.fireReset()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.betaColor)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.betaColor.opacity(0.12)))
                }

                Picker("Target Parameter", selection: trackedParameterBinding(rule)) {
                    Text("Carrier").tag(TrackedParameter.carrier)
                    Text("Beat").tag(TrackedParameter.beat)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    VStack(spacing: 6) {
                        StudioKnob(
                            value: ratioBinding(rule),
                            range: 0.25...4.0,
                            defaultValue: 1.0,
                            title: "Ratio",
                            valueFormatter: { String(format: "%.2f×", $0) },
                            accentColor: accentColor,
                            size: 50
                        )

                        HStack(spacing: 4) {
                            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { presetRatio in
                                let isActive = abs(rule.ratio - presetRatio) < 0.01
                                Button {
                                    setTrackingRatio(presetRatio)
                                } label: {
                                    Text(verbatim: presetRatio == 1.5 ? "1.5×" : String(format: "%.1g×", presetRatio))
                                        .font(.system(size: 10, weight: isActive ? .bold : .medium, design: .monospaced))
                                        .foregroundStyle(isActive ? StudioTheme.chassisGraphite : StudioTheme.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(isActive ? accentColor : StudioTheme.recessedWell))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 6) {
                        let offsetRange: ClosedRange<Double> = rule.targetParameter == .carrier ? -200.0...200.0 : -30.0...30.0
                        StudioKnob(
                            value: offsetBinding(rule, range: offsetRange),
                            range: offsetRange,
                            defaultValue: 0.0,
                            title: "Offset",
                            valueFormatter: { String(format: "%+.1f Hz", $0) },
                            accentColor: StudioTheme.betaColor,
                            size: 50
                        )

                        Stepper(
                            "Offset",
                            value: offsetBinding(rule, range: offsetRange),
                            in: offsetRange,
                            step: rule.targetParameter == .carrier ? 1.0 : 0.5
                        )
                        .labelsHidden()
                        .scaleEffect(0.85)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if validTrackingSources.isEmpty {
                let emptyMessageKey: LocalizedStringKey = allVoices.count <= 1
                    ? "Add another voice to enable tracking"
                    : "All other voices form a tracking chain back to this voice"
                Text(emptyMessageKey)
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.mutedText)
            }
        }
        .padding(12)
        .studioRackCard(cornerRadius: 16)
    }

    private var sourceVoiceMenu: some View {
        Menu {
            Button {
                haptics.prepare()
                voice.trackingRule = nil
                haptics.fireModeShift()
            } label: {
                HStack {
                    Text("None")
                    if voice.trackingRule == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !validTrackingSources.isEmpty {
                Divider()
                ForEach(validTrackingSources, id: \.self) { idx in
                    let isSelected = voice.trackingRule?.sourceVoiceIndex == idx
                    Button {
                        haptics.prepare()
                        if var existing = voice.trackingRule {
                            existing.sourceVoiceIndex = idx
                            voice.trackingRule = existing
                        } else {
                            voice.trackingRule = VoiceTrackingRule(
                                sourceVoiceIndex: idx,
                                targetParameter: .carrier,
                                ratio: 1.5,
                                offset: 0.0
                            )
                        }
                        haptics.fireModeShift()
                    } label: {
                        HStack {
                            Text(verbatim: "\(String(localized: "Ch \(idx + 1)")) • \(allVoices[idx].name)")
                            if isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let sourceIdx = voice.trackingRule?.sourceVoiceIndex,
                   allVoices.indices.contains(sourceIdx) {
                    Text("Ch \(sourceIdx + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(accentColor)
                } else {
                    Text("None")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(StudioTheme.recessedWell))
            .overlay(Capsule().strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
        }
        .accessibilityLabel(Text("Source Voice"))
    }

    // MARK: - Acyclic Tracking Graph Validation

    /// Returns all voice indices that can safely serve as `sourceVoiceIndex` for `voiceIndex`
    /// without self-referencing or introducing a dependency cycle.
    public static func validTrackingSourceIndices(for voiceIndex: Int, in voices: [Voice]) -> [Int] {
        guard voices.indices.contains(voiceIndex) else { return [] }
        return voices.indices.filter { candidate in
            candidate != voiceIndex && !wouldCreateCycle(from: voiceIndex, to: candidate, in: voices)
        }
    }

    private static func wouldCreateCycle(from voiceIndex: Int, to candidate: Int, in voices: [Voice]) -> Bool {
        var visited = Set<Int>()
        var current: Int? = candidate
        while let node = current {
            if node == voiceIndex {
                return true
            }
            guard visited.insert(node).inserted,
                  voices.indices.contains(node),
                  let next = voices[node].trackingRule?.sourceVoiceIndex else {
                return false
            }
            current = next
        }
        return false
    }

    private static func effectiveFrequency(
        forVoiceAt index: Int,
        parameter: TrackedParameter,
        currentVoice: Voice,
        allVoices: [Voice],
        at timeSec: Double
    ) -> Double {
        let range: ClosedRange<Double> = parameter == .carrier ? PresetLimits.carrierHzRange : PresetLimits.beatHzRange
        let baseValue: Double = parameter == .carrier
            ? currentVoice.carrierCurve.evaluate(at: timeSec)
            : currentVoice.beatCurve.evaluate(at: timeSec)

        guard let rule = currentVoice.trackingRule,
              rule.targetParameter == parameter,
              rule.ratio.isFinite,
              rule.offset.isFinite else {
            return min(range.upperBound, max(range.lowerBound, baseValue))
        }

        var chain: [(ratio: Double, offset: Double)] = [(rule.ratio, rule.offset)]
        var visited: Set<Int> = [index]
        var cursor = rule.sourceVoiceIndex

        while allVoices.indices.contains(cursor), visited.insert(cursor).inserted {
            let sourceVoice = allVoices[cursor]
            if let nextRule = sourceVoice.trackingRule,
               nextRule.targetParameter == parameter,
               nextRule.ratio.isFinite,
               nextRule.offset.isFinite {
                chain.append((nextRule.ratio, nextRule.offset))
                cursor = nextRule.sourceVoiceIndex
            } else {
                var value = parameter == .carrier
                    ? sourceVoice.carrierCurve.evaluate(at: timeSec)
                    : sourceVoice.beatCurve.evaluate(at: timeSec)
                for link in chain.reversed() {
                    value = min(range.upperBound, max(range.lowerBound, link.ratio * value + link.offset))
                }
                return value
            }
        }

        return min(range.upperBound, max(range.lowerBound, baseValue))
    }

    // MARK: - Bindings & Formatters

    private var carrierBinding: Binding<Double> {
        Binding(
            get: { currentCarrierHz },
            set: { newValue in
                voice.carrierCurve = StudioCurveAdjustment.shiftCurve(
                    voice.carrierCurve,
                    toNewValue: newValue,
                    at: safeTime,
                    clampedTo: PresetLimits.carrierHzRange
                )
            }
        )
    }

    private var beatBinding: Binding<Double> {
        Binding(
            get: { currentBeatHz },
            set: { newValue in
                voice.beatCurve = StudioCurveAdjustment.shiftCurve(
                    voice.beatCurve,
                    toNewValue: newValue,
                    at: safeTime,
                    clampedTo: PresetLimits.beatHzRange
                )
            }
        )
    }

    private func trackedParameterBinding(_ rule: VoiceTrackingRule) -> Binding<TrackedParameter> {
        Binding(
            get: { voice.trackingRule?.targetParameter ?? rule.targetParameter },
            set: { newTarget in
                guard var updated = voice.trackingRule else { return }
                updated.targetParameter = newTarget
                if newTarget == .beat {
                    updated.offset = min(30.0, max(-30.0, updated.offset))
                }
                voice.trackingRule = updated
            }
        )
    }

    private func ratioBinding(_ rule: VoiceTrackingRule) -> Binding<Double> {
        Binding(
            get: { voice.trackingRule?.ratio ?? rule.ratio },
            set: { newRatio in
                setTrackingRatio(newRatio)
            }
        )
    }

    private func setTrackingRatio(_ newRatio: Double) {
        guard var updated = voice.trackingRule else { return }
        let safe = newRatio.isFinite ? min(8.0, max(0.1, newRatio)) : 1.0
        updated.ratio = safe
        voice.trackingRule = updated
    }

    private func offsetBinding(_ rule: VoiceTrackingRule, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { voice.trackingRule?.offset ?? rule.offset },
            set: { newOffset in
                guard var updated = voice.trackingRule else { return }
                let safe = newOffset.isFinite ? min(range.upperBound, max(range.lowerBound, newOffset)) : 0.0
                updated.offset = safe
                voice.trackingRule = updated
            }
        )
    }

    private func formatPercent(_ value: Double) -> String {
        guard value.isFinite else { return "50%" }
        return String(format: "%.0f%%", min(1.0, max(0.0, value)) * 100.0)
    }

    private func formatPan(_ value: Double) -> String {
        guard value.isFinite else { return String(localized: "Center") }
        let clamped = min(1.0, max(-1.0, value))
        if abs(clamped) < 0.02 {
            return String(localized: "Center")
        }
        let pct = Int((abs(clamped) * 100.0).rounded())
        return clamped < 0 ? "L \(pct)%" : "R \(pct)%"
    }
}
