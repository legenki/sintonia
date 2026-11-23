import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Primary macOS Player window hosting `PlayerView`, output device routing menu,
/// Export/About sheets, `.fileImporter` (`⌘O`), Finder `.bwg`/`.waveforge` drop import, and import alerts/toasts.
public struct MacPlayerWindowView: View {
    @Bindable private var coordinator: MacAppCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted: Bool = false

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    private var playerImportAlertBinding: Binding<ImportAlertContent?> {
        Binding(
            get: {
                coordinator.importPresentationTarget == .player ? coordinator.importAlert : nil
            },
            set: { newValue in
                if coordinator.importPresentationTarget == .player {
                    coordinator.importAlert = newValue
                }
            }
        )
    }

    public var body: some View {
        ZStack(alignment: .top) {
            PlayerView(
                engine: coordinator.engine,
                onOpenLibrary: {
                    coordinator.openWindow(id: WaveForgeWindowID.library)
                },
                onOpenStudio: {
                    coordinator.openWindow(id: WaveForgeWindowID.studio)
                },
                onOpenExport: {
                    coordinator.requestShowExport()
                },
                onOpenAbout: {
                    coordinator.requestShowAbout()
                }
            ) {
                MacOutputDeviceMenu(engine: coordinator.engine, compact: true)
            }

            if coordinator.importPresentationTarget == .player,
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
        .frame(minWidth: 380, maxWidth: 540, minHeight: 620, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.registerWindowOpener { windowID in
                NSApp.activate()
                openWindow(id: windowID)
            }
        }
        .sheet(item: $coordinator.activePlayerSheet) { sheet in
            switch sheet {
            case .export:
                ExportSheetView(
                    preset: coordinator.engine.currentPreset,
                    accentColor: coordinator.engine.dominantBand.accentColor,
                    onDismiss: {
                        coordinator.activePlayerSheet = nil
                    }
                )

            case .about:
                AboutSheetView(
                    accentColor: coordinator.engine.dominantBand.accentColor,
                    onDismiss: {
                        coordinator.activePlayerSheet = nil
                    }
                )
            }
        }
        .fileImporter(
            isPresented: $coordinator.isShowingFileImporter,
            allowedContentTypes: [.waveForgePreset, .brainWaveGenerator],
            allowsMultipleSelection: true
        ) { result in
            coordinator.handleFileImporterResult(result, source: .player)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            MacDropHandler.handleDrop(providers: providers) { urls in
                coordinator.handleIncomingURLs(urls, source: .player)
            }
        }
        .importResultAlert(playerImportAlertBinding)
        .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
        .animation(
            .easeInOut(duration: 0.22),
            value: coordinator.importPresentationTarget == .player && coordinator.importToastPresetName != nil
        )
    }
}
