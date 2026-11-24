import AppKit
import Foundation
import Observation
import PresetKit
import SwiftUI
import Synchronization
import SynthCore
import UniformTypeIdentifiers
import WaveForgeExport

/// Canonical SwiftUI `Window` scene identifiers for the WaveForge macOS desktop app.
public enum WaveForgeWindowID: Sendable {
    public static let player = "player"
    public static let library = "library"
    public static let studio = "studio"
}

/// Coordinates multi-window macOS state, menu commands, menu bar popover controls,
/// drag-and-drop / Finder `.bwg` & `.waveforge` imports, and Studio unsaved-edit conflict guards.
@MainActor
@Observable
public final class MacAppCoordinator {
    /// Modal sheets presented exclusively by the Player window.
    public enum PlayerModalSheet: String, Identifiable, Sendable {
        case export
        case about

        public var id: String { rawValue }
    }

    /// Identifies which window owns presentation of import alerts and confirmation toasts.
    public enum ImportPresentationTarget: String, Sendable, Equatable {
        case player
        case library
    }

    /// Origin of an incoming `.bwg` or `.waveforge` URL import request.
    public enum ImportSource: Sendable, Equatable {
        case external
        case player
        case library

        public var presentationTarget: ImportPresentationTarget {
            switch self {
            case .external, .player:
                return .player
            case .library:
                return .library
            }
        }
    }

    /// Deferred preset switch or Studio close waiting on the user to Save, Discard, or Keep Editing unsaved Studio changes.
    public enum PendingStudioConflict: Identifiable, Equatable, Sendable {
        case loadPreset(Preset, autoPlay: Bool)
        case createNewTemplate(Preset)
        case importPreset(Preset, toastPresetName: String?, target: ImportPresentationTarget)
        case closeStudio

        public var id: String {
            switch self {
            case .loadPreset(let preset, let autoPlay):
                return "load-\(preset.id.uuidString)-\(autoPlay)"
            case .createNewTemplate(let preset):
                return "new-\(preset.id.uuidString)"
            case .importPreset(let preset, _, _):
                return "import-\(preset.id.uuidString)"
            case .closeStudio:
                return "close-studio"
            }
        }

        public var pendingPresetName: String {
            switch self {
            case .loadPreset(let preset, _),
                 .createNewTemplate(let preset),
                 .importPreset(let preset, _, _):
                return preset.name
            case .closeStudio:
                return ""
            }
        }
    }

    public let engine: AudioEngineController
    public let presetStore: PresetStore

    public var presetsRevision: Int = 0
    public var activePlayerSheet: PlayerModalSheet? = nil
    public var isShowingFileImporter: Bool = false
    public var importAlert: ImportAlertContent? = nil
    public private(set) var importPresentationTarget: ImportPresentationTarget = .player
    public var importToastPresetName: String? = nil
    public var studioHasUnsavedChanges: Bool = false
    public private(set) var studioSyncToken: UUID? = nil
    public private(set) var pendingConflict: PendingStudioConflict? = nil
    public private(set) var isTextInputFirstResponder: Bool = false

    @ObservationIgnored private var studioSaveHandler: (() -> Bool)? = nil
    @ObservationIgnored private var studioDiscardHandler: (() -> Void)? = nil
    @ObservationIgnored private var studioCloseHandler: (() -> Void)? = nil
    @ObservationIgnored private var windowOpener: ((String) -> Void)? = nil
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>? = nil
    @ObservationIgnored internal var targetMainMenuForTesting: NSMenu? = nil
    @ObservationIgnored private var didSuppressMenuSpaceShortcut: Bool = false
    @ObservationIgnored private nonisolated(unsafe) let responderObservers = FirstResponderObserverState()

    public init(
        presetStore: PresetStore = PresetStore(storageDirectory: MacAppCoordinator.defaultPresetStorageURL()),
        engine: AudioEngineController = AudioEngineController()
    ) {
        self.presetStore = presetStore
        self.engine = engine
        startMonitoringFirstResponder()
    }

