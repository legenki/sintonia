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
            onRegisterDiscardHandler: { discardHandler in
                coordinator.registerStudioDiscardHandler(discardHandler)
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
        .background(
            MacStudioWindowBridge(
                isDocumentEdited: coordinator.studioHasUnsavedChanges,
                shouldInterceptClose: { coordinator.studioHasUnsavedChanges },
                onInterceptedClose: { coordinator.requestCloseStudioWindow() },
                onRegisterCloseHandler: { closeHandler in
                    coordinator.registerStudioCloseHandler(closeHandler)
                }
            )
            .allowsHitTesting(false)
        )
        .onAppear {
            coordinator.registerWindowOpener { windowID in
                NSApp.activate()
                openWindow(id: windowID)
            }
        }
        .onDisappear {
            coordinator.registerStudioCloseHandler(nil)
            if coordinator.pendingConflict == .closeStudio {
                coordinator.resolveConflictCancel()
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
        } message: { conflict in
            if case .closeStudio = conflict {
                Text("You have unsaved changes to this preset. Save before closing?")
            } else {
                Text("You have unsaved studio edits. Save before switching presets?")
            }
        }
    }
}

/// Bridges the hosting `NSWindow` for macOS Studio so the close button shows the unsaved-document dot
/// (`isDocumentEdited`) and intercepts `⌘W` / red-button close with the Save/Discard dialog.
private struct MacStudioWindowBridge: NSViewRepresentable {
    let isDocumentEdited: Bool
    let shouldInterceptClose: () -> Bool
    let onInterceptedClose: () -> Void
    let onRegisterCloseHandler: ((() -> Void)?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldInterceptClose: shouldInterceptClose,
            onInterceptedClose: onInterceptedClose,
            onRegisterCloseHandler: onRegisterCloseHandler
        )
    }

    func makeNSView(context: Context) -> BridgeNSView {
        let view = BridgeNSView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window, isDocumentEdited: isDocumentEdited)
        }
        return view
    }

    func updateNSView(_ nsView: BridgeNSView, context: Context) {
        context.coordinator.shouldInterceptClose = shouldInterceptClose
        context.coordinator.onInterceptedClose = onInterceptedClose
        context.coordinator.onRegisterCloseHandler = onRegisterCloseHandler
        context.coordinator.attach(to: nsView.window, isDocumentEdited: isDocumentEdited)
    }

    static func dismantleNSView(_ nsView: BridgeNSView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class BridgeNSView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldInterceptClose: () -> Bool
        var onInterceptedClose: () -> Void
        var onRegisterCloseHandler: ((() -> Void)?) -> Void

        private weak var attachedWindow: NSWindow?
        private nonisolated(unsafe) weak var originalDelegate: (any NSWindowDelegate)?
        private var isProgrammaticClose = false

        init(
            shouldInterceptClose: @escaping () -> Bool,
            onInterceptedClose: @escaping () -> Void,
            onRegisterCloseHandler: @escaping ((() -> Void)?) -> Void
        ) {
            self.shouldInterceptClose = shouldInterceptClose
            self.onInterceptedClose = onInterceptedClose
            self.onRegisterCloseHandler = onRegisterCloseHandler
        }

        func attach(to window: NSWindow?, isDocumentEdited: Bool) {
            guard let window else {
                detach()
                return
            }

            window.isDocumentEdited = isDocumentEdited

            if attachedWindow !== window {
                detach()
                attachedWindow = window
                if window.delegate !== self {
                    originalDelegate = window.delegate
                    window.delegate = self
                }
                onRegisterCloseHandler { [weak self] in
                    guard let self, let window = self.attachedWindow else { return }
                    self.isProgrammaticClose = true
                    window.isDocumentEdited = false
                    window.performClose(nil)
                    self.isProgrammaticClose = false
                }
            }
        }

        func detach() {
            if let window = attachedWindow {
                window.isDocumentEdited = false
                if window.delegate === self {
                    window.delegate = originalDelegate
                }
            }
            attachedWindow = nil
            originalDelegate = nil
            onRegisterCloseHandler(nil)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isProgrammaticClose {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            if shouldInterceptClose() {
                onInterceptedClose()
                return false
            }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) {
                return true
            }
            return originalDelegate?.responds(to: aSelector) ?? false
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if super.responds(to: aSelector) {
                return self
            }
            if let originalDelegate, originalDelegate.responds(to: aSelector) {
                return originalDelegate
            }
            return nil
        }
    }
}
