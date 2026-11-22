import Foundation
import SynthCore

/// Catalog of WaveForge's 18 original built-in 30–45 minute entrainment presets.
public enum PresetCatalog {
    /// Deterministic, immutable list of 18 built-in entrainment programs matching Spec Section 6.
    public static let builtInPresets: [Preset] = [
        deepFocus(),
        gammaPeakFlow(),
        morningEnergizer(),
        studyAnchor(),
        deepUnwind(),
        postWorkReset(),
        tensionRelief(),
        deepSleepDescent(),
        powerNap30(),
        lucidDreamGateway(),
        insomniaDrift(),
        zenThetaStillness(),
        schumannEarth(),
        deepBreathSync(),
        memoryRetention(),
        creativeCrossover(),
        readingCompanion(),
        problemSolvingSprint(),
    ]

    // MARK: - Deterministic IDs & Builders

    private static func presetUUID(_ index: Int) -> UUID {
        let suffix = String(format: "%012X", index)
        return UUID(uuidString: "A5700001-0000-4000-8000-\(suffix)")!
    }

    private static func voiceUUID(presetIndex: Int, voiceIndex: Int) -> UUID {
        let suffix = String(format: "%04X%08X", presetIndex, voiceIndex)
        return UUID(uuidString: "B5700001-0000-4000-8000-\(suffix)")!
    }

    private static func curve(
        _ points: [(Double, Double)],
        interpolation: CurveInterpolation = .smoothStep
    ) -> EnvelopeCurve {
        EnvelopeCurve(
            points: points.map { CurvePoint(timeSec: $0.0, value: $0.1) },
            interpolation: interpolation
        )
    }

    private static func constant(_ value: Double) -> EnvelopeCurve {
        EnvelopeCurve(
            points: [CurvePoint(timeSec: 0.0, value: value)],
            interpolation: .linear
        )
    }

    private static func breathModulatedCurve(
        durationSec: Double,
        cycleSec: Double,
        minValue: Double,
        maxValue: Double
    ) -> EnvelopeCurve {
        let cycleCount = max(1, Int(durationSec / cycleSec))
        var points: [CurvePoint] = []
        points.reserveCapacity(cycleCount * 2 + 1)

        for cycle in 0..<cycleCount {
            let start = Double(cycle) * cycleSec
            let peak = start + cycleSec * 0.45
            points.append(CurvePoint(timeSec: start, value: minValue))
            if peak < durationSec {
                points.append(CurvePoint(timeSec: peak, value: maxValue))
            }
        }
        points.append(CurvePoint(timeSec: durationSec, value: minValue))
        return EnvelopeCurve(points: points, interpolation: .smoothStep)
    }

    private static func makeVoice(
        presetIndex: Int,
        voiceIndex: Int,
        name: String,
        mode: EntrainmentMode,
        waveform: Waveform,
        isochronicSoftness: Double = 0.6,
        isochronicDutyCycle: Double = 0.5,
        pan: Double = 0.0,
        carrier: EnvelopeCurve,
        beat: EnvelopeCurve,
        volume: EnvelopeCurve,
        trackingRule: VoiceTrackingRule? = nil
    ) -> Voice {
        Voice(
            id: voiceUUID(presetIndex: presetIndex, voiceIndex: voiceIndex),
            name: name,
            isEnabled: true,
            isMuted: false,
            isSolo: false,
            mode: mode,
            waveform: waveform,
            isochronicSoftness: isochronicSoftness,
            isochronicDutyCycle: isochronicDutyCycle,
            pan: pan,
            carrierCurve: carrier,
            beatCurve: beat,
            volumeCurve: volume,
            trackingRule: trackingRule
        )
    }

