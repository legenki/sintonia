import SwiftUI
import WaveForgeExport

/// Compact Liquid Glass macOS audio output device selector for the Player header and Menu Bar popover.
public struct MacOutputDeviceMenu: View {
    private let engine: AudioEngineController
    private let compact: Bool

    public init(engine: AudioEngineController, compact: Bool = true) {
        self.engine = engine
        self.compact = compact
    }

    private var selectedDevice: AudioOutputDevice? {
        guard let uid = engine.selectedOutputDeviceUID else { return nil }
        return engine.availableOutputDevices.first { $0.uid == uid }
    }

    private var activeDeviceTitle: String {
        selectedDevice?.name ?? String(localized: "System Default")
    }

    private var activeRoute: AudioOutputRoute {
        selectedDevice?.route ?? engine.outputRoute
    }

    private var routeTint: Color {
        switch activeRoute {
        case .headphones:
            return StudioTheme.alphaColor
        case .speaker:
            return engine.presetHasActiveBinaural ? StudioTheme.betaColor : StudioTheme.secondaryText
        case .other:
            return StudioTheme.secondaryText
        }
    }

    private var routeBadgeKey: LocalizedStringKey {
        switch activeRoute {
        case .headphones:
            return "Headphones"
        case .speaker:
            return "Speaker"
        case .other:
            return "Any Output"
        }
    }

    public var body: some View {
        Menu {
            MacOutputDeviceMenuItems(engine: engine)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbolName(for: activeRoute))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(routeTint)

                Text(verbatim: activeDeviceTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !compact {
                    Spacer(minLength: 4)

                    Text(routeBadgeKey)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(routeTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(routeTint.opacity(0.16)))
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: compact ? 150 : .infinity, alignment: .leading)
            .studioGlassCapsule(tint: routeTint.opacity(0.12), interactive: true)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text("Audio Output"))
        .accessibilityValue(Text(verbatim: activeDeviceTitle))
    }

    internal static func symbolName(for route: AudioOutputRoute) -> String {
        switch route {
        case .headphones:
            return "headphones"
        case .speaker:
            return "speaker.wave.2"
        case .other:
            return "hifispeaker"
        }
    }
}

/// Reusable CoreAudio output device menu items shared by `MacOutputDeviceMenu` and `MacCommands`.
internal struct MacOutputDeviceMenuItems: View {
    let engine: AudioEngineController

    private var defaultDeviceRoute: AudioOutputRoute {
        engine.availableOutputDevices.first(where: \.isSystemDefault)?.route ?? engine.outputRoute
    }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { engine.selectedOutputDeviceUID == nil },
                set: { _ in
                    engine.selectOutputDevice(uid: nil)
                }
            )
        ) {
            Label(
                String(localized: "System Default"),
                systemImage: MacOutputDeviceMenu.symbolName(for: defaultDeviceRoute)
            )
        }

        if !engine.availableOutputDevices.isEmpty {
            Divider()

            ForEach(engine.availableOutputDevices) { device in
                Toggle(
                    isOn: Binding(
                        get: { engine.selectedOutputDeviceUID == device.uid },
                        set: { _ in
                            engine.selectOutputDevice(uid: device.uid)
                        }
                    )
                ) {
                    Label(
                        device.name,
                        systemImage: MacOutputDeviceMenu.symbolName(for: device.route)
                    )
                }
            }
        }
    }
}
