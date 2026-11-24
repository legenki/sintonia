import Foundation
import PresetKit
import SwiftUI
import SynthCore
import WaveForgeExport

@main
struct WaveForgeApp: App {
    private let presetStore: PresetStore
    @State private var engine: AudioEngineController

    init() {
        SessionExporter.cleanupStaleTemporaryExports()
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
    private enum RootSheet: String, Identifiable {
        case library
        case export
        case about

        var id: String { rawValue }
    }

    let engine: AudioEngineController
    let presetStore: PresetStore

    @State private var activeSheet: RootSheet? = nil
    @State private var isShowingStudio: Bool = false
    @State private var isDismissingSheet: Bool = false
    @State private var isDismissingStudio: Bool = false
    @State private var pendingOpenStudioAfterLibraryDismiss: Bool = false
    @State private var presetsRevision: Int = 0

    @State private var importAlert: ImportAlertContent? = nil
    @State private var pendingImportAlertAfterModalDismiss: ImportAlertContent? = nil
    @State private var importToastPresetName: String? = nil
    @State private var toastDismissTask: Task<Void, Never>? = nil

    @State private var studioHasUnsavedChanges: Bool = false
    @State private var studioHandlers = StudioHandlerBox()
    @State private var pendingStudioImport: PresetImportOutcome? = nil

    private var pendingStudioImportBinding: Binding<Bool> {
        Binding(
            get: { pendingStudioImport != nil },
            set: { if !$0 { pendingStudioImport = nil } }
        )
    }

    private var isModalBusy: Bool {
        activeSheet != nil || isShowingStudio || isDismissingSheet || isDismissingStudio
    }

    var body: some View {
        ZStack(alignment: .top) {
            PlayerView(
                engine: engine,
                onOpenLibrary: {
                    presentSheet(.library)
                },
                onOpenStudio: {
                    presentStudio()
                },
                onOpenExport: {
                    presentSheet(.export)
                },
                onOpenAbout: {
                    presentSheet(.about)
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
        .sheet(item: $activeSheet, onDismiss: handleSheetDismissed) { sheet in
            switch sheet {
            case .library:
                LibraryView(
                    engine: engine,
                    presetStore: presetStore,
                    presetsRevision: presetsRevision,
                    onPresetsChanged: {},
                    onSelectPreset: { _ in },
                    onOpenStudioForNewPreset: {
                        pendingOpenStudioAfterLibraryDismiss = true
                        dismissActiveSheet()
                    },
                    onDismiss: {
                        dismissActiveSheet()
                    }
                )

            case .export:
                ExportSheetView(
                    preset: engine.currentPreset,
                    accentColor: engine.dominantBand.accentColor,
                    onDismiss: {
                        dismissActiveSheet()
                    }
                )

            case .about:
                AboutSheetView(
                    accentColor: engine.dominantBand.accentColor,
                    onDismiss: {
                        dismissActiveSheet()
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $isShowingStudio, onDismiss: handleStudioDismissed) {
            StudioRackView(
                engine: engine,
                presetStore: presetStore,
                onDirtyStateChanged: { dirty in
                    studioHasUnsavedChanges = dirty
                },
                onRegisterSaveHandler: { handler in
                    studioHandlers.save = handler
                },
                onSavedPreset: { _ in
                    presetsRevision += 1
                },
                onDismiss: {
                    dismissStudio()
                }
            )
            .confirmationDialog(
                "Unsaved Changes",
                isPresented: pendingStudioImportBinding,
                titleVisibility: .visible,
                presenting: pendingStudioImport
            ) { outcome in
                Button("Save") {
                    pendingStudioImport = nil
                    if studioHandlers.save?() ?? true {
                        applyImportOutcome(outcome)
                    }
                }
                Button("Discard Changes", role: .destructive) {
                    pendingStudioImport = nil
                    applyImportOutcome(outcome)
                }
                Button("Keep Editing", role: .cancel) {
                    pendingStudioImport = nil
                }
            } message: { _ in
                Text("You have unsaved studio edits. Save before switching presets?")
            }
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

    // MARK: - Modal Presentation & Dismissal Coordination

    private func presentSheet(_ sheet: RootSheet) {
        guard !isModalBusy else { return }
        activeSheet = sheet
    }

    private func presentStudio() {
        guard !isModalBusy else { return }
        isShowingStudio = true
    }

    private func dismissActiveSheet() {
        guard activeSheet != nil else { return }
        isDismissingSheet = true
        activeSheet = nil
    }

    private func dismissStudio() {
        guard isShowingStudio else { return }
        isDismissingStudio = true
        isShowingStudio = false
    }

    private func dismissAllModals() {
        dismissActiveSheet()
        dismissStudio()
    }

    private func handleSheetDismissed() {
        isDismissingSheet = false
        processPendingTransitions()
    }

    private func handleStudioDismissed() {
        isDismissingStudio = false
        processPendingTransitions()
    }

    private func processPendingTransitions() {
        guard !isModalBusy else { return }

        if pendingOpenStudioAfterLibraryDismiss {
            pendingOpenStudioAfterLibraryDismiss = false
            isShowingStudio = true
            return
        }

        if let pendingAlert = pendingImportAlertAfterModalDismiss {
            pendingImportAlertAfterModalDismiss = nil
            importAlert = pendingAlert
        }
    }

    // MARK: - System `.bwg` / `.waveforge` Import Handling

    private func handleIncomingURL(_ url: URL) {
        pendingOpenStudioAfterLibraryDismiss = false

        Task { @MainActor in
            let results = await PresetImportCoordinator.importFiles(at: [url], into: presetStore)
            guard let result = results.first else { return }
            switch result {
            case .success(let outcome):
                presetsRevision += 1
                // Never silently replace unsaved Studio edits: ask first, from inside the Studio cover.
                if isShowingStudio && !isDismissingStudio && studioHasUnsavedChanges {
                    pendingStudioImport = outcome
                } else {
                    applyImportOutcome(outcome)
                }
            case .failure(let error):
                presentImportAlertSafely(ImportAlertContent.fromError(error))
            }
        }
    }

    private func applyImportOutcome(_ outcome: PresetImportOutcome) {
        engine.load(outcome.preset)

        if let alert = ImportAlertContent.fromOutcome(outcome) {
            presentImportAlertSafely(alert)
        } else {
            dismissAllModals()
            showImportToast(for: outcome.preset.name)
        }
    }

    private func presentImportAlertSafely(_ alert: ImportAlertContent) {
        if isModalBusy {
            pendingImportAlertAfterModalDismiss = alert
            dismissAllModals()
        } else {
            importAlert = alert
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

/// Holds Studio's live save handler without triggering view updates when it is (re)registered.
@MainActor
private final class StudioHandlerBox {
    var save: (() -> Bool)?
}