    public convenience init(
        engine: AudioEngineController,
        presetStore: PresetStore
    ) {
        self.init(presetStore: presetStore, engine: engine)
    }

    deinit {
        toastDismissTask?.cancel()
        responderObservers.invalidateAll()
    }

    public static func defaultPresetStorageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("WaveForge", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true)
    }

    // MARK: - Window Navigation & Focus Guard

    /// Registers SwiftUI's `openWindow` action so coordinator flows and menu commands can raise windows cleanly.
    public func registerWindowOpener(_ opener: ((String) -> Void)?) {
        windowOpener = opener
    }

    /// Activates the app and opens or focuses `windowID`.
    public func openWindow(id windowID: String) {
        activateAndOpenWindow(windowID)
    }

    /// Returns `true` when the `Space` shortcut should toggle Play/Pause rather than inserting whitespace in text entry.
    public func shouldHandlePlayPauseSpaceShortcut(
        isTextInputFocused: Bool?,
        isFirstResponderTextEditor: Bool
    ) -> Bool {
        isTextInputFocused != true && !isFirstResponderTextEditor
    }

    /// Returns `true` when AppKit's active key-window first responder is an `NSText` / `NSTextView` field editor
    /// or an editable `NSTextField`.
    public static var isFirstResponderTextEditor: Bool {
        isTextInputFirstResponder(in: (NSApp as NSApplication?)?.keyWindow)
    }

    internal static func isTextInputFirstResponder(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSText {
            return true
        }
        if let textField = responder as? NSTextField, textField.isEditable {
            return true
        }
        return false
    }

    /// Attaches first-responder observation directly to `window` for deterministic testing even in background test hosts.
    internal func observeWindowFirstResponderForTesting(_ window: NSWindow) {
        handleKeyWindowChanged(window)
    }

    /// Recomputes `isTextInputFirstResponder` for `window` and immediately syncs the live `Playback -> Play/Pause`
    /// `NSMenuItem` key equivalent so AppKit `NSMenu.performKeyEquivalent` cannot swallow `Space` during text entry.
    internal func refreshFirstResponderTextInputState(for window: NSWindow?) {
        let isTextInput = Self.isTextInputFirstResponder(in: window)
        if isTextInputFirstResponder != isTextInput {
            isTextInputFirstResponder = isTextInput
        }
        let activeKeyWindow = (NSApp as NSApplication?)?.keyWindow
        if targetMainMenuForTesting != nil || window == nil || window === activeKeyWindow || window?.isKeyWindow == true {
            let targetMenu = targetMainMenuForTesting ?? (NSApp as NSApplication?)?.mainMenu
            syncPlayPauseMenuKeyEquivalent(in: targetMenu, suppressSpace: isTextInput)
        }
    }

    // MARK: - Coordinated Actions & Conflict Guards

    /// Requests loading `preset` (optionally starting playback), guarding unsaved Studio edits first.
    public func requestLoadPreset(_ preset: Preset, autoPlay: Bool = false) {
        if studioHasUnsavedChanges {
            pendingConflict = .loadPreset(preset, autoPlay: autoPlay)
            activateAndOpenWindow(WaveForgeWindowID.studio)
            return
        }

        engine.load(preset)
        if autoPlay {
            engine.play()
        }
        studioSyncToken = UUID()
    }

    /// Requests creating a new template preset and opening Studio Rack, guarding unsaved Studio edits first.
    public func requestCreateNewPreset() {
        let template = LibraryView.makeTemplatePreset()
        if studioHasUnsavedChanges {
            pendingConflict = .createNewTemplate(template)
            activateAndOpenWindow(WaveForgeWindowID.studio)
            return
        }

        engine.load(template)
        studioSyncToken = UUID()
        activateAndOpenWindow(WaveForgeWindowID.studio)
    }

    /// Brings the Player window forward and presents the macOS `.fileImporter` panel (`⌘O`).
    public func requestOpenImportPanel() {
        importPresentationTarget = .player
        activateAndOpenWindow(WaveForgeWindowID.player)
        isShowingFileImporter = true
    }

    /// Brings the Player window forward and presents `ExportSheetView` (`⌘E`).
    public func requestShowExport() {
        activateAndOpenWindow(WaveForgeWindowID.player)
        activePlayerSheet = .export
    }

    /// Brings the Player window forward and presents `AboutSheetView` (`About WaveForge`).
    public func requestShowAbout() {
        activateAndOpenWindow(WaveForgeWindowID.player)
        activePlayerSheet = .about
    }

    /// Registers Studio's live save handler for Save-and-Proceed conflict resolution.
    public func registerStudioSaveHandler(_ handler: (() -> Bool)?) {
        studioSaveHandler = handler
    }

    /// Registers Studio's live discard handler for reverting unsaved edits before closing the Studio window.
    public func registerStudioDiscardHandler(_ handler: (() -> Void)?) {
        studioDiscardHandler = handler
    }

    /// Registers the macOS Studio window close handler used after resolving a `.closeStudio` conflict.
    public func registerStudioCloseHandler(_ handler: (() -> Void)?) {
        studioCloseHandler = handler
    }

    /// Intercepts macOS Studio window close when unsaved edits exist, presenting the Save/Discard dialog.
    public func requestCloseStudioWindow() {
        if studioHasUnsavedChanges {
            pendingConflict = .closeStudio
            activateAndOpenWindow(WaveForgeWindowID.studio)
            return
        }
        studioCloseHandler?()
    }

    /// Validates, imports, and saves `.bwg` / `.waveforge` URLs from Finder (`onOpenURL`), `⌘O`, or drag-and-drop.
    /// File I/O and parsing run off the main actor; the returned task completes once UI state is updated.
    @discardableResult
    public func handleIncomingURLs(_ urls: [URL]) -> Task<Void, Never> {
        handleIncomingURLs(urls, source: .external)
    }

    /// Validates, imports, and saves `.bwg` / `.waveforge` URLs with an explicit source window for modal routing.
    @discardableResult
    public func handleIncomingURLs(_ urls: [URL], source: ImportSource) -> Task<Void, Never> {
        guard !urls.isEmpty else { return Task {} }
        let store = presetStore
        return Task { @MainActor [weak self] in
            let results = await PresetImportCoordinator.importFiles(at: urls, into: store)
            self?.applyImportResults(results, urls: urls, source: source)
        }
    }

    private func applyImportResults(
        _ results: [Result<PresetImportOutcome, PresetImportError>],
        urls: [URL],
        source: ImportSource
    ) {
        var outcomes: [PresetImportOutcome] = []
        var failures: [(url: URL, error: any Error)] = []

        for (url, result) in zip(urls, results) {
            switch result {
            case .success(let outcome):
                outcomes.append(outcome)
            case .failure(let error):
                failures.append((url, error))
            }
        }

        let target = source.presentationTarget

        // Invalid / corrupted / unsupported imports must never mutate engine state, stop playback, or raise conflicts.
        guard let lastOutcome = outcomes.last else {
            importPresentationTarget = target
            dismissImportToast()
            importAlert = buildFailureAlert(from: failures)
            if source == .external {
                activateAndOpenWindow(WaveForgeWindowID.player)
            }
            return
        }

        presetsRevision += 1
        let alertContent = buildOutcomeAlert(outcomes: outcomes, failures: failures)

        if studioHasUnsavedChanges {
            importPresentationTarget = target
            if let alertContent {
                dismissImportToast()
                importAlert = alertContent
            }
            pendingConflict = .importPreset(
                lastOutcome.preset,
                toastPresetName: alertContent == nil ? lastOutcome.preset.name : nil,
                target: target
            )
            activateAndOpenWindow(WaveForgeWindowID.studio)
            return
        }

        engine.load(lastOutcome.preset)
        studioSyncToken = UUID()
        importPresentationTarget = target

        if let alertContent {
            dismissImportToast()
            importAlert = alertContent
        } else {
            importAlert = nil
            showImportToast(for: lastOutcome.preset.name)
        }

        if source == .external {
            activateAndOpenWindow(WaveForgeWindowID.player)
        }
    }

    /// Handles SwiftUI `.fileImporter` completion cleanly.
    public func handleFileImporterResult(_ result: Result<[URL], any Error>, source: ImportSource = .player) {
        switch result {
        case .success(let urls):
            _ = handleIncomingURLs(urls, source: source)

        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            importPresentationTarget = source.presentationTarget
            dismissImportToast()
            importAlert = ImportAlertContent.fromError(error)
        }
    }

    /// Saves unsaved Studio edits via the registered save handler, then proceeds with the deferred switch.
    public func resolveConflictSaveThenProceed() {
        guard let conflict = pendingConflict else { return }
        if let studioSaveHandler {
            guard studioSaveHandler() else {
                pendingConflict = nil
                return
            }
        }
        pendingConflict = nil
        studioHasUnsavedChanges = false
        applyPendingConflict(conflict)
    }

    /// Discards unsaved Studio edits, loads the deferred preset (or closes Studio), and triggers Studio sync.
    public func resolveConflictDiscardAndProceed() {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        if case .closeStudio = conflict {
            studioDiscardHandler?()
        }
        studioHasUnsavedChanges = false
        applyPendingConflict(conflict)
    }

    /// Cancels the pending switch so the user can continue editing in Studio.
    public func resolveConflictCancel() {
        pendingConflict = nil
    }

    /// Dismisses any visible import confirmation toast.
    public func dismissImportToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        importToastPresetName = nil
    }

    // MARK: - Internal Helpers

    private func applyPendingConflict(_ conflict: PendingStudioConflict) {
        switch conflict {
        case .loadPreset(let preset, let autoPlay):
            engine.load(preset)
            if autoPlay {
                engine.play()
            }
            studioSyncToken = UUID()

        case .createNewTemplate(let template):
            engine.load(template)
            studioSyncToken = UUID()
            activateAndOpenWindow(WaveForgeWindowID.studio)

        case .importPreset(let preset, let toastPresetName, let target):
            engine.load(preset)
            studioSyncToken = UUID()
            if let toastPresetName {
                importPresentationTarget = target
                importAlert = nil
                showImportToast(for: toastPresetName)
            }

        case .closeStudio:
            studioCloseHandler?()
        }

        if importAlert != nil && importPresentationTarget == .player {
            activateAndOpenWindow(WaveForgeWindowID.player)
        }
    }

    private func activateAndOpenWindow(_ windowID: String) {
        guard let windowOpener else { return }
        NSApp.activate()
        windowOpener(windowID)
    }

    private func showImportToast(for presetName: String) {
        toastDismissTask?.cancel()
        importToastPresetName = presetName
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard let self, !Task.isCancelled else { return }
            self.importToastPresetName = nil
            self.toastDismissTask = nil
        }
    }

    private func buildFailureAlert(from failures: [(url: URL, error: any Error)]) -> ImportAlertContent {
        if failures.count == 1 {
            return ImportAlertContent.fromError(failures[0].error)
        }
        let lines = failures.map { failure in
            "• \(failure.url.lastPathComponent): \(PresetImportCoordinator.localizedMessage(for: failure.error))"
        }
        return ImportAlertContent(kind: .failure(message: lines.joined(separator: "\n")))
    }

    private func buildOutcomeAlert(
        outcomes: [PresetImportOutcome],
        failures: [(url: URL, error: any Error)]
    ) -> ImportAlertContent? {
        if !failures.isEmpty {
            let lines = failures.map { failure in
                "• \(failure.url.lastPathComponent): \(PresetImportCoordinator.localizedMessage(for: failure.error))"
            }
            return ImportAlertContent(kind: .failure(message: lines.joined(separator: "\n")))
        }

        guard let lastOutcome = outcomes.last else { return nil }
        if outcomes.count == 1 {
            return ImportAlertContent.fromOutcome(lastOutcome)
        }

        var mergedSkipped: [SkippedLegacyFeature] = []
        var mergedWarnings: [String] = []
        var mergedStructured: [ImportWarning] = []

        for outcome in outcomes {
            for feature in outcome.report.skippedFeatures where !mergedSkipped.contains(feature) {
                mergedSkipped.append(feature)
            }
            mergedWarnings.append(contentsOf: outcome.report.warnings)
            mergedStructured.append(contentsOf: outcome.report.structuredWarnings)
        }

        let mergedOutcome = PresetImportOutcome(
            preset: lastOutcome.preset,
            report: ImportReport(
                skippedFeatures: mergedSkipped,
                warnings: mergedWarnings,
                structuredWarnings: mergedStructured
            )
        )
        return ImportAlertContent.fromOutcome(mergedOutcome)
    }

    // MARK: - AppKit First-Responder & Menu Space-Shortcut Monitoring

    private func startMonitoringFirstResponder() {
        ensureKeyWindowObserverAttached()

        let bridge = ResponderNotificationBridge(coordinator: self)
        responderObservers.notificationBridge = bridge

        let center = NotificationCenter.default
        center.addObserver(
            bridge,
            selector: #selector(ResponderNotificationBridge.handleApplicationDidFinishLaunching(_:)),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil
        )
        center.addObserver(
            bridge,
            selector: #selector(ResponderNotificationBridge.handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            bridge,
            selector: #selector(ResponderNotificationBridge.handleWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        center.addObserver(
            bridge,
            selector: #selector(ResponderNotificationBridge.handleWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        center.addObserver(
            bridge,
            selector: #selector(ResponderNotificationBridge.handleTextDidBeginEditing(_:)),
            name: NSText.didBeginEditingNotification,
            object: nil
        )
        center.addObserver(
            bridge,
            selector: #selector(ResponderNotificationBridge.handleTextDidEndEditing(_:)),
            name: NSText.didEndEditingNotification,
            object: nil
        )

        refreshFirstResponderTextInputState(for: (NSApp as NSApplication?)?.keyWindow)
    }

    private func ensureKeyWindowObserverAttached() {
        guard responderObservers.keyWindowObservation == nil,
              let app = NSApp as NSApplication? else {
            return
        }

        responderObservers.keyWindowObservation = app.observe(\.keyWindow, options: [.initial, .new]) { [weak self] _, _ in
            Self.runOnMainActor(self) { coordinator in
                coordinator.handleKeyWindowChanged((NSApp as NSApplication?)?.keyWindow)
            }
        }
    }

    private func handleKeyWindowChanged(_ window: NSWindow?) {
        if responderObservers.observedKeyWindow !== window {
            responderObservers.firstResponderObservation?.invalidate()
            responderObservers.firstResponderObservation = nil
            responderObservers.observedKeyWindow = window

            if let window {
                responderObservers.firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] observedWindow, _ in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            let activeKeyWindow = (NSApp as NSApplication?)?.keyWindow
                            if self.targetMainMenuForTesting != nil
                                || activeKeyWindow == nil
                                || activeKeyWindow === observedWindow
                                || observedWindow.isKeyWindow {
                                self.refreshFirstResponderTextInputState(for: observedWindow)
                            }
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let fallbackWindow = self.responderObservers.observedKeyWindow
                                ?? (NSApp as NSApplication?)?.keyWindow
                            self.refreshFirstResponderTextInputState(for: fallbackWindow)
                        }
                    }
                }
            }
        }
        refreshFirstResponderTextInputState(for: window)
    }

    private func handleWindowWillClose(_ closingWindow: NSWindow?) {
        if let closingWindow, responderObservers.observedKeyWindow === closingWindow {
            responderObservers.firstResponderObservation?.invalidate()
            responderObservers.firstResponderObservation = nil
            responderObservers.observedKeyWindow = nil
            let remainingKey = (NSApp as NSApplication?)?.keyWindow
            handleKeyWindowChanged(remainingKey === closingWindow ? nil : remainingKey)
        } else if responderObservers.observedKeyWindow == nil {
            refreshFirstResponderTextInputState(for: (NSApp as NSApplication?)?.keyWindow)
        }
    }

    private func syncPlayPauseMenuKeyEquivalent(in targetMenu: NSMenu?, suppressSpace: Bool) {
        guard let menuItem = findPlayPauseMenuItem(in: targetMenu) else {
            return
        }
        if suppressSpace {
            if menuItem.keyEquivalent == " " && menuItem.keyEquivalentModifierMask.isEmpty {
                menuItem.keyEquivalent = ""
                menuItem.keyEquivalentModifierMask = []
                didSuppressMenuSpaceShortcut = true
            }
        } else if didSuppressMenuSpaceShortcut {
            if menuItem.keyEquivalent.isEmpty {
                menuItem.keyEquivalent = " "
                menuItem.keyEquivalentModifierMask = []
            }
            didSuppressMenuSpaceShortcut = false
        }
    }

    private func findPlayPauseMenuItem(in mainMenu: NSMenu?) -> NSMenuItem? {
        guard let mainMenu else { return nil }

        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            if let spaceItem = submenu.items.first(where: {
                $0.keyEquivalent == " " && $0.keyEquivalentModifierMask.isEmpty
            }) {
                return spaceItem
            }
        }

        let playbackTitles: Set<String> = ["Playback", String(localized: "Playback")]
        let playPauseTitles: Set<String> = [
            "Play",
            "Pause",
            String(localized: "Play"),
            String(localized: "Pause")
        ]
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            if playbackTitles.contains(topItem.title) || playbackTitles.contains(submenu.title) {
                if let item = submenu.items.first(where: { playPauseTitles.contains($0.title) }) {
                    return item
                }
            }
        }

        return nil
    }

    private nonisolated static func runOnMainActor(
        _ target: MacAppCoordinator?,
        _ operation: @MainActor @escaping (MacAppCoordinator) -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard let target else { return }
                operation(target)
            }
        } else {
            Task { @MainActor [weak target] in
                guard let target else { return }
                operation(target)
            }
        }
    }

    @MainActor
    private final class ResponderNotificationBridge: NSObject {
        private weak var coordinator: MacAppCoordinator?

        init(coordinator: MacAppCoordinator) {
            self.coordinator = coordinator
        }

        @objc func handleApplicationDidFinishLaunching(_ notification: Notification) {
            guard let coordinator else { return }
            coordinator.ensureKeyWindowObserverAttached()
            coordinator.handleKeyWindowChanged((NSApp as NSApplication?)?.keyWindow)
        }

        @objc func handleWindowDidBecomeKey(_ notification: Notification) {
            guard let coordinator else { return }
            coordinator.ensureKeyWindowObserverAttached()
            let window = (notification.object as? NSWindow) ?? (NSApp as NSApplication?)?.keyWindow
            coordinator.handleKeyWindowChanged(window)
        }

        @objc func handleWindowDidResignKey(_ notification: Notification) {
            guard let coordinator else { return }
            let resigning = notification.object as? NSWindow
            if coordinator.targetMainMenuForTesting != nil,
               let observed = coordinator.responderObservers.observedKeyWindow,
               resigning !== observed {
                return
            }
            let currentKey = (NSApp as NSApplication?)?.keyWindow
            if let resigning, currentKey === resigning {
                coordinator.handleKeyWindowChanged(nil)
            } else {
                coordinator.handleKeyWindowChanged(currentKey)
            }
        }

        @objc func handleWindowWillClose(_ notification: Notification) {
            guard let coordinator else { return }
            coordinator.handleWindowWillClose(notification.object as? NSWindow)
        }

        @objc func handleTextDidBeginEditing(_ notification: Notification) {
            guard let coordinator else { return }
            let textWindow = (notification.object as? NSText)?.window
            let keyWindow = (NSApp as NSApplication?)?.keyWindow
            let isObservedTestWindow = coordinator.targetMainMenuForTesting != nil
                && textWindow === coordinator.responderObservers.observedKeyWindow
            if let textWindow, textWindow === keyWindow || textWindow.isKeyWindow || isObservedTestWindow {
                coordinator.handleKeyWindowChanged(textWindow)
            } else if coordinator.targetMainMenuForTesting != nil {
                coordinator.refreshFirstResponderTextInputState(for: coordinator.responderObservers.observedKeyWindow)
            } else {
                coordinator.refreshFirstResponderTextInputState(for: keyWindow)
            }
        }

        @objc func handleTextDidEndEditing(_ notification: Notification) {
            guard let coordinator else { return }
            let textWindow = (notification.object as? NSText)?.window
            let targetWindow: NSWindow? = if coordinator.targetMainMenuForTesting != nil,
                                             let observed = coordinator.responderObservers.observedKeyWindow,
                                             textWindow == nil || textWindow === observed {
                observed
            } else {
                (NSApp as NSApplication?)?.keyWindow
            }
            coordinator.refreshFirstResponderTextInputState(for: targetWindow)
        }
    }

    private final class FirstResponderObserverState {
        var keyWindowObservation: NSKeyValueObservation?
        var firstResponderObservation: NSKeyValueObservation?
        var notificationBridge: ResponderNotificationBridge?
        weak var observedKeyWindow: NSWindow?

        func invalidateAll() {
            keyWindowObservation?.invalidate()
            keyWindowObservation = nil
            firstResponderObservation?.invalidate()
            firstResponderObservation = nil
            observedKeyWindow = nil
            if let notificationBridge {
                NotificationCenter.default.removeObserver(notificationBridge)
                self.notificationBridge = nil
            }
        }
    }
}

