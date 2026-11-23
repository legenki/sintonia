import AppKit
import Foundation
import PresetKit
import SwiftUI
import SynthCore
import Testing
import WaveForgeExport
@testable import WaveForgeMac

@Suite("WaveForgeMac Runtime & Review Focus Tests", .serialized)
struct MacRuntimeTests {
    @Test func appBundleContainsPrivacyManifestWithRequiredDiskSpaceReason() throws {
        let hostBundle = try #require(Bundle(identifier: "com.waveforge.mac"))
        let privacyURL = try #require(
            hostBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: privacyURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect((plist["NSPrivacyTracking"] as? Bool) == false)

        let accessedTypes = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = accessedTypes.flatMap { entry in
            entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        #expect(reasons.contains("E174.1"))
        #expect(reasons.contains("CA92.1"))
    }

    @MainActor
    @Test func audioEngineControllerInitializesCleanlyOnMacOS() async {
        let controller = AudioEngineController()
        let firstPreset = PresetCatalog.builtInPresets[0]

        #expect(!controller.isPlaying)
        #expect(controller.currentPreset.id == firstPreset.id)
        #expect(controller.duration == firstPreset.durationSec)
        #expect(controller.currentTime == 0.0)
        _ = controller.selectedOutputDeviceUID
        _ = controller.availableOutputDevices
    }

    @MainActor
    @Test func liveAudioEnginePlaysAndPausesOnRealAudioThreadWithoutActorCrash() async throws {
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let controller = AudioEngineController(
            preset: PresetCatalog.builtInPresets[0],
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        defer {
            controller.pause()
        }

        controller.play()
        try await Task.sleep(for: .milliseconds(150))

        if controller.lastErrorMessage == nil {
            #expect(controller.isPlaying)
            #expect(controller.currentTime > 0.0)

            var frame = TelemetryFrame()
            controller.telemetryBuffer.readLatest(into: &frame)
            let leftAllFinite = frame.leftSamples.allSatisfy(\.isFinite)
            let rightAllFinite = frame.rightSamples.allSatisfy(\.isFinite)
            #expect(!frame.leftSamples.isEmpty)
            #expect(!frame.rightSamples.isEmpty)
            #expect(leftAllFinite)
            #expect(rightAllFinite)

            controller.pause()
            try await Task.sleep(for: .milliseconds(80))
            #expect(!controller.isPlaying)
        }
    }

    @MainActor
    @Test func reviewFocus1_headphoneDisconnectDuringBinauralAutoPausesAndResetsSelection() throws {
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let deepFocus = PresetCatalog.builtInPresets[0]
        let controller = AudioEngineController(
            preset: deepFocus,
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        #expect(controller.presetHasActiveBinaural)

        let speaker = AudioOutputDevice(
            uid: "builtin-speaker",
            name: "MacBook Speakers",
            route: .speaker,
            isSystemDefault: true
        )
        let airpods = AudioOutputDevice(
            uid: "airpods",
            name: "AirPods Pro",
            route: .headphones,
            isSystemDefault: false
        )

        controller.applyMacDeviceSnapshotForTesting(
            devices: [speaker, airpods],
            defaultUID: speaker.uid
        )
        controller.selectOutputDevice(uid: "airpods")
        #expect(controller.selectedOutputDeviceUID == "airpods")
        #expect(controller.outputRoute == .headphones)
        #expect(!controller.showHeadphoneBanner)

        controller.setIsPlayingForTesting(true)
        #expect(controller.isPlaying)

        controller.applyMacDeviceSnapshotForTesting(
            devices: [speaker],
            defaultUID: speaker.uid
        )

        #expect(!controller.isPlaying)
        #expect(controller.showHeadphoneBanner)
        #expect(controller.selectedOutputDeviceUID == nil)
        #expect(controller.outputRoute == .speaker)
    }

    @MainActor
    @Test func reviewFocus2_unsavedStudioDraftGuardsPresetLoadAndOpenURL() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let initialPreset = PresetCatalog.builtInPresets[0]
        let otherPreset = PresetCatalog.builtInPresets[1]
        let thirdPreset = PresetCatalog.builtInPresets[2]
        let engine = AudioEngineController(
            preset: initialPreset,
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)

        coordinator.studioHasUnsavedChanges = true
        coordinator.requestLoadPreset(otherPreset, autoPlay: false)

        #expect(coordinator.engine.currentPreset.id == initialPreset.id)
        #expect(coordinator.pendingConflict == .loadPreset(otherPreset, autoPlay: false))

        coordinator.resolveConflictDiscardAndProceed()
        #expect(coordinator.pendingConflict == nil)
        #expect(!coordinator.studioHasUnsavedChanges)
        #expect(coordinator.engine.currentPreset.id == otherPreset.id)
        #expect(coordinator.studioSyncToken != nil)

        let validBWGURL = tempDir.appendingPathComponent("GuardImport.bwg")
        let validBWG = """
        BrainWave Generator File
        Name=Guard Import Test
        Duration=120
        Voice1.Carrier=0:200
        Voice1.Beat=0:10
        """
        try validBWG.write(to: validBWGURL, atomically: true, encoding: .utf8)

        let previousSyncToken = coordinator.studioSyncToken
        coordinator.studioHasUnsavedChanges = true
        coordinator.handleIncomingURLs([validBWGURL])

        #expect(coordinator.engine.currentPreset.id == otherPreset.id)
        #expect(coordinator.pendingConflict != nil)

        coordinator.resolveConflictDiscardAndProceed()
        #expect(coordinator.pendingConflict == nil)
        #expect(!coordinator.studioHasUnsavedChanges)
        #expect(coordinator.engine.currentPreset.name == "Guard Import Test")
        #expect(coordinator.studioSyncToken != previousSyncToken)
        #expect(store.allPresets().contains { !$0.isBuiltIn && $0.name == "Guard Import Test" })

        var saveHandlerInvoked = false
        coordinator.registerStudioSaveHandler {
            saveHandlerInvoked = true
            return true
        }
        coordinator.studioHasUnsavedChanges = true
        coordinator.requestLoadPreset(thirdPreset, autoPlay: false)
        #expect(coordinator.pendingConflict == .loadPreset(thirdPreset, autoPlay: false))

        coordinator.resolveConflictSaveThenProceed()
        #expect(saveHandlerInvoked)
        #expect(coordinator.pendingConflict == nil)
        #expect(!coordinator.studioHasUnsavedChanges)
        #expect(coordinator.engine.currentPreset.id == thirdPreset.id)
    }

    @MainActor
    @Test func studioWindowCloseConflictGuardsUnsavedEditsAndRejectsOversizedImport() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let engine = AudioEngineController(
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)

        var closeCount = 0
        var discardCount = 0
        var saveCount = 0
        coordinator.registerStudioCloseHandler { closeCount += 1 }
        coordinator.registerStudioDiscardHandler { discardCount += 1 }
        coordinator.registerStudioSaveHandler {
            saveCount += 1
            return true
        }

        coordinator.studioHasUnsavedChanges = true
        coordinator.requestCloseStudioWindow()
        #expect(coordinator.pendingConflict == .closeStudio)
        #expect(closeCount == 0)

        coordinator.resolveConflictDiscardAndProceed()
        #expect(discardCount == 1)
        #expect(closeCount == 1)
        #expect(coordinator.pendingConflict == nil)
        #expect(!coordinator.studioHasUnsavedChanges)

        coordinator.studioHasUnsavedChanges = true
        coordinator.requestCloseStudioWindow()
        #expect(coordinator.pendingConflict == .closeStudio)
        coordinator.resolveConflictSaveThenProceed()
        #expect(saveCount == 1)
        #expect(closeCount == 2)
        #expect(coordinator.pendingConflict == nil)

        // Verify oversized preset file is rejected before loading into memory.
        let oversizedURL = tempDir.appendingPathComponent("huge.bwg")
        try Data(repeating: 0x41, count: PresetLimits.maxImportFileBytes + 1).write(to: oversizedURL)
        #expect(throws: PresetImportError.fileTooLarge) {
            _ = try PresetImportCoordinator.importFile(at: oversizedURL, into: store)
        }
    }

