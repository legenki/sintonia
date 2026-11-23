import AppKit
import SwiftUI

/// Dedicated macOS Studio Rack window wrapping `StudioRackView` in wide dual-pane mode
/// and acting as the single canonical presenter of unsaved-edit switch confirmation dialogs.
public struct MacStudioWindowView: View {
    @Bindable private var coordinator: MacAppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    private var conflictPresentedBinding: Binding<Bool> {
        Binding(
            get: { coordinator.pendingConflict != nil },
            set: { isPresented in
                if !isPresented {
                    coordinator.resolveConflictCancel()
                }
            }
        )
    }

    public var body: some View {
        StudioRackView(
            engine: coordinator.engine,
            presetStore: coordinator.presetStore,
            showsDualPaneWhenWide: true,
            externalSyncTrigger: coordinator.studioSyncToken,
            onDirtyStateChanged: { isDirty in
                coordinator.studioHasUnsavedChanges = isDirty
            },
            onRegisterSaveHandler: { saveHandler in
                coordinator.registerStudioSaveHandler(saveHandler)
            },
            onSavedPreset: { _ in
                coordinator.presetsRevision += 1
            },
            onDismiss: {
                dismiss()
            }
        )
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.registerWindowOpener { windowID in
                NSApp.activate()
                openWindow(id: windowID)
            }
        }
        .confirmationDialog(
            "Unsaved Changes",
            isPresented: conflictPresentedBinding,
            titleVisibility: .visible,
            presenting: coordinator.pendingConflict
        ) { _ in
            Button("Save") {
                coordinator.resolveConflictSaveThenProceed()
            }
            Button("Discard Changes", role: .destructive) {
                coordinator.resolveConflictDiscardAndProceed()
            }
            Button("Keep Editing", role: .cancel) {
                coordinator.resolveConflictCancel()
            }
        } message: { _ in
            Text("You have unsaved studio edits. Save before switching presets?")
        }
    }
}
