import Foundation
import PresetKit
import SwiftUI
import SynthCore

@main
struct WaveForgeApp: App {
    private let presetStore: PresetStore
    @State private var engine: AudioEngineController

    init() {
        let storageURL = Self.defaultPresetStorageURL()
        self.presetStore = PresetStore(storageDirectory: storageURL)
        self._engine = State(initialValue: AudioEngineController(preset: PresetCatalog.builtInPresets[0]))
    }

    var body: some Scene {
        WindowGroup {
            WaveForgeRootView(engine: engine, presetStore: presetStore)
        }
    }

    private static func defaultPresetStorageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("WaveForge", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true)
    }
}

/// Root coordinator wiring `PlayerView`, `LibraryView`, `StudioRackView`, and system `.onOpenURL` imports.
struct WaveForgeRootView: View {
    let engine: AudioEngineController
    let presetStore: PresetStore

    @State private var isShowingLibrary: Bool = false
    @State private var isShowingStudio: Bool = false
    @State private var pendingOpenStudioAfterLibraryDismiss: Bool = false
    @State private var presetsRevision: Int = 0

    @State private var importAlert: ImportAlertContent? = nil
    @State private var pendingImportAlertAfterModalDismiss: ImportAlertContent? = nil
    @State private var importToastPresetName: String? = nil
    @State private var toastDismissTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack(alignment: .top) {
            PlayerView(
                engine: engine,
                onOpenLibrary: {
                    isShowingLibrary = true
                },
                onOpenStudio: {
                    isShowingStudio = true
                }
            )

            if let toastName = importToastPresetName {
                ImportConfirmationToast(presetName: toastName) {
                    dismissImportToast()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingLibrary, onDismiss: handleModalDismissed) {
            LibraryView(
                engine: engine,
                presetStore: presetStore,
                presetsRevision: presetsRevision,
                onPresetsChanged: {
                    presetsRevision += 1
                },
                onSelectPreset: { _ in },
                onOpenStudioForNewPreset: {
                    pendingOpenStudioAfterLibraryDismiss = true
                    isShowingLibrary = false
                },
                onDismiss: {
                    isShowingLibrary = false
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingStudio, onDismiss: handleModalDismissed) {
            StudioRackView(
                engine: engine,
                presetStore: presetStore,
                onSavedPreset: { _ in
                    presetsRevision += 1
                },
                onDismiss: {
                    isShowingStudio = false
                }
            )
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .importResultAlert($importAlert)
        .animation(.easeInOut(duration: 0.22), value: importToastPresetName != nil)
        .onDisappear {
            toastDismissTask?.cancel()
            toastDismissTask = nil
        }
    }

    // MARK: - System `.bwg` / `.waveforge` Import Handling

    private func handleIncomingURL(_ url: URL) {
        do {
            let outcome = try PresetImportCoordinator.importFile(at: url, into: presetStore)
            presetsRevision += 1
            engine.load(outcome.preset)

            if let alert = ImportAlertContent.fromOutcome(outcome) {
                presentImportAlertSafely(alert)
            } else {
                if isShowingLibrary {
                    isShowingLibrary = false
                }
                if isShowingStudio {
                    isShowingStudio = false
                }
                showImportToast(for: outcome.preset.name)
            }
        } catch {
            presentImportAlertSafely(ImportAlertContent.fromError(error))
        }
    }

    private func presentImportAlertSafely(_ alert: ImportAlertContent) {
        if isShowingLibrary || isShowingStudio {
            pendingImportAlertAfterModalDismiss = alert
            isShowingLibrary = false
            isShowingStudio = false
        } else {
            importAlert = alert
        }
    }

    private func handleModalDismissed() {
        if pendingOpenStudioAfterLibraryDismiss && !isShowingLibrary {
            pendingOpenStudioAfterLibraryDismiss = false
            isShowingStudio = true
            return
        }

        if let pendingAlert = pendingImportAlertAfterModalDismiss, !isShowingLibrary, !isShowingStudio {
            pendingImportAlertAfterModalDismiss = nil
            importAlert = pendingAlert
        }
    }

    private func showImportToast(for presetName: String) {
        toastDismissTask?.cancel()
        importToastPresetName = presetName
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            importToastPresetName = nil
        }
    }

    private func dismissImportToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        importToastPresetName = nil
    }
}