    @MainActor
    @Test func finding1_deletingActiveCustomPresetViaLibraryCoordinatedPathRespectsCleanAndDirtyStudioStates() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let engine = AudioEngineController(
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)
        let deepFocus = PresetCatalog.builtInPresets[0]

        var customActive = LibraryView.makeTemplatePreset()
        customActive.id = UUID()
        customActive.name = "Custom Active Clean"
        try store.saveCustom(customActive)

        var customInactive = LibraryView.makeTemplatePreset()
        customInactive.id = UUID()
        customInactive.name = "Custom Inactive"
        try store.saveCustom(customInactive)

        coordinator.requestLoadPreset(customActive, autoPlay: false)
        let tokenBeforeDelete = try #require(coordinator.studioSyncToken)
        #expect(coordinator.engine.currentPreset.id == customActive.id)

        // Deleting a non-active custom preset leaves the active preset and sync token untouched.
        try LibraryView.performCustomPresetDeletion(
            customInactive,
            presetStore: store,
            engine: engine,
            loadsDirectlyOnSelect: false
        ) { preset in
            coordinator.requestLoadPreset(preset, autoPlay: false)
        }
        #expect(!store.allPresets().contains { $0.id == customInactive.id })
        #expect(coordinator.engine.currentPreset.id == customActive.id)
        #expect(coordinator.studioSyncToken == tokenBeforeDelete)
        #expect(coordinator.pendingConflict == nil)

