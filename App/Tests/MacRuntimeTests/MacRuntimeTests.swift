import Foundation
import PresetKit
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
}
