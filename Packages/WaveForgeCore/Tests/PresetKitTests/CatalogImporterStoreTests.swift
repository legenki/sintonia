import Foundation
import Testing
@testable import PresetKit
@testable import SynthCore

@Suite("Catalog, BWGImporter, and PresetStore")
struct CatalogImporterStoreTests {
    @Test func allEighteenBuiltInPresetsValidateCompileAndRenderFiniteAudio() {
        let presets = PresetCatalog.builtInPresets
        #expect(presets.count == 18)
        for preset in presets {
            #expect(preset.isBuiltIn)
            #expect((1800...2700).contains(preset.durationSec))
            #expect(PresetValidator.validate(preset).isEmpty)

            let encoded = try? PresetCodec.encode(preset)
            #expect(encoded != nil)
            if let encoded {
                #expect((try? PresetCodec.decode(encoded)) == preset)
            }

            let snap = SnapshotCompiler.compile(preset)
            let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
            renderer.setPlaying(true)
            var l = [Float](repeating: 0, count: 1024)
            var r = [Float](repeating: 0, count: 1024)
            l.withUnsafeMutableBufferPointer { lPtr in
                r.withUnsafeMutableBufferPointer { rPtr in
                    renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 1024)
                }
            }
            for s in l + r { #expect(s.isFinite && abs(s) <= 1.0) }
        }
    }

    @Test func builtInCatalogHasDeterministicIDsExactMetadataAndTrackingRules() {
        let presets = PresetCatalog.builtInPresets
        let secondRead = PresetCatalog.builtInPresets
        #expect(presets.map(\.id) == secondRead.map(\.id))
        #expect(Set(presets.map(\.id)).count == 18)

        let allVoiceIDs = presets.flatMap { $0.voices.map(\.id) }
        #expect(Set(allVoiceIDs).count == allVoiceIDs.count)

        for preset in presets {
            #expect(preset.category != .custom)
            #expect(!preset.name.isEmpty)
            #expect(!preset.summary.isEmpty)
        }

        // Verify exact spec metadata for key presets
        #expect(presets[0].name == "Deep Focus")
        #expect(presets[0].category == .focus)
        #expect(presets[0].durationSec == 2400)
        #expect(presets[0].recommendedOutput == .headphones)

        let studyAnchor = presets.first(where: { $0.name == "Study Anchor" })
        #expect(studyAnchor?.category == .focus)
        #expect(studyAnchor?.durationSec == 2100)
        #expect(studyAnchor?.voices.count == 2)
        #expect(studyAnchor?.voices[1].trackingRule == VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0.0))

        let schumann = presets.first(where: { $0.name == "Schumann Earth 7.83 Hz" })
        #expect(schumann?.category == .meditation)
        #expect(schumann?.durationSec == 2100)
        #expect(schumann?.voices.count == 3)
        #expect(schumann?.voices[1].trackingRule == VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .beat, ratio: 2.0, offset: 0.0))

        let memoryRetention = presets.first(where: { $0.name == "Memory Retention" })
        #expect(memoryRetention?.category == .study)
        #expect(memoryRetention?.durationSec == 2100)
        #expect(memoryRetention?.voices[1].trackingRule == VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0.0))

        let reading = presets.first(where: { $0.name == "Reading Companion" })
        #expect(reading?.category == .study)
        #expect(reading?.durationSec == 2400)
        #expect(reading?.voices.count == 1)
        #expect(reading?.voices[0].mode == .isochronic)
        #expect(reading?.recommendedOutput == .any)

        let insomnia = presets.first(where: { $0.name == "Insomnia Drift" })
        #expect(insomnia?.category == .sleep)
        #expect(insomnia?.durationSec == 2700)
    }

    @Test func bwgImporterParsesValidPresetFixture() throws {
        let text = """
        BrainWave Generator File
        Version=3.1.12
        Name=Classic Alpha Study
        Duration=1800
        NoiseVolume=0.20
        NoiseSmoothness=0.50
        Voice1.Waveform=Sine
        Voice1.Carrier=0:220,900:200,1800:220
        Voice1.Beat=0:12,900:10,1800:12
        Voice1.Volume=0:0.8,1800:0.8
        """
        let result = try BWGImporter.importPreset(from: Data(text.utf8), fallbackName: "Imported")
        #expect(result.preset.name == "Classic Alpha Study")
        #expect(result.preset.durationSec == 1800)
        #expect(result.preset.category == .custom)
        #expect(!result.preset.isBuiltIn)
        #expect(result.preset.voices.count == 1)
        #expect(result.preset.voices[0].waveform == .sine)
        #expect(result.preset.noise.isEnabled)
        #expect(result.report.skippedFeatures.isEmpty)
        #expect(PresetValidator.validate(result.preset).isEmpty)
    }