        // Deleting the active custom preset when Studio is clean falls back to Deep Focus via coordinator and bumps studioSyncToken.
        try LibraryView.performCustomPresetDeletion(
            customActive,
            presetStore: store,
            engine: engine,
            loadsDirectlyOnSelect: false
        ) { preset in
            coordinator.requestLoadPreset(preset, autoPlay: false)
        }
        #expect(!store.allPresets().contains { $0.id == customActive.id })
        #expect(coordinator.engine.currentPreset.id == deepFocus.id)
        #expect(coordinator.studioSyncToken != tokenBeforeDelete)
        #expect(coordinator.pendingConflict == nil)

        // Deleting the active custom preset when Studio has unsaved edits raises pendingConflict instead of silently overwriting.
        var customDirty = LibraryView.makeTemplatePreset()
        customDirty.id = UUID()
        customDirty.name = "Custom Active Dirty"
        try store.saveCustom(customDirty)

        coordinator.requestLoadPreset(customDirty, autoPlay: false)
        let tokenDuringDirty = try #require(coordinator.studioSyncToken)
        coordinator.studioHasUnsavedChanges = true

        try LibraryView.performCustomPresetDeletion(
            customDirty,
            presetStore: store,
            engine: engine,
            loadsDirectlyOnSelect: false
        ) { preset in
            coordinator.requestLoadPreset(preset, autoPlay: false)
        }
        #expect(!store.allPresets().contains { $0.id == customDirty.id })
        #expect(coordinator.engine.currentPreset.id == customDirty.id)
        #expect(coordinator.pendingConflict == .loadPreset(deepFocus, autoPlay: false))

        coordinator.resolveConflictDiscardAndProceed()
        #expect(coordinator.pendingConflict == nil)
        #expect(!coordinator.studioHasUnsavedChanges)
        #expect(coordinator.engine.currentPreset.id == deepFocus.id)
        #expect(coordinator.studioSyncToken != tokenDuringDirty)

        // Direct mode (iOS path) loads Deep Focus directly without invoking onSelectPreset.
        var customDirect = LibraryView.makeTemplatePreset()
        customDirect.id = UUID()
        customDirect.name = "Custom Direct"
        try store.saveCustom(customDirect)
        engine.load(customDirect)

