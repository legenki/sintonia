import Foundation
import Testing
@testable import PresetKit
@testable import SynthCore

@Suite("PresetKit Models, Validator, Compiler, and Codec")
struct PresetModelTests {
    private func samplePreset(voices: [Voice]? = nil) -> Preset {
        let v0 = Voice(
            id: UUID(), name: "Primary", isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 200), CurvePoint(timeSec: 1800, value: 160)], interpolation: .smoothStep),
            beatCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 14), CurvePoint(timeSec: 1800, value: 8)], interpolation: .linear),
            volumeCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.7)], interpolation: .linear),
            trackingRule: nil
        )
        return Preset(
            id: UUID(), name: "Test Session", category: .focus, summary: "Test",
            durationSec: 1800, recommendedOutput: .headphones, masterGain: 0.85,
            fadeInSec: 10, fadeOutSec: 15,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.25)], interpolation: .linear),
                smoothnessCurve: EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.5)], interpolation: .linear),
                pulseEnabled: false, pulseDepth: 0, pulseSourceVoiceIndex: nil
            ),
            voices: voices ?? [v0],
            isBuiltIn: false
        )
    }

    @Test func jsonRoundTripPreservesAllPresetFields() throws {
        var preset = samplePreset()
        var v1 = preset.voices[0]
        v1.id = UUID()
        v1.name = "Harmonic"
        v1.mode = .isochronic
        v1.waveform = .smoothSquare
        v1.isochronicSoftness = 0.25
        v1.isochronicDutyCycle = 0.65
        v1.pan = -0.35
        v1.trackingRule = VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 5.0)
        preset.voices.append(v1)
        preset.noise.pulseEnabled = true
        preset.noise.pulseDepth = 0.4
        preset.noise.pulseSourceVoiceIndex = 0

        let data = try PresetCodec.encode(preset)
        let decoded = try PresetCodec.decode(data)
        #expect(decoded == preset)

        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(jsonObject?["schemaVersion"] as? Int == 1)
    }

    @Test func codecRejectsUnsupportedSchemaVersionAndInvalidData() throws {
        let preset = samplePreset()
        let data = try PresetCodec.encode(preset)
        let jsonString = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        let unsupportedData = Data(jsonString.utf8)

        #expect(throws: PresetCodecError.unsupportedSchemaVersion(99)) {
            _ = try PresetCodec.decode(unsupportedData)
        }
    }

    @Test func validatorDetectsInvalidRangesAndVoiceCounts() {
        let emptyVoices = samplePreset(voices: [])
        #expect(PresetValidator.validate(emptyVoices).contains(.invalidVoiceCount))

        let tooManyVoices = samplePreset(voices: Array(repeating: samplePreset().voices[0], count: 11))
        #expect(PresetValidator.validate(tooManyVoices).contains(.invalidVoiceCount))

        var tooShort = samplePreset()
        tooShort.durationSec = 30
        #expect(PresetValidator.validate(tooShort).contains(.invalidDuration))

        var tooLong = samplePreset()
        tooLong.durationSec = 7201
        #expect(PresetValidator.validate(tooLong).contains(.invalidDuration))

        var badFreq = samplePreset()
        badFreq.voices[0].carrierCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 2500)], interpolation: .linear)
        #expect(PresetValidator.validate(badFreq).contains(.carrierOutOfRange(voiceIndex: 0)))

        var badBeat = samplePreset()
        badBeat.voices[0].beatCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 0.2)], interpolation: .linear)
        #expect(PresetValidator.validate(badBeat).contains(.beatOutOfRange(voiceIndex: 0)))

        var badMasterAndFades = samplePreset()
        badMasterAndFades.masterGain = 1.2
        badMasterAndFades.fadeInSec = -1
        badMasterAndFades.fadeOutSec = 121
        let scalarErrors = PresetValidator.validate(badMasterAndFades)
        #expect(scalarErrors.contains(.invalidMasterGain))
        #expect(scalarErrors.contains(.invalidFadeIn))
        #expect(scalarErrors.contains(.invalidFadeOut))

        var badVoiceScalars = samplePreset()
        badVoiceScalars.voices[0].pan = 1.5
        badVoiceScalars.voices[0].isochronicSoftness = 0.01
        badVoiceScalars.voices[0].isochronicDutyCycle = 0.9
        badVoiceScalars.voices[0].volumeCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 1.5)], interpolation: .linear)
        let voiceErrors = PresetValidator.validate(badVoiceScalars)
        #expect(voiceErrors.contains(.invalidPan(voiceIndex: 0)))
        #expect(voiceErrors.contains(.invalidIsochronicSoftness(voiceIndex: 0)))
        #expect(voiceErrors.contains(.invalidIsochronicDutyCycle(voiceIndex: 0)))
        #expect(voiceErrors.contains(.volumeOutOfRange(voiceIndex: 0)))

        var badNoise = samplePreset()
        badNoise.noise.volumeCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: -0.1)], interpolation: .linear)
        badNoise.noise.smoothnessCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 1.1)], interpolation: .linear)
        badNoise.noise.pulseDepth = 1.5
        badNoise.noise.pulseSourceVoiceIndex = 3
        let noiseErrors = PresetValidator.validate(badNoise)
        #expect(noiseErrors.contains(.invalidNoiseVolume))
        #expect(noiseErrors.contains(.invalidNoiseSmoothness))
        #expect(noiseErrors.contains(.invalidNoisePulseDepth))
        #expect(noiseErrors.contains(.invalidNoisePulseSourceVoiceIndex))
    }

    @Test func cyclicAndOutOfBoundsTrackingRulesAreFlaggedAndSafelyCompiled() {
        var preset = samplePreset()
        var v1 = preset.voices[0]
        v1.id = UUID()
        v1.name = "Tracked"
        preset.voices[0].trackingRule = VoiceTrackingRule(sourceVoiceIndex: 1, targetParameter: .carrier, ratio: 1.0, offset: 0)
        v1.trackingRule = VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0)
        preset.voices.append(v1)

        let errors = PresetValidator.validate(preset)
        #expect(errors.contains(where: { if case .cyclicTracking = $0 { return true }; return false }))

        let snapshot = SnapshotCompiler.compile(preset)
        #expect(snapshot.voices.count == 2)
        #expect(snapshot.voices[0].carrierCurve.evaluate(at: 0) == 200)

        var outOfBounds = samplePreset()
        outOfBounds.voices[0].trackingRule = VoiceTrackingRule(sourceVoiceIndex: 5, targetParameter: .beat, ratio: 2.0, offset: 0)
        let oobErrors = PresetValidator.validate(outOfBounds)
        #expect(oobErrors.contains(.trackingSourceOutOfBounds(voiceIndex: 0, sourceVoiceIndex: 5)))
        let oobSnapshot = SnapshotCompiler.compile(outOfBounds)
        #expect(oobSnapshot.voices[0].beatCurve.evaluate(at: 0) == 14)

        var selfTracking = samplePreset()
        selfTracking.voices[0].trackingRule = VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0)
        let selfErrors = PresetValidator.validate(selfTracking)
        #expect(selfErrors.contains(where: { if case .cyclicTracking = $0 { return true }; return false }))
    }

    @Test func validatorFlagsEmptyNegativeTimeAndNonFiniteCurves() {
        var emptyCurvePreset = samplePreset()
        emptyCurvePreset.voices[0].carrierCurve = EnvelopeCurve(points: [], interpolation: .linear)
        #expect(PresetValidator.validate(emptyCurvePreset).contains(.emptyCurve(voiceIndex: 0)))

        var negativeTimePreset = samplePreset()
        negativeTimePreset.noise.volumeCurve = EnvelopeCurve(points: [CurvePoint(timeSec: -5, value: 0.2)], interpolation: .linear)
        #expect(PresetValidator.validate(negativeTimePreset).contains(.negativeCurveTime(voiceIndex: nil)))

        var nonFinitePreset = samplePreset()
        nonFinitePreset.voices[0].beatCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: .nan)], interpolation: .linear)
        #expect(PresetValidator.validate(nonFinitePreset).contains(.nonFiniteValue(voiceIndex: 0)))
    }

    @Test func snapshotCompilerAppliesCarrierRatioAndBeatTracking() {
        var preset = samplePreset()
        var v1 = preset.voices[0]
        v1.id = UUID()
        v1.name = "Fifth"
        v1.trackingRule = VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0)
        preset.voices.append(v1)

        #expect(PresetValidator.validate(preset).isEmpty)
        let snapshot = SnapshotCompiler.compile(preset)
        #expect(abs(snapshot.voices[1].carrierCurve.evaluate(at: 0) - 300.0) < 1e-6)
        #expect(abs(snapshot.voices[1].carrierCurve.evaluate(at: 1800) - 240.0) < 1e-6)
        // SmoothStep midpoint at t = 900 should match 1.5 * 180 = 270
        #expect(abs(snapshot.voices[1].carrierCurve.evaluate(at: 900) - 270.0) < 1e-6)
    }

    @Test func snapshotCompilerSupportsChainedTrackingAndClampsDerivedRanges() {
        var preset = samplePreset()
        // v1 tracks v0 beat with 2x + 1 -> [29, 17]
        var v1 = preset.voices[0]
        v1.id = UUID()
        v1.name = "DoubleBeat"
        v1.trackingRule = VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .beat, ratio: 2.0, offset: 1.0)

        // v2 tracks v1 beat with 3x + 0 -> clamped at 60 Hz (raw 87 at t=0, 51 at t=1800)
        var v2 = preset.voices[0]
        v2.id = UUID()
        v2.name = "ChainedClampedBeat"
        v2.trackingRule = VoiceTrackingRule(sourceVoiceIndex: 1, targetParameter: .beat, ratio: 3.0, offset: 0.0)

        // Intentionally insert v2 before v1? No, indices are 0, 1, 2; test reverse order: 0 tracks 1, 1 tracks 2
        preset.voices = [preset.voices[0], v1, v2]
        #expect(PresetValidator.validate(preset).isEmpty)

        let snapshot = SnapshotCompiler.compile(preset)
        #expect(abs(snapshot.voices[1].beatCurve.evaluate(at: 0) - 29.0) < 1e-6)
        #expect(abs(snapshot.voices[1].beatCurve.evaluate(at: 1800) - 17.0) < 1e-6)
        #expect(abs(snapshot.voices[2].beatCurve.evaluate(at: 0) - 60.0) < 1e-6)
        #expect(abs(snapshot.voices[2].beatCurve.evaluate(at: 1800) - 51.0) < 1e-6)

        // Reverse dependency order: voice 0 tracks voice 1 (carrier), voice 1 has no rule
        var reversePreset = samplePreset()
        var sourceVoice = reversePreset.voices[0]
        sourceVoice.id = UUID()
        sourceVoice.name = "Source"
        sourceVoice.carrierCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 100)], interpolation: .linear)
        reversePreset.voices[0].trackingRule = VoiceTrackingRule(sourceVoiceIndex: 1, targetParameter: .carrier, ratio: 2.0, offset: 20.0)
        reversePreset.voices.append(sourceVoice)

        #expect(PresetValidator.validate(reversePreset).isEmpty)
        let reverseSnapshot = SnapshotCompiler.compile(reversePreset)
        #expect(abs(reverseSnapshot.voices[0].carrierCurve.evaluate(at: 0) - 220.0) < 1e-6)
    }
}
