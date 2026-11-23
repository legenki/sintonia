import AppKit
import SwiftUI

/// Native macOS menu bar commands (`WaveForge`, `File`, `Playback`, `Window`) wired to `MacAppCoordinator`.
public struct MacCommands: Commands {
    @Bindable private var coordinator: MacAppCoordinator
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.isTextInputFocused) private var isTextInputFocused

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About WaveForge") {
                registerOpener()
                coordinator.requestShowAbout()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Preset") {
                registerOpener()
                coordinator.requestCreateNewPreset()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Import Preset…") {
                registerOpener()
                coordinator.requestOpenImportPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Export Audio…") {
                registerOpener()
                coordinator.requestShowExport()
            }
            .keyboardShortcut("e", modifiers: .command)
        }

        CommandMenu("Playback") {
            let allowsShortcuts = allowsPlayPauseSpaceShortcut()
            let spaceShortcut: KeyboardShortcut? = allowsShortcuts
                ? KeyboardShortcut(.space, modifiers: [])
                : nil
            let skipBackShortcut: KeyboardShortcut? = allowsShortcuts
                ? KeyboardShortcut(.leftArrow, modifiers: .command)
                : nil
            let skipForwardShortcut: KeyboardShortcut? = allowsShortcuts
                ? KeyboardShortcut(.rightArrow, modifiers: .command)
                : nil
            let increaseGainShortcut: KeyboardShortcut? = allowsShortcuts
                ? KeyboardShortcut(.upArrow, modifiers: .command)
                : nil
            let decreaseGainShortcut: KeyboardShortcut? = allowsShortcuts
                ? KeyboardShortcut(.downArrow, modifiers: .command)
                : nil

            Button(coordinator.engine.isPlaying ? "Pause" : "Play") {
                guard allowsPlayPauseSpaceShortcut() else {
                    return
                }
                coordinator.engine.togglePlayPause()
            }
            .keyboardShortcut(spaceShortcut)

            Button("Skip Back 30s") {
                coordinator.engine.skip(by: -30.0)
            }
            .keyboardShortcut(skipBackShortcut)

            Button("Skip Forward 30s") {
                coordinator.engine.skip(by: 30.0)
            }
            .keyboardShortcut(skipForwardShortcut)

            Divider()

            Button("Increase Master Gain") {
                var updated = coordinator.engine.liveOverrides
                updated.masterGain = min(1.0, updated.masterGain + 0.05)
                coordinator.engine.updateOverrides(updated)
            }
            .keyboardShortcut(increaseGainShortcut)

            Button("Decrease Master Gain") {
                var updated = coordinator.engine.liveOverrides
                updated.masterGain = max(0.0, updated.masterGain - 0.05)
                coordinator.engine.updateOverrides(updated)
            }
            .keyboardShortcut(decreaseGainShortcut)

            Divider()

            Menu("Output Device") {
                MacOutputDeviceMenuItems(engine: coordinator.engine)
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Player") {
                openAndActivate(WaveForgeWindowID.player)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Library") {
                openAndActivate(WaveForgeWindowID.library)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Studio Rack") {
                openAndActivate(WaveForgeWindowID.studio)
            }
            .keyboardShortcut("2", modifiers: .command)
        }
    }

    private func allowsPlayPauseSpaceShortcut() -> Bool {
        let isFirstResponderTextEditor = coordinator.isTextInputFirstResponder
            || MacAppCoordinator.isFirstResponderTextEditor
        return coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: isTextInputFocused,
            isFirstResponderTextEditor: isFirstResponderTextEditor
        )
    }

    private func registerOpener() {
        coordinator.registerWindowOpener { windowID in
            NSApp.activate()
            openWindow(id: windowID)
        }
    }

    private func openAndActivate(_ windowID: String) {
        registerOpener()
        coordinator.openWindow(id: windowID)
    }
}