    @Test func bwgImporterSkipsLegacyWavAndVisualStrobeWithReport() throws {
        let text = """
        BrainWave Generator File
        Version=3.1.12
        Name=Rainy Lucid
        Duration=2400
        BackgroundSound=rain_loop.wav
        VisualStimulation=1
        Voice1.Waveform=SineSquared
        Voice1.Carrier=0:150,2400:140
        Voice1.Beat=0:10,2400:5.5
        Voice1.Volume=0:0.7,2400:0.7
        """
        let result = try BWGImporter.importPreset(from: Data(text.utf8), fallbackName: "Fallback")
        #expect(result.preset.voices.count == 1)
        #expect(result.preset.voices[0].waveform == .sineSquared)
        #expect(result.report.skippedFeatures.contains(.externalWavBackground))
        #expect(result.report.skippedFeatures.contains(.visualStimulation))
        #expect(PresetValidator.validate(result.preset).isEmpty)
    }

    @Test func bwgImporterParsesLegacyBinaryPayloadWithEmbeddedTokens() throws {
        var binary = Data("BrainWave Generator File".utf8)
        binary.append(contentsOf: [0x00, 0x1A, 0x03, 0x01, 0x0C, 0xFF, 0xFE, 0x00])
        binary.append(Data("Duration=2000".utf8))
        binary.append(contentsOf: [0x00, 0x04, 0x80])
        binary.append(Data("Voice1.Mode=Isochronic".utf8))
        binary.append(contentsOf: [0x00, 0x10])
        binary.append(Data("Voice1.Waveform=SmoothedSquare".utf8))
        binary.append(contentsOf: [0x00, 0x00, 0xA5])
        binary.append(Data("Voice1.Carrier=0:250,2000:250".utf8))
        binary.append(contentsOf: [0x00])
        binary.append(Data("Voice1.Beat=0:40,2000:40".utf8))
        binary.append(contentsOf: [0x00])
        binary.append(Data("Voice1.Volume=0:0.6,2000:0.6".utf8))
        binary.append(contentsOf: [0x00, 0x7F])
        binary.append(Data("ocean_waves.wav".utf8))
        binary.append(contentsOf: [0x00])
        binary.append(Data("AudioStrobe=1".utf8))
        binary.append(contentsOf: [0x00, 0xFF])

        let result = try BWGImporter.importPreset(from: binary, fallbackName: "Binary Gamma")
        #expect(result.preset.name == "Binary Gamma")
        #expect(result.preset.durationSec == 2000)
        #expect(result.preset.voices.count == 1)
        #expect(result.preset.voices[0].mode == .isochronic)
        #expect(result.preset.voices[0].waveform == .smoothSquare)
        #expect(result.preset.recommendedOutput == .any)
        #expect(result.report.skippedFeatures.contains(.externalWavBackground))
        #expect(result.report.skippedFeatures.contains(.visualStimulation))
        #expect(PresetValidator.validate(result.preset).isEmpty)
    }

