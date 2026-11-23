import Foundation
import Observation
import PresetKit
import SynthCore

/// Minimal macOS application coordinator scaffold; expanded in Task 5 with multi-window,
/// menu bar, and document import wiring.
@MainActor
@Observable
public final class MacAppCoordinator {
    public let engine: AudioEngineController
    public let presetStore: PresetStore

    public init(
        engine: AudioEngineController = AudioEngineController(),
        presetStore: PresetStore = PresetStore(storageDirectory: MacAppCoordinator.defaultPresetStorageURL())
    ) {
        self.engine = engine
        self.presetStore = presetStore
    }

    public static func defaultPresetStorageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("WaveForge", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true)
    }
}