        try LibraryView.performCustomPresetDeletion(
            customDirect,
            presetStore: store,
            engine: engine,
            loadsDirectlyOnSelect: true
        ) { _ in
            Issue.record("onSelectPreset must not be called when loadsDirectlyOnSelect is true")
        }
        #expect(engine.currentPreset.id == deepFocus.id)
    }

    @MainActor
    @Test func reviewFocus3_spaceShortcutBlockedWhileTextInputFocused() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let engine = AudioEngineController(
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)

        #expect(!coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: true,
            isFirstResponderTextEditor: false
        ))
        #expect(!coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: false,
            isFirstResponderTextEditor: true
        ))
        #expect(!coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: nil,
            isFirstResponderTextEditor: true
        ))
        #expect(coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: false,
            isFirstResponderTextEditor: false
        ))
        #expect(coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: nil,
            isFirstResponderTextEditor: false
        ))
    }

    @MainActor
    @Test func liveMacToolbarSearchFieldAllowsSpaceInsertionAndDoesNotSwallowViaMainMenu() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let engine = AudioEngineController(
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)

        let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let toolbarDelegate = TestSearchToolbarDelegate(searchField: searchField)
        let toolbar = NSToolbar(identifier: "TestLibraryToolbar-\(UUID().uuidString)")
        toolbar.delegate = toolbarDelegate

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbar = toolbar
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView = contentView
        defer {
            window.makeFirstResponder(nil)
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        activateKeyWindow(window)
        try verifyToolbarSearchFieldSpaceBehavior(
            in: window,
            searchField: searchField,
            coordinator: coordinator
        )
    }

    @MainActor
    @Test func hostedLibraryViewToolbarSearchFieldAllowsSpaceInsertion() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let engine = AudioEngineController(
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)

        let libraryView = LibraryView(
            engine: engine,
            presetStore: store,
            presetsRevision: coordinator.presetsRevision,
            adaptiveDesktopGrid: true,
            hidesDoneButton: true,
            loadsDirectlyOnSelect: false,
            onPresetsChanged: { coordinator.presetsRevision += 1 },
            onSelectPreset: { preset in coordinator.requestLoadPreset(preset, autoPlay: false) }
        )

        let hostingController = NSHostingController(rootView: libraryView)
        hostingController.preferredContentSize = NSSize(width: 780, height: 640)
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 780, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        defer {
            window.makeFirstResponder(nil)
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        activateKeyWindow(window)
        window.layoutIfNeeded()
        var foundSearchField = findSearchField(in: window)
        for _ in 0..<12 where foundSearchField == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            window.layoutIfNeeded()
            foundSearchField = findSearchField(in: window)
        }

        let searchField = try #require(foundSearchField)
        try verifyToolbarSearchFieldSpaceBehavior(
            in: window,
            searchField: searchField,
            coordinator: coordinator
        )
    }

    @MainActor
    @Test func reviewFocus4_invalidAndMultiFileDropSurfacesImportAlertWithoutDisruptingPlayback() throws {
        let (tempDir, cleanupDir) = try makeTempDirectory()
        defer { cleanupDir() }
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let store = PresetStore(storageDirectory: tempDir.appendingPathComponent("Presets", isDirectory: true))
        let engine = AudioEngineController(
            deviceUserDefaults: defaults,
            startHardwareMonitoring: false
        )
        let coordinator = MacAppCoordinator(presetStore: store, engine: engine)

        let invalidTxtURL = tempDir.appendingPathComponent("notes.txt")
        try "not a valid waveforge preset".write(to: invalidTxtURL, atomically: true, encoding: .utf8)

        let truncatedBWGURL = tempDir.appendingPathComponent("broken.bwg")
        try "BrainWave Generator File\n".write(to: truncatedBWGURL, atomically: true, encoding: .utf8)

        let initialPresetID = coordinator.engine.currentPreset.id
        coordinator.engine.setIsPlayingForTesting(true)
        coordinator.handleIncomingURLs([invalidTxtURL, truncatedBWGURL])

        #expect(coordinator.importAlert != nil)
        #expect(coordinator.engine.currentPreset.id == initialPresetID)
        #expect(coordinator.engine.isPlaying)
        #expect(store.allPresets().filter { !$0.isBuiltIn }.isEmpty)

        let legacyBWGURL = tempDir.appendingPathComponent("LegacyRainStrobe.bwg")
        let legacyBWG = """
        BrainWave Generator File
        Name=Legacy Rain Strobe
        Duration=600
        BackgroundWav=rain_forest.wav
        VisualStimulation=1
        Voice1.Carrier=0:200
        Voice1.Beat=0:10
        """
        try legacyBWG.write(to: legacyBWGURL, atomically: true, encoding: .utf8)

        coordinator.handleIncomingURLs([legacyBWGURL])

        let alert = try #require(coordinator.importAlert)
        #expect(alert.message.contains(String(localized: "External WAV background audio is not supported.")))
        #expect(alert.message.contains(String(localized: "Visual / screen-flash stimulation is not supported.")))
        let storedCustom = store.allPresets().filter { !$0.isBuiltIn }
        #expect(storedCustom.count == 1)
        #expect(storedCustom[0].name == "Legacy Rain Strobe")
        #expect(coordinator.engine.currentPreset.name == "Legacy Rain Strobe")
    }

    @MainActor
    @Test func reviewFocus5_stalePersistedUIDAndZeroAudioDevicesFallBackSafely() throws {
        let (defaults, cleanupDefaults) = try makeIsolatedDefaults()
        defer { cleanupDefaults() }

        defaults.set("stale-usb-dac-uid", forKey: MacAudioDeviceManager.selectedDeviceUIDDefaultsKey)

        let manager = MacAudioDeviceManager(
            userDefaults: defaults,
            startHardwareMonitoring: false
        )
        #expect(manager.selectedDeviceUID == nil)

        manager.applySnapshotForTesting(devices: [], defaultUID: nil)
        #expect(manager.selectedDeviceUID == nil)
        #expect(manager.currentRoute == .other)
        #expect(manager.availableDevices.isEmpty)

        let speakerDevice = AudioOutputDevice(
            uid: "builtin-speaker",
            name: "MacBook Speakers",
            route: .speaker,
            isSystemDefault: true
        )
        manager.applySnapshotForTesting(devices: [speakerDevice], defaultUID: speakerDevice.uid)
        #expect(manager.selectedDeviceUID == nil)
        #expect(manager.currentRoute == .speaker)
        #expect(manager.availableDevices == [speakerDevice])
    }

    @Test func macBundleContainsPrivacyManifestE174_1AndRussianTranslations() throws {
        let hostBundle = try #require(Bundle(identifier: "com.waveforge.mac"))
        let privacyURL = try #require(
            hostBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let privacyData = try Data(contentsOf: privacyURL)
        let privacyPlist = try #require(
            PropertyListSerialization.propertyList(from: privacyData, format: nil) as? [String: Any]
        )

        #expect((privacyPlist["NSPrivacyTracking"] as? Bool) == false)
        let accessedTypes = try #require(privacyPlist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = accessedTypes.flatMap { entry in
            entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        #expect(reasons.contains("E174.1"))

        let enURL = try #require(
            hostBundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "en"
            )
        )
        let ruURL = try #require(
            hostBundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "ru"
            )
        )

        let enStrings = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: enURL), format: nil) as? [String: String]
        )
        let ruStrings = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: ruURL), format: nil) as? [String: String]
        )

        let requiredMacKeys: [(key: String, expectedRU: String)] = [
            ("System Default", "Системное по умолчанию"),
            ("Output Device", "Устройство вывода"),
            ("Playback", "Воспроизведение"),
            ("Import Preset…", "Импортировать пресет…"),
            ("Export Audio…", "Экспортировать аудио…"),
            ("Increase Master Gain", "Увеличить общую громкость"),
            ("Decrease Master Gain", "Уменьшить общую громкость"),
            ("Quit WaveForge", "Завершить WaveForge"),
            ("Drop .bwg or .waveforge to Import", "Перетащите .bwg или .waveforge для импорта"),
            ("Save As…", "Сохранить как…"),
            ("Save .waveforge…", "Сохранить .waveforge…"),
            ("You have unsaved studio edits. Save before switching presets?", "В студии есть несохранённые изменения. Сохранить перед сменой пресета?"),
            ("About WaveForge", "О WaveForge"),
            ("Studio Rack", "Студийная стойка"),
            ("Delete Point", "Удалить точку"),
            ("Skip Back 30s", "Назад на 30 с"),
            ("Skip Forward 30s", "Вперёд на 30 с"),
            ("Headphones Disconnected", "Наушники отключены"),
            ("Unsaved Changes", "Несохранённые изменения"),
            ("Discard Changes", "Отменить изменения"),
            ("Keep Editing", "Продолжить"),
        ]

        for entry in requiredMacKeys {
            let enValue = enStrings[entry.key]
            let ruValue = ruStrings[entry.key]
            #expect(enValue != nil, "Missing EN translation for key: \(entry.key)")
            #expect(ruValue == entry.expectedRU, "Unexpected RU translation for key \(entry.key): \(String(describing: ruValue))")
        }
    }

    // MARK: - Test Isolation Helpers

    private func makeTempDirectory() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveForgeMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, {
            try? FileManager.default.removeItem(at: dir)
        })
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, () -> Void) {
        let suiteName = "com.waveforge.mac.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    @MainActor
    private func verifyToolbarSearchFieldSpaceBehavior(
        in window: NSWindow,
        searchField: NSSearchField,
        coordinator: MacAppCoordinator
    ) throws {
        let (testMenu, playItem, menuTarget) = makeIsolatedPlaybackMenu()
        coordinator.targetMainMenuForTesting = testMenu
        coordinator.observeWindowFirstResponderForTesting(window)
        #expect(!coordinator.isTextInputFirstResponder)
        #expect(playItem.keyEquivalent == " ")

        #expect(window.makeFirstResponder(searchField))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let fieldEditor = try #require(window.firstResponder as? NSText)
        #expect(MacAppCoordinator.isTextInputFirstResponder(in: window))
        #expect(coordinator.isTextInputFirstResponder)
        #expect(!coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: nil,
            isFirstResponderTextEditor: coordinator.isTextInputFirstResponder
        ))
        #expect(playItem.keyEquivalent.isEmpty)

        let spaceDown = try makeSpaceKeyDownEvent(in: window)
        #expect(!testMenu.performKeyEquivalent(with: spaceDown))
        #expect(!menuTarget.playActionTriggered)

        if window.isKeyWindow {
            #expect(MacAppCoordinator.isFirstResponderTextEditor)
            let swallowedByMainMenu = NSApp.mainMenu?.performKeyEquivalent(with: spaceDown) ?? false
            #expect(!swallowedByMainMenu, "NSApp.mainMenu.performKeyEquivalent swallowed Space while toolbar NSSearchField had focus!")
        }

        window.sendEvent(spaceDown)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(fieldEditor.string == " " || searchField.stringValue == " ")

        // Resigning search focus restores Space Play/Pause availability and menu keyEquivalent.
        #expect(window.makeFirstResponder(nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!coordinator.isTextInputFirstResponder)
        #expect(coordinator.shouldHandlePlayPauseSpaceShortcut(
            isTextInputFocused: false,
            isFirstResponderTextEditor: coordinator.isTextInputFirstResponder
        ))
        #expect(playItem.keyEquivalent == " ")
        #expect(testMenu.performKeyEquivalent(with: spaceDown))
        #expect(menuTarget.playActionTriggered)
    }

    @MainActor
    private func makeIsolatedPlaybackMenu() -> (menu: NSMenu, playItem: NSMenuItem, target: TestMenuActionTarget) {
        let target = TestMenuActionTarget()
        let rootMenu = NSMenu(title: "MainMenu")
        let playbackTopItem = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        let playbackSubmenu = NSMenu(title: "Playback")
        let playItem = NSMenuItem(
            title: "Play",
            action: #selector(TestMenuActionTarget.handlePlay(_:)),
            keyEquivalent: " "
        )
        playItem.keyEquivalentModifierMask = []
        playItem.target = target
        playbackSubmenu.addItem(playItem)
        playbackTopItem.submenu = playbackSubmenu
        rootMenu.addItem(playbackTopItem)
        return (rootMenu, playItem, target)
    }

    @MainActor
    private func activateKeyWindow(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 {
            if window.isKeyWindow { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            window.makeKey()
        }
    }

    @MainActor
    private func makeSpaceKeyDownEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
    }

    @MainActor
    private func findSearchField(in window: NSWindow) -> NSSearchField? {
        if let items = window.toolbar?.items {
            for item in items {
                if let searchItem = item as? NSSearchToolbarItem {
                    return searchItem.searchField
                }
                if let view = item.view, let found = findSearchField(in: view) {
                    return found
                }
            }
        }
        if let contentView = window.contentView {
            return findSearchField(in: contentView)
        }
        return nil
    }

    @MainActor
    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField {
            return searchField
        }
        for subview in view.subviews {
            if let found = findSearchField(in: subview) {
                return found
            }
        }
        return nil
    }
}

@MainActor
private final class TestSearchToolbarDelegate: NSObject, NSToolbarDelegate {
    static let searchItemID = NSToolbarItem.Identifier("TestSearchItem")
    private let searchField: NSSearchField

    init(searchField: NSSearchField) {
        self.searchField = searchField
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.searchItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.searchItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = searchField
        return item
    }
}

@MainActor
private final class TestMenuActionTarget: NSObject {
    var playActionTriggered = false

    @objc func handlePlay(_ sender: Any?) {
        playActionTriggered = true
    }
}
