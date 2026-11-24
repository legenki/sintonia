import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dedicated macOS Preset Library window wrapping `LibraryView` with adaptive desktop columns,
/// double-click auto-play, Studio template launch, and Finder `.bwg`/`.sintonia` drop import.
public struct MacLibraryWindowView: View {
    @Bindable private var coordinator: MacAppCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted: Bool = false

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    private var libraryImportAlertBinding: Binding<ImportAlertContent?> {
        Binding(
            get: {
                coordinator.importPresentationTarget == .library ? coordinator.importAlert : nil
            },
            set: { newValue in
                if coordinator.importPresentationTarget == .library {
                    coordinator.importAlert = newValue
                }
            }
        )
    }

    public var body: some View {
        ZStack(alignment: .top) {
            LibraryView(
                engine: coordinator.engine,
                presetStore: coordinator.presetStore,
                presetsRevision: coordinator.presetsRevision,
                adaptiveDesktopGrid: true,
                hidesDoneButton: true,
                loadsDirectlyOnSelect: false,
                onPresetsChanged: {
                    coordinator.presetsRevision += 1
                },
                onSelectPreset: { preset in
                    coordinator.requestLoadPreset(preset, autoPlay: false)
                },
                onDoubleClickPreset: { preset in
                    coordinator.requestLoadPreset(preset, autoPlay: true)
                },
                onCreateNewTemplate: { _ in
                    coordinator.requestCreateNewPreset()
                }
            )

            if coordinator.importPresentationTarget == .library,
               let toastName = coordinator.importToastPresetName {
                ImportConfirmationToast(presetName: toastName) {
                    coordinator.dismissImportToast()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }

            if isDropTargeted {
                MacPresetDropOverlay(accentColor: coordinator.engine.dominantBand.accentColor)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.registerWindowOpener { windowID in
                NSApp.activate()
                openWindow(id: windowID)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            MacDropHandler.handleDrop(providers: providers) { urls in
                coordinator.handleIncomingURLs(urls, source: .library)
            }
        }
        .importResultAlert(libraryImportAlertBinding)
        .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
        .animation(
            .easeInOut(duration: 0.22),
            value: coordinator.importPresentationTarget == .library && coordinator.importToastPresetName != nil
        )
    }
}
