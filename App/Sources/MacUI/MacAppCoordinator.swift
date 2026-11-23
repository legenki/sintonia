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

    /// Deferred preset switch waiting on the user to Save, Discard, or Keep Editing unsaved Studio changes.
    public enum PendingStudioConflict: Identifiable, Equatable, Sendable {
        case loadPreset(Preset, autoPlay: Bool)
        case createNewTemplate(Preset)
        case importPreset(Preset, toastPresetName: String?, target: ImportPresentationTarget)

        public var id: String {
            switch self {
            case .loadPreset(let preset, let autoPlay):
                return "load-\(preset.id.uuidString)-\(autoPlay)"
            case .createNewTemplate(let preset):
                return "new-\(preset.id.uuidString)"
            case .importPreset(let preset, _, _):
                return "import-\(preset.id.uuidString)"
            }
        }

        public var pendingPresetName: String {
            switch self {
            case .loadPreset(let preset, _),
                 .createNewTemplate(let preset),
                 .importPreset(let preset, _, _):
                return preset.name
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

    @ObservationIgnored private var studioSaveHandler: (() -> Bool)? = nil
    @ObservationIgnored private var windowOpener: ((String) -> Void)? = nil
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>? = nil

    public init(
        presetStore: PresetStore = PresetStore(storageDirectory: MacAppCoordinator.defaultPresetStorageURL()),
        engine: AudioEngineController = AudioEngineController()
    ) {
        self.presetStore = presetStore
        self.engine = engine
    }

    public convenience init(
        engine: AudioEngineController,
        presetStore: PresetStore
    ) {
        self.init(presetStore: presetStore, engine: engine)
    }

    deinit {
        toastDismissTask?.cancel()
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

    /// Returns `true` when AppKit's active key-window first responder is an `NSText` / `NSTextView` field editor.
    public static var isFirstResponderTextEditor: Bool {
        (NSApp as NSApplication?)?.keyWindow?.firstResponder is NSText
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

    /// Validates, imports, and saves `.bwg` / `.waveforge` URLs from Finder (`onOpenURL`), `⌘O`, or drag-and-drop.
    public func handleIncomingURLs(_ urls: [URL]) {
        handleIncomingURLs(urls, source: .external)
    }

    /// Validates, imports, and saves `.bwg` / `.waveforge` URLs with an explicit source window for modal routing.
    public func handleIncomingURLs(_ urls: [URL], source: ImportSource) {
        guard !urls.isEmpty else { return }

        var outcomes: [PresetImportOutcome] = []
        var failures: [(url: URL, error: any Error)] = []

        for url in urls {
            do {
                let outcome = try PresetImportCoordinator.importFile(at: url, into: presetStore)
                outcomes.append(outcome)
            } catch {
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
            handleIncomingURLs(urls, source: source)

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

    /// Discards unsaved Studio edits, loads the deferred preset, and triggers Studio sync.
    public func resolveConflictDiscardAndProceed() {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
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