    @Test func bwgImporterSanitizesOutOfRangeNaNUnsortedAndDuplicateTimestamps() throws {
        let text = """
        BrainWave Generator File
        Version=3.1.12
        Duration=99999
        NoiseVolume=1.5
        NoiseSmoothness=-0.2
        Voice1.Waveform=Triangle
        Voice1.Pan=4.0
        Voice1.IsochronicSoftness=0.001
        Voice1.IsochronicDutyCycle=0.99
        Voice1.Carrier=900:2500,-10:20,300:nan,300:200,300:220
        Voice1.Beat=600:120,0:0.1
        Voice1.Volume=0:-0.5,600:1.8
        Voice1.Tracking=Voice2:Carrier:1.5:0
        Voice2.Carrier=0:200 600:220
        Voice2.Beat=0:10 600:10
        Voice2.Tracking=Voice1:Carrier:1.5:0
        """
        let result = try BWGImporter.importPreset(from: Data(text.utf8), fallbackName: "Sanitized")
        #expect(result.preset.name == "Sanitized")
        #expect(result.preset.durationSec == PresetLimits.durationRange.upperBound)
        #expect(result.preset.voices.count == 2)
        #expect(PresetValidator.validate(result.preset).isEmpty)

        let voice = result.preset.voices[0]
        #expect(voice.waveform == .triangle)
        let carrierPoints = voice.carrierCurve.points
        #expect(carrierPoints.count == 3)
        #expect(carrierPoints[0] == CurvePoint(timeSec: 0, value: 40))
        #expect(carrierPoints[1] == CurvePoint(timeSec: 300, value: 220))
        #expect(carrierPoints[2] == CurvePoint(timeSec: 900, value: 1000))
        #expect(!result.report.warnings.isEmpty)

        let snap = SnapshotCompiler.compile(result.preset)
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
        renderer.setPlaying(true)
        var l = [Float](repeating: 0, count: 256)
        var r = [Float](repeating: 0, count: 256)
        l.withUnsafeMutableBufferPointer { lPtr in
            r.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 256)
            }
        }
        for s in l + r { #expect(s.isFinite && abs(s) <= 1.0) }
    }

    @Test func bwgImporterRejectsInvalidEmptyCorruptedAndZeroVoiceFiles() {
        #expect(throws: BWGImportError.emptyFile) {
            _ = try BWGImporter.importPreset(from: Data(), fallbackName: "Empty")
        }
        #expect(throws: BWGImportError.invalidHeader) {
            _ = try BWGImporter.importPreset(from: Data("Not a BWG file".utf8), fallbackName: "Bad")
        }

        var corruptedBinary = Data("BrainWave Generator File".utf8)
        corruptedBinary.append(contentsOf: [0x00, 0xFF, 0xFE, 0x01, 0x02, 0x80, 0x99])
        #expect(throws: BWGImportError.corruptedStructure) {
            _ = try BWGImporter.importPreset(from: corruptedBinary, fallbackName: "Corrupt")
        }

        let noVoicesText = """
        BrainWave Generator File
        Version=3.1.12
        Name=No Voices Here
        Duration=1800
        Voice1.Carrier=0:nan
        Voice1.Beat=0:inf
        """
        #expect(throws: BWGImportError.noValidVoices) {
            _ = try BWGImporter.importPreset(from: Data(noVoicesText.utf8), fallbackName: "NoVoices")
        }
    }

    @Test func presetStoreForksBuiltInOnEditLeavingBuiltInImmutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WaveForgeStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PresetStore(storageDirectory: dir)
        var builtIn = PresetCatalog.builtInPresets[0]
        builtIn.name = "My Deep Focus Tweaked"

        let saved = try store.saveEdited(builtIn)
        #expect(!saved.isBuiltIn)
        #expect(saved.category == .custom)
        #expect(saved.id != builtIn.id)

        let all = store.allPresets()
        #expect(all.count == 19)
        #expect(all.first(where: { $0.id == builtIn.id })?.name == PresetCatalog.builtInPresets[0].name)
    }

    @Test func presetStorePersistsReloadsEditsInPlaceAndDeletesCustomPresets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WaveForgeStorePersist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corruptURL = dir.appendingPathComponent("corrupt.waveforge")
        try Data("not valid json".utf8).write(to: corruptURL)

        let store = PresetStore(storageDirectory: dir)
        #expect(store.allPresets().count == 18)

        let imported = try BWGImporter.importPreset(
            from: Data(
                """
                BrainWave Generator File
                Name=Evening Custom
                Duration=1800
                Voice1.Carrier=0:180
                Voice1.Beat=0:8
                Voice1.Volume=0:0.7
                """.utf8
            ),
            fallbackName: "Fallback"
        ).preset

        try store.saveCustom(imported)
        #expect(store.allPresets().count == 19)

        var updated = imported
        updated.name = "Evening Custom Revised"
        let editedSaved = try store.saveEdited(updated)
        #expect(editedSaved.id == imported.id)
        #expect(editedSaved.name == "Evening Custom Revised")

        let reloaded = PresetStore(storageDirectory: dir)
        #expect(reloaded.allPresets().count == 19)
        #expect(reloaded.allPresets().first(where: { $0.id == imported.id })?.name == "Evening Custom Revised")

        try reloaded.deleteCustom(id: imported.id)
        #expect(reloaded.allPresets().count == 18)
        let reloadedAfterDelete = PresetStore(storageDirectory: dir)
        #expect(reloadedAfterDelete.allPresets().count == 18)

        let builtInID = PresetCatalog.builtInPresets[0].id
        #expect(throws: PresetStoreError.cannotModifyBuiltIn) {
            try reloadedAfterDelete.deleteCustom(id: builtInID)
        }
        #expect(throws: PresetStoreError.cannotModifyBuiltIn) {
            try reloadedAfterDelete.saveCustom(PresetCatalog.builtInPresets[0])
        }
    }
}
