import AppKit
import PresetKit
import SwiftUI

/// Compact 310 pt macOS `MenuBarExtra` popover providing instant transport, Master level,
/// quick preset switching, CoreAudio output device routing, and window launch actions.
public struct MacMenuBarView: View {
    @Bindable private var coordinator: MacAppCoordinator
    @Environment(\.openWindow) private var openWindow

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    private var engine: AudioEngineController {
        coordinator.engine
    }

    private var accentColor: Color {
        engine.dominantBand.accentColor
    }

    private var progressFraction: Double {
        guard engine.duration > 0 else { return 0.0 }
        return min(1.0, max(0.0, engine.currentTime / engine.duration))
    }

    private var masterBinding: Binding<Double> {
        Binding(
            get: { engine.liveOverrides.masterGain },
            set: { newValue in
                var updated = engine.liveOverrides
                updated.masterGain = newValue
                engine.updateOverrides(updated)
            }
        )
    }

    public var body: some View {
        let _ = coordinator.presetsRevision
        let allPresets = coordinator.presetStore.allPresets()
        let builtInPresets = allPresets.filter(\.isBuiltIn)
        let customPresets = allPresets.filter { !$0.isBuiltIn }

        VStack(alignment: .leading, spacing: 12) {
            headerSection
            timerSection
            transportSection
            masterGainSection

            Divider()
                .overlay(StudioTheme.hairlineHighlight)

            quickPresetMenu(builtInPresets: builtInPresets, customPresets: customPresets)
            MacOutputDeviceMenu(engine: engine, compact: false)

            Divider()
                .overlay(StudioTheme.hairlineHighlight)

            windowLaunchSection

            Divider()
                .overlay(StudioTheme.hairlineHighlight)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Label("Quit Sintonia", systemImage: "power")
                    Spacer()
                    Text(verbatim: "⌘Q")
                        .font(.caption2.monospaced())
                        .foregroundStyle(StudioTheme.mutedText)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(StudioTheme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 310)
        .background(StudioTheme.rackBackgroundGradient)
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.registerWindowOpener { windowID in
                NSApp.activate()
                openWindow(id: windowID)
            }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: engine.currentPreset.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(categoryTitleKey(for: engine.currentPreset.category))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            BrainwaveBandBadge(
                band: engine.dominantBand,
                beatHz: engine.dominantBeatHz,
                compact: true
            )
        }
    }

    private var timerSection: some View {
        VStack(spacing: 5) {
            HStack {
                Text(verbatim: StudioTheme.formatTime(engine.currentTime))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
                Spacer()
                Text(verbatim: StudioTheme.formatTime(engine.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioTheme.secondaryText)
            }

            ProgressView(value: progressFraction, total: 1.0)
                .progressViewStyle(.linear)
                .tint(accentColor)
        }
        .padding(9)
        .studioRackCard(cornerRadius: 12)
    }

    private var transportSection: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)

            Button {
                engine.skip(by: -30.0)
            } label: {
                Image(systemName: "gobackward.30")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip Back 30s"))

            Button {
                engine.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(accentColor)
                        .shadow(color: accentColor.opacity(engine.isPlaying ? 0.55 : 0.3), radius: 7)

                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(StudioTheme.chassisGraphite)
                        .offset(x: engine.isPlaying ? 0 : 1)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(engine.isPlaying ? "Pause" : "Play"))

            Button {
                engine.skip(by: 30.0)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip Forward 30s"))

            Spacer(minLength: 0)
        }
    }

    private var masterGainSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Master")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Text(verbatim: "\(Int((engine.liveOverrides.masterGain * 100.0).rounded()))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(StudioTheme.primaryText)
            }
            Slider(value: masterBinding, in: 0.0...1.0)
                .tint(accentColor)
        }
    }

    private func quickPresetMenu(builtInPresets: [Preset], customPresets: [Preset]) -> some View {
        Menu {
            ForEach(builtInPresets) { preset in
                presetMenuItem(preset)
            }

            if !customPresets.isEmpty {
                Divider()
                ForEach(customPresets) { preset in
                    presetMenuItem(preset)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accentColor)

                Text(verbatim: engine.currentPreset.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioGlassCapsule(tint: accentColor.opacity(0.1), interactive: true)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text("Preset"))
    }

    private func presetMenuItem(_ preset: Preset) -> some View {
        Toggle(
            isOn: Binding(
                get: { engine.currentPreset.id == preset.id },
                set: { _ in
                    coordinator.requestLoadPreset(preset, autoPlay: false)
                }
            )
        ) {
            Text(preset.name)
        }
    }

    private var windowLaunchSection: some View {
        VStack(spacing: 6) {
            windowLaunchButton(
                titleKey: "Player",
                systemImage: "waveform.path.ecg",
                shortcutLabel: "⌘1",
                windowID: SintoniaWindowID.player
            )
            windowLaunchButton(
                titleKey: "Library",
                systemImage: "books.vertical.fill",
                shortcutLabel: "⌘L",
                windowID: SintoniaWindowID.library
            )
            windowLaunchButton(
                titleKey: "Studio Rack",
                systemImage: "slider.horizontal.3",
                shortcutLabel: "⌘2",
                windowID: SintoniaWindowID.studio
            )
        }
    }

    private func windowLaunchButton(
        titleKey: LocalizedStringKey,
        systemImage: String,
        shortcutLabel: String,
        windowID: String
    ) -> some View {
        Button {
            openWindowAndActivate(windowID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 16)

                Text(titleKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)

                Spacer()

                Text(verbatim: shortcutLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(StudioTheme.mutedText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openWindowAndActivate(_ windowID: String) {
        NSApp.activate()
        openWindow(id: windowID)
    }

    private func categoryTitleKey(for category: PresetCategory) -> LocalizedStringKey {
        switch category {
        case .focus: return "Focus"
        case .relax: return "Relax"
        case .sleep: return "Sleep"
        case .meditation: return "Meditation"
        case .study: return "Study"
        case .creative: return "Creative"
        case .custom: return "Custom"
        }
    }
}
