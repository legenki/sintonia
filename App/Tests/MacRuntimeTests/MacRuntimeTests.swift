import Foundation
import PresetKit
import SynthCore
import Testing
@testable import WaveForgeMac

@Suite("WaveForgeMac Runtime Smoke Tests", .serialized)
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
        #expect(controller.selectedOutputDeviceUID == nil)
        _ = controller.availableOutputDevices
    }
}