// MARK: - Drag-and-Drop URL Resolution & Overlay

/// Thread-safe `.fileURL` drop resolver converting `[NSItemProvider]` items into `[URL]` on `@MainActor`.
@MainActor
internal enum MacDropHandler {
    private final class URLCollector: Sendable {
        private struct State {
            var remaining: Int
            var urls: [URL?]
        }

        private let state: Mutex<State>
        private let onComplete: @MainActor @Sendable ([URL]) -> Void

        init(count: Int, onComplete: @escaping @MainActor @Sendable ([URL]) -> Void) {
            self.state = Mutex(State(remaining: count, urls: Array(repeating: nil, count: count)))
            self.onComplete = onComplete
        }

        func record(_ url: URL?, at index: Int) {
            let completedURLs: [URL]? = state.withLock { current in
                if current.urls.indices.contains(index) {
                    current.urls[index] = url
                }
                current.remaining -= 1
                guard current.remaining <= 0 else { return nil }
                return current.urls.compactMap { $0 }
            }

            if let completedURLs, !completedURLs.isEmpty {
                let callback = onComplete
                Task { @MainActor in
                    callback(completedURLs)
                }
            }
        }
    }

    static func handleDrop(
        providers: [NSItemProvider],
        onURLs: @escaping @MainActor @Sendable ([URL]) -> Void
    ) -> Bool {
        let fileTypeIdentifier = UTType.fileURL.identifier
        let matchingProviders = providers.filter {
            $0.canLoadObject(ofClass: URL.self)
                || $0.hasItemConformingToTypeIdentifier(fileTypeIdentifier)
        }
        guard !matchingProviders.isEmpty else { return false }

        let collector = URLCollector(count: matchingProviders.count, onComplete: onURLs)
        for (index, provider) in matchingProviders.enumerated() {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    collector.record(url, at: index)
                }
            } else {
                _ = provider.loadDataRepresentation(forTypeIdentifier: fileTypeIdentifier) { data, _ in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    collector.record(url, at: index)
                }
            }
        }
        return true
    }
}

/// Liquid Glass drag-and-drop highlight overlay displayed over Player and Library windows.
internal struct MacPresetDropOverlay: View {
    let accentColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.chassisGraphite.opacity(0.72))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))

            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text("Drop .bwg or .waveforge to Import")
                    .font(.headline)
                    .foregroundStyle(StudioTheme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .studioGlassSurface(cornerRadius: 18, tint: accentColor.opacity(0.22), interactive: false)
        }
        .padding(12)
        .allowsHitTesting(false)
    }
}
