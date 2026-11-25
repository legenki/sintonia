import PresetKit
import SwiftUI
import SynthCore

/// Hardware inspector for the global stereo colored `NoiseLayer`, covering enablement,
/// noise level & color offsets, and beat-synchronized pulse modulation (`Auto` or `Ch 1...10`).
public struct NoiseInspectorView: View {
    @Binding private var noise: NoiseLayer
    private let voices: [Voice]
    private let currentTime: Double
    private let accentColor: Color
    private let onEditCurve: ((CurveEditorParameter) -> Void)?

    @State private var haptics = StudioControlHaptics()

    public init(
        noise: Binding<NoiseLayer>,
        voices: [Voice],
        currentTime: Double = 0.0,
        accentColor: Color = StudioTheme.thetaColor,
        onEditCurve: ((CurveEditorParameter) -> Void)? = nil
    ) {
        self._noise = noise
        self.voices = voices
        self.currentTime = currentTime
        self.accentColor = accentColor
        self.onEditCurve = onEditCurve
    }

    private var safeTime: Double {
        currentTime.isFinite ? max(0.0, currentTime) : 0.0
    }

    private var currentVolume: Double {
        noise.volumeCurve.evaluate(at: safeTime)
    }

    private var currentSmoothness: Double {
        noise.smoothnessCurve.evaluate(at: safeTime)
    }

    private var safePulseSourceIndex: Int? {
        guard let idx = noise.pulseSourceVoiceIndex, voices.indices.contains(idx) else {
            return nil
        }
        return idx
    }

    public var body: some View {
        VStack(spacing: 12) {
            enableAndMixCard
            pulseSyncCard
        }
    }

    private var enableAndMixCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(noise.isEnabled ? accentColor : StudioTheme.ledOff)
                    .frame(width: 8, height: 8)
                    .shadow(color: noise.isEnabled ? accentColor.opacity(0.8) : .clear, radius: 4)

                Text("Noise Layer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)

                Spacer(minLength: 8)

                Toggle("Enable Noise", isOn: $noise.isEnabled)
                    .tint(accentColor)
                    .labelsHidden()
                    .accessibilityLabel(Text("Enable Noise"))
            }

            HStack(spacing: 12) {
                StudioKnob(
                    value: volumeBinding,
                    range: PresetLimits.unitRange,
                    defaultValue: 0.2,
                    title: "Volume",
                    valueFormatter: formatPercent,
                    accentColor: accentColor,
                    size: 56
                )
                .frame(maxWidth: .infinity)

                StudioKnob(
                    value: smoothnessBinding,
                    range: PresetLimits.unitRange,
                    defaultValue: 0.5,
                    title: "Noise Color",
                    valueFormatter: CurveEditorParameter.noiseColor.formatValue,
                    accentColor: StudioTheme.betaColor,
                    size: 56
                )
                .frame(maxWidth: .infinity)
            }
            .disabled(!noise.isEnabled)
            .opacity(noise.isEnabled ? 1.0 : 0.5)

            if let onEditCurve {
                HStack(spacing: 8) {
                    curveButton(title: "Noise Volume", parameter: .noiseVolume, action: onEditCurve)
                    curveButton(title: "Noise Color", parameter: .noiseColor, action: onEditCurve)
                }
            }
        }
        .padding(12)
        .studioRackCard(cornerRadius: 16)
    }

    private var pulseSyncCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(noise.pulseEnabled && noise.isEnabled ? accentColor : StudioTheme.secondaryText)

                Text("Pulse Sync")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)

                Spacer(minLength: 8)

                Toggle("Pulse Sync", isOn: $noise.pulseEnabled)
                    .tint(accentColor)
                    .labelsHidden()
                    .accessibilityLabel(Text("Pulse Sync"))
            }

            HStack(spacing: 14) {
                StudioKnob(
                    value: $noise.pulseDepth,
                    range: PresetLimits.unitRange,
                    defaultValue: 0.4,
                    title: "Pulse Depth",
                    valueFormatter: formatPercent,
                    accentColor: accentColor,
                    size: 54
                )
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pulse Source")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .textCase(.uppercase)

                    pulseSourceMenu
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!noise.isEnabled || !noise.pulseEnabled)
            .opacity(noise.isEnabled && noise.pulseEnabled ? 1.0 : 0.5)
        }
        .padding(12)
        .studioRackCard(cornerRadius: 16)
    }

    private var pulseSourceMenu: some View {
        Menu {
            Button {
                haptics.prepare()
                noise.pulseSourceVoiceIndex = nil
                haptics.fireModeShift()
            } label: {
                HStack {
                    Text("Auto")
                    if safePulseSourceIndex == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !voices.isEmpty {
                Divider()
                ForEach(voices.indices, id: \.self) { index in
                    Button {
                        haptics.prepare()
                        noise.pulseSourceVoiceIndex = index
                        haptics.fireModeShift()
                    } label: {
                        HStack {
                            Text(verbatim: "\(String(localized: "Ch \(index + 1)")) • \(voices[index].name)")
                            if safePulseSourceIndex == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let sourceIdx = safePulseSourceIndex {
                    Text("Ch \(sourceIdx + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(accentColor)
                } else {
                    Text("Auto")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioTheme.recessedWell))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioTheme.hairlineHighlight, lineWidth: 0.75))
        }
        .studioMenuButtonStyle()
        .accessibilityLabel(Text("Pulse Source"))
    }

    private func curveButton(
        title: LocalizedStringKey,
        parameter: CurveEditorParameter,
        action: @escaping (CurveEditorParameter) -> Void
    ) -> some View {
        Button {
            action(parameter)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(parameter.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(parameter.accentColor.opacity(0.14)))
            .overlay(Capsule().strokeBorder(parameter.accentColor.opacity(0.42), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bindings & Formatting

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { currentVolume },
            set: { newValue in
                noise.volumeCurve = StudioCurveAdjustment.adjustVolumeCurve(
                    noise.volumeCurve,
                    toNewValue: newValue,
                    at: safeTime
                )
            }
        )
    }

    private var smoothnessBinding: Binding<Double> {
        Binding(
            get: { currentSmoothness },
            set: { newValue in
                noise.smoothnessCurve = StudioCurveAdjustment.shiftCurve(
                    noise.smoothnessCurve,
                    toNewValue: newValue,
                    at: safeTime,
                    clampedTo: PresetLimits.unitRange
                )
            }
        )
    }

    private func formatPercent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return String(format: "%.0f%%", min(1.0, max(0.0, value)) * 100.0)
    }
}