    private static func makePreset(
        index: Int,
        name: String,
        category: PresetCategory,
        summary: String,
        durationSec: Double,
        masterGain: Double = 0.84,
        fadeInSec: Double = 15.0,
        fadeOutSec: Double = 20.0,
        noise: NoiseLayer,
        voices: [Voice]
    ) -> Preset {
        let hasBinaural = voices.contains { $0.isEnabled && $0.mode == .binaural }
        return Preset(
            id: presetUUID(index),
            name: name,
            category: category,
            summary: summary,
            durationSec: durationSec,
            recommendedOutput: hasBinaural ? .headphones : .any,
            masterGain: masterGain,
            fadeInSec: fadeInSec,
            fadeOutSec: fadeOutSec,
            noise: noise,
            voices: voices,
            isBuiltIn: true
        )
    }

    // MARK: - 18 Built-In Presets (Spec Section 6)

    private static func deepFocus() -> Preset {
        makePreset(
            index: 1,
            name: "Deep Focus",
            category: .focus,
            summary: "Binaural Beta 14 -> 18 -> 15 Hz with harmonic isochronic support and steady pink noise.",
            durationSec: 2400,
            masterGain: 0.85,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.18),
                smoothnessCurve: constant(0.5),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 1,
                    voiceIndex: 1,
                    name: "Beta Focus Carrier",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(210),
                    beat: curve([(0, 14.0), (300, 16.5), (1200, 18.0), (2100, 15.0), (2400, 15.0)]),
                    volume: constant(0.78)
                ),
                makeVoice(
                    presetIndex: 1,
                    voiceIndex: 2,
                    name: "Harmonic Iso Layer",
                    mode: .isochronic,
                    waveform: .sine,
                    isochronicSoftness: 0.65,
                    isochronicDutyCycle: 0.5,
                    carrier: constant(315),
                    beat: curve([(0, 14.0), (1200, 18.0), (2400, 15.0)]),
                    volume: curve([(0, 0.2), (300, 0.36), (2100, 0.36), (2400, 0.2)])
                ),
            ]
        )
    }

    private static func gammaPeakFlow() -> Preset {
        makePreset(
            index: 2,
            name: "Gamma Peak Flow",
            category: .focus,
            summary: "Isochronic 40 Hz Gamma pulse paired with a gentle 10 Hz Alpha foundation and light pink noise.",
            durationSec: 1800,
            masterGain: 0.82,
            fadeInSec: 12,
            fadeOutSec: 15,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.12),
                smoothnessCurve: constant(0.5),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 2,
                    voiceIndex: 1,
                    name: "Gamma 40 Hz Pulse",
                    mode: .isochronic,
                    waveform: .smoothSquare,
                    isochronicSoftness: 0.45,
                    isochronicDutyCycle: 0.45,
                    carrier: constant(320),
                    beat: constant(40.0),
                    volume: constant(0.68)
                ),
                makeVoice(
                    presetIndex: 2,
                    voiceIndex: 2,
                    name: "Alpha Foundation",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(160),
                    beat: constant(10.0),
                    volume: constant(0.45)
                ),
            ]
        )
    }

    private static func morningEnergizer() -> Preset {
        makePreset(
            index: 3,
            name: "Morning Energizer",
            category: .focus,
            summary: "Smooth 10 -> 20 Hz upward ramp with triangle binaural carrier and tapering white-to-pink noise.",
            durationSec: 1800,
            masterGain: 0.85,
            fadeInSec: 15,
            fadeOutSec: 10,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: curve([(0, 0.22), (1200, 0.16), (1800, 0.04)]),
                smoothnessCurve: curve([(0, 0.0), (1800, 0.5)]),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 3,
                    voiceIndex: 1,
                    name: "Beta Ramp Primary",
                    mode: .binaural,
                    waveform: .triangle,
                    carrier: curve([(0, 240), (1800, 280)]),
                    beat: curve([(0, 10.0), (600, 14.0), (1500, 20.0), (1800, 20.0)]),
                    volume: constant(0.70)
                ),
                makeVoice(
                    presetIndex: 3,
                    voiceIndex: 2,
                    name: "Sub-Octave Lift",
                    mode: .monaural,
                    waveform: .sine,
                    carrier: curve([(0, 120), (1800, 140)]),
                    beat: curve([(0, 10.0), (1500, 20.0), (1800, 20.0)]),
                    volume: constant(0.38)
                ),
            ]
        )
    }

    private static func studyAnchor() -> Preset {
        makePreset(
            index: 4,
            name: "Study Anchor",
            category: .focus,
            summary: "Steady 13.5 Hz SMR focus anchored by a fifth-tracking harmonic voice and warm brown noise.",
            durationSec: 2100,
            masterGain: 0.85,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.22),
                smoothnessCurve: constant(0.95),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 4,
                    voiceIndex: 1,
                    name: "SMR Anchor",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(190),
                    beat: constant(13.5),
                    volume: constant(0.75)
                ),
                makeVoice(
                    presetIndex: 4,
                    voiceIndex: 2,
                    name: "Fifth Harmonic",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(285),
                    beat: constant(13.5),
                    volume: constant(0.42),
                    trackingRule: VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0.0)
                ),
            ]
        )
    }

    private static func deepUnwind() -> Preset {
        makePreset(
            index: 5,
            name: "Deep Unwind",
            category: .relax,
            summary: "Gentle Beta 15 -> Alpha 8.5 Hz unwind paired with pink-to-brown noise transition.",
            durationSec: 2100,
            masterGain: 0.82,
            fadeInSec: 20,
            fadeOutSec: 25,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.22),
                smoothnessCurve: curve([(0, 0.5), (2100, 1.0)]),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 5,
                    voiceIndex: 1,
                    name: "Alpha Descent",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: curve([(0, 180), (1500, 155), (2100, 150)]),
                    beat: curve([(0, 15.0), (900, 10.5), (1650, 8.5), (2100, 8.5)]),
                    volume: constant(0.75)
                ),
                makeVoice(
                    presetIndex: 5,
                    voiceIndex: 2,
                    name: "Warm Octave Drone",
                    mode: .monaural,
                    waveform: .sineSquared,
                    carrier: curve([(0, 90), (2100, 75)]),
                    beat: curve([(0, 15.0), (1650, 8.5), (2100, 8.5)]),
                    volume: constant(0.35)
                ),
            ]
        )
    }

    private static func postWorkReset() -> Preset {
        makePreset(
            index: 6,
            name: "Post-Work Reset",
            category: .relax,
            summary: "Three-voice 14 -> 7.83 Hz Schumann transition blending binaural, monaural, and Sine² layers.",
            durationSec: 1800,
            masterGain: 0.84,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.18),
                smoothnessCurve: constant(0.75),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 6,
                    voiceIndex: 1,
                    name: "Schumann Binaural",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: curve([(0, 200), (900, 160), (1800, 160)]),
                    beat: curve([(0, 14.0), (900, 7.83), (1800, 7.83)]),
                    volume: constant(0.70)
                ),
                makeVoice(
                    presetIndex: 6,
                    voiceIndex: 2,
                    name: "Schumann Monaural",
                    mode: .monaural,
                    waveform: .sine,
                    carrier: curve([(0, 200), (900, 160), (1800, 160)]),
                    beat: curve([(0, 14.0), (900, 7.83), (1800, 7.83)]),
                    volume: constant(0.45)
                ),
                makeVoice(
                    presetIndex: 6,
                    voiceIndex: 3,
                    name: "Warm Sine² Pad",
                    mode: .monaural,
                    waveform: .sineSquared,
                    carrier: curve([(0, 100), (900, 80), (1800, 80)]),
                    beat: curve([(0, 14.0), (900, 7.83), (1800, 7.83)]),
                    volume: constant(0.40)
                ),
            ]
        )
    }

    private static func tensionRelief() -> Preset {
        makePreset(
            index: 7,
            name: "Tension Relief",
            category: .relax,
            summary: "Three-voice Alpha/Theta harmonic chord at 136.1 Hz and octave with soothing brown noise.",
            durationSec: 1800,
            masterGain: 0.82,
            fadeInSec: 20,
            fadeOutSec: 25,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.24),
                smoothnessCurve: constant(0.95),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 7,
                    voiceIndex: 1,
                    name: "Alpha Chord Root",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(136.1),
                    beat: curve([(0, 10.0), (900, 8.0), (1800, 6.0)]),
                    volume: constant(0.70)
                ),
                makeVoice(
                    presetIndex: 7,
                    voiceIndex: 2,
                    name: "Theta Octave",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(272.2),
                    beat: curve([(0, 10.0), (600, 6.0), (1800, 6.0)]),
                    volume: constant(0.45)
                ),
                makeVoice(
                    presetIndex: 7,
                    voiceIndex: 3,
                    name: "Low Resonance Anchor",
                    mode: .monaural,
                    waveform: .sine,
                    carrier: constant(68.05),
                    beat: constant(6.0),
                    volume: constant(0.38)
                ),
            ]
        )
    }

    private static func deepSleepDescent() -> Preset {
        makePreset(
            index: 8,
            name: "Deep Sleep Descent",
            category: .sleep,
            summary: "Staged Alpha 10 -> Theta 5 -> Delta 1.5 Hz descent with softly fading brown noise.",
            durationSec: 2400,
            masterGain: 0.78,
            fadeInSec: 25,
            fadeOutSec: 60,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: curve([(0, 0.28), (1600, 0.22), (2400, 0.05)]),
                smoothnessCurve: constant(1.0),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 8,
                    voiceIndex: 1,
                    name: "Sleep Descent Primary",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: curve([(0, 140), (720, 120), (1440, 105), (2400, 95)]),
                    beat: curve([(0, 10.0), (600, 5.0), (1200, 5.0), (1800, 1.5), (2400, 1.5)]),
                    volume: curve([(0, 0.75), (2100, 0.65), (2400, 0.35)])
                ),
                makeVoice(
                    presetIndex: 8,
                    voiceIndex: 2,
                    name: "Sub-Delta Anchor",
                    mode: .monaural,
                    waveform: .sine,
                    carrier: curve([(0, 70), (2400, 47.5)]),
                    beat: curve([(0, 10.0), (600, 5.0), (1800, 1.5), (2400, 1.5)]),
                    volume: curve([(0, 0.40), (2100, 0.35), (2400, 0.15)])
                ),
            ]
        )
    }

    private static func powerNap30() -> Preset {
        makePreset(
            index: 9,
            name: "Power Nap 30",
            category: .sleep,
            summary: "20-minute dip from 12 -> 4.5 Hz Theta followed by an invigorating rise to 14 Hz.",
            durationSec: 1800,
            masterGain: 0.82,
            fadeInSec: 15,
            fadeOutSec: 15,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: curve([(0, 0.22), (1200, 0.24), (1800, 0.10)]),
                smoothnessCurve: curve([(0, 0.65), (900, 0.90), (1800, 0.45)]),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 9,
                    voiceIndex: 1,
                    name: "Nap Dip & Wake",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: curve([(0, 180), (1200, 130), (1800, 210)]),
                    beat: curve([(0, 12.0), (300, 4.5), (1200, 4.5), (1800, 14.0)]),
                    volume: constant(0.75)
                ),
                makeVoice(
                    presetIndex: 9,
                    voiceIndex: 2,
                    name: "Wake Iso Cue",
                    mode: .isochronic,
                    waveform: .sine,
                    isochronicSoftness: 0.75,
                    isochronicDutyCycle: 0.5,
                    carrier: curve([(0, 270), (1200, 195), (1800, 315)]),
                    beat: curve([(0, 12.0), (300, 4.5), (1200, 4.5), (1800, 14.0)]),
                    volume: curve([(0, 0.20), (1200, 0.15), (1620, 0.35), (1800, 0.50)])
                ),
            ]
        )
    }

    private static func lucidDreamGateway() -> Preset {
        makePreset(
            index: 10,
            name: "Lucid Dream Gateway",
            category: .sleep,
            summary: "Theta 5.5 Hz plateau with periodic 6.5 Hz isochronic cues and pulsing brown noise.",
            durationSec: 2400,
            masterGain: 0.80,
            fadeInSec: 25,
            fadeOutSec: 30,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.24),
                smoothnessCurve: constant(1.0),
                pulseEnabled: true,
                pulseDepth: 0.35,
                pulseSourceVoiceIndex: 0
            ),
            voices: [
                makeVoice(
                    presetIndex: 10,
                    voiceIndex: 1,
                    name: "Theta Dream Plateau",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: curve([(0, 160), (600, 136), (2400, 136)]),
                    beat: curve([(0, 10.0), (600, 5.5), (2400, 5.5)]),
                    volume: constant(0.72)
                ),
                makeVoice(
                    presetIndex: 10,
                    voiceIndex: 2,
                    name: "Lucid Iso Cue",
                    mode: .isochronic,
                    waveform: .sine,
                    isochronicSoftness: 0.85,
                    isochronicDutyCycle: 0.45,
                    carrier: constant(272),
                    beat: constant(6.5),
                    volume: curve([
                        (0, 0.0), (600, 0.0), (750, 0.32), (1050, 0.0),
                        (1350, 0.35), (1650, 0.0), (1950, 0.32), (2250, 0.0), (2400, 0.0)
                    ])
                ),
                makeVoice(
                    presetIndex: 10,
                    voiceIndex: 3,
                    name: "Sub-Theta Pad",
                    mode: .monaural,
                    waveform: .sineSquared,
                    carrier: constant(68),
                    beat: constant(5.5),
                    volume: constant(0.35)
                ),
            ]
        )
    }

    private static func insomniaDrift() -> Preset {
        makePreset(
            index: 11,
            name: "Insomnia Drift",
            category: .sleep,
            summary: "45-minute deep Delta 2.5 -> 1.2 Hz drift with deep brown noise and 5-minute gradual fade-out.",
            durationSec: 2700,
            masterGain: 0.78,
            fadeInSec: 30,
            fadeOutSec: 120,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: curve([(0, 0.32), (2400, 0.30), (2700, 0.0)]),
                smoothnessCurve: constant(1.0),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 11,
                    voiceIndex: 1,
                    name: "Deep Delta Drift",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: curve([(0, 110), (1350, 95), (2700, 85)]),
                    beat: curve([(0, 2.5), (900, 1.8), (1800, 1.2), (2700, 1.2)]),
                    volume: curve([(0, 0.72), (2400, 0.65), (2700, 0.0)])
                ),
                makeVoice(
                    presetIndex: 11,
                    voiceIndex: 2,
                    name: "Ultra-Low Drone",
                    mode: .monaural,
                    waveform: .sine,
                    carrier: curve([(0, 55), (2700, 42.5)]),
                    beat: curve([(0, 2.5), (1800, 1.2), (2700, 1.2)]),
                    volume: curve([(0, 0.35), (2400, 0.30), (2700, 0.0)])
                ),
            ]
        )
    }

    private static func zenThetaStillness() -> Preset {
        makePreset(
            index: 12,
            name: "Zen Theta Stillness",
            category: .meditation,
            summary: "Smooth 8 -> 4.5 Hz Sine² meditation at 136.1 Hz with minimal pink-brown noise.",
            durationSec: 2100,
            masterGain: 0.80,
            fadeInSec: 20,
            fadeOutSec: 30,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.08),
                smoothnessCurve: constant(0.75),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 12,
                    voiceIndex: 1,
                    name: "Zen Theta Core",
                    mode: .binaural,
                    waveform: .sineSquared,
                    carrier: constant(136.1),
                    beat: curve([(0, 8.0), (900, 5.5), (1800, 4.5), (2100, 4.5)]),
                    volume: constant(0.72)
                ),
                makeVoice(
                    presetIndex: 12,
                    voiceIndex: 2,
                    name: "Harmonic Stillness",
                    mode: .monaural,
                    waveform: .sineSquared,
                    carrier: constant(272.2),
                    beat: curve([(0, 8.0), (1800, 4.5), (2100, 4.5)]),
                    volume: constant(0.32)
                ),
            ]
        )
    }

    private static func schumannEarth() -> Preset {
        makePreset(
            index: 13,
            name: "Schumann Earth 7.83 Hz",
            category: .meditation,
            summary: "Fundamental 7.83 Hz resonance with tracked 15.66 Hz isochronic overtone and earth drone.",
            durationSec: 2100,
            masterGain: 0.84,
            fadeInSec: 20,
            fadeOutSec: 25,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.15),
                smoothnessCurve: constant(0.85),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 13,
                    voiceIndex: 1,
                    name: "Schumann Fundamental",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(156.6),
                    beat: constant(7.83),
                    volume: constant(0.75)
                ),
                makeVoice(
                    presetIndex: 13,
                    voiceIndex: 2,
                    name: "Schumann Overtone",
                    mode: .isochronic,
                    waveform: .sine,
                    isochronicSoftness: 0.75,
                    isochronicDutyCycle: 0.5,
                    carrier: constant(313.2),
                    beat: constant(15.66),
                    volume: constant(0.32),
                    trackingRule: VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .beat, ratio: 2.0, offset: 0.0)
                ),
                makeVoice(
                    presetIndex: 13,
                    voiceIndex: 3,
                    name: "Earth Drone",
                    mode: .monaural,
                    waveform: .sineSquared,
                    carrier: constant(78.3),
                    beat: constant(7.83),
                    volume: constant(0.40)
                ),
            ]
        )
    }

    private static func deepBreathSync() -> Preset {
        let duration = 1800.0
        return makePreset(
            index: 14,
            name: "Deep Breath Sync",
            category: .meditation,
            summary: "7 Hz Theta resonance with slow breathing volume swells and synchronized pulsing noise.",
            durationSec: duration,
            masterGain: 0.82,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: breathModulatedCurve(durationSec: duration, cycleSec: 12.0, minValue: 0.12, maxValue: 0.28),
                smoothnessCurve: constant(0.80),
                pulseEnabled: true,
                pulseDepth: 0.30,
                pulseSourceVoiceIndex: 0
            ),
            voices: [
                makeVoice(
                    presetIndex: 14,
                    voiceIndex: 1,
                    name: "Theta Breath Core",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(174),
                    beat: constant(7.0),
                    volume: breathModulatedCurve(durationSec: duration, cycleSec: 12.0, minValue: 0.45, maxValue: 0.80)
                ),
                makeVoice(
                    presetIndex: 14,
                    voiceIndex: 2,
                    name: "Harmonic Breath Pad",
                    mode: .monaural,
                    waveform: .sine,
                    carrier: constant(87),
                    beat: constant(7.0),
                    volume: breathModulatedCurve(durationSec: duration, cycleSec: 12.0, minValue: 0.25, maxValue: 0.45)
                ),
            ]
        )
    }

    private static func memoryRetention() -> Preset {
        makePreset(
            index: 15,
            name: "Memory Retention",
            category: .study,
            summary: "Alpha 10.5 Hz at 200 Hz paired with a tracked pure-fifth harmonic voice (300 Hz) and steady pink noise.",
            durationSec: 2100,
            masterGain: 0.85,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.18),
                smoothnessCurve: constant(0.5),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 15,
                    voiceIndex: 1,
                    name: "Alpha Recall Core",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(200),
                    beat: constant(10.5),
                    volume: constant(0.75)
                ),
                makeVoice(
                    presetIndex: 15,
                    voiceIndex: 2,
                    name: "Pure Fifth Harmonic",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(300),
                    beat: constant(10.5),
                    volume: constant(0.42),
                    trackingRule: VoiceTrackingRule(sourceVoiceIndex: 0, targetParameter: .carrier, ratio: 1.5, offset: 0.0)
                ),
            ]
        )
    }

    private static func creativeCrossover() -> Preset {
        let waveBeat = curve([
            (0, 8.5), (350, 6.5), (700, 8.5), (1050, 6.5), (1400, 8.5), (1750, 6.5), (2100, 8.5)
        ])
        return makePreset(
            index: 16,
            name: "Creative Crossover",
            category: .creative,
            summary: "Undulating Alpha 8.5 Hz / Theta 6.5 Hz oscillation across triangle and sine voices with light pink noise.",
            durationSec: 2100,
            masterGain: 0.84,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.14),
                smoothnessCurve: constant(0.5),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 16,
                    voiceIndex: 1,
                    name: "Alpha-Theta Wave",
                    mode: .binaural,
                    waveform: .triangle,
                    carrier: curve([(0, 196), (525, 174), (1050, 196), (1575, 174), (2100, 196)]),
                    beat: waveBeat,
                    volume: constant(0.70)
                ),
                makeVoice(
                    presetIndex: 16,
                    voiceIndex: 2,
                    name: "Creative Sine Blend",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(294),
                    beat: waveBeat,
                    volume: constant(0.42)
                ),
            ]
        )
    }

    private static func readingCompanion() -> Preset {
        makePreset(
            index: 17,
            name: "Reading Companion",
            category: .study,
            summary: "Speaker-friendly 12 Hz soft isochronic pulse (0.8 softness) with pink-to-brown background noise.",
            durationSec: 2400,
            masterGain: 0.85,
            fadeInSec: 15,
            fadeOutSec: 20,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.22),
                smoothnessCurve: curve([(0, 0.5), (2400, 0.95)]),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 17,
                    voiceIndex: 1,
                    name: "Isochronic Alpha Reading",
                    mode: .isochronic,
                    waveform: .sine,
                    isochronicSoftness: 0.8,
                    isochronicDutyCycle: 0.5,
                    carrier: constant(220),
                    beat: constant(12.0),
                    volume: constant(0.72)
                ),
            ]
        )
    }

    private static func problemSolvingSprint() -> Preset {
        makePreset(
            index: 18,
            name: "Problem Solving Sprint",
            category: .creative,
            summary: "Beta 16 Hz binaural drive with a mid-session 38 Hz isochronic Gamma accent (10-25 min) and pink noise.",
            durationSec: 1800,
            masterGain: 0.85,
            fadeInSec: 12,
            fadeOutSec: 15,
            noise: NoiseLayer(
                isEnabled: true,
                volumeCurve: constant(0.16),
                smoothnessCurve: constant(0.5),
                pulseEnabled: false,
                pulseDepth: 0.0,
                pulseSourceVoiceIndex: nil
            ),
            voices: [
                makeVoice(
                    presetIndex: 18,
                    voiceIndex: 1,
                    name: "Beta Sprint Core",
                    mode: .binaural,
                    waveform: .sine,
                    carrier: constant(220),
                    beat: constant(16.0),
                    volume: constant(0.74)
                ),
                makeVoice(
                    presetIndex: 18,
                    voiceIndex: 2,
                    name: "Mid-Sprint Gamma Accent",
                    mode: .isochronic,
                    waveform: .smoothSquare,
                    isochronicSoftness: 0.55,
                    isochronicDutyCycle: 0.45,
                    carrier: constant(440),
                    beat: constant(38.0),
                    volume: curve([(0, 0.0), (540, 0.0), (600, 0.34), (1500, 0.34), (1560, 0.0), (1800, 0.0)])
                ),
            ]
        )
    }
}
