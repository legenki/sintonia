# Sintonia iOS 27 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Sintonia — an App Store–ready native iOS 27 BrainWave Generator synthesizer with 10-voice real-time DSP, GarageBand-inspired tactile UI, 18 built-in 30–45 min presets, `.bwg` import, curve editor, and bit-identical WAV/M4A offline export.

**Architecture:** Four isolated modules: platform-independent `SynthCore` (lock-free real-time DSP) and `PresetKit` (models, validator, 18 presets, `.bwg` importer, store) in local Swift Package `Packages/SintoniaCore`, linked by an XcodeGen-generated iOS 27.2 app containing `AudioRuntime` (`AVAudioEngine`, `AVAudioSession`, `NowPlaying`, `SessionExporter`) and `StudioUI` (SwiftUI Liquid Glass + GarageBand tactile controls).

**Tech Stack:** Swift 6.4 (Swift 6 language mode), SwiftUI (iOS 27.2 SDK / Liquid Glass), AVFoundation / Core Audio (`AVAudioEngine`, `AVAudioSourceNode`, `AVAudioFile`), MediaPlayer, Swift Testing (`Testing`), XcodeGen 2.48. Zero external third-party packages.

**Spec:** `docs/superpowers/specs/2026-11-22-sintonia-ios-design.md`

---

## Global Constraints

- Minimum deployment target: iOS 27.2 (Xcode 27.2), Swift 6 language mode (`SWIFT_STRICT_CONCURRENCY = complete`).
- Zero external third-party packages (Foundation, Darwin, AVFoundation, MediaPlayer, SwiftUI, UIKit, Synchronization only).
- 100% offline: no network calls, accounts, analytics, ads, or iCloud sync.
- Real-time audio callback (`AVAudioSourceNode` / `SynthRenderer.render`) must perform zero heap allocations, zero Swift ARC retains/releases, and zero locks (`os_unfair_lock`, `DispatchSemaphore`, `NSLock`).
- Audio output safety: master limiter ceiling `-0.5 dBFS` (`0.944`), hard clamp `[-1.0, 1.0]`, NaN/Inf sanitization, 15 ms exponential parameter & transport smoothing.
- Offline export: 48 kHz stereo via the identical `SynthRenderer`, supporting 24-bit Linear PCM `.wav` and 256 kbps AAC-LC `.m4a`.
- Localization: complete English (`en`) and Russian (`ru`) strings in `App/Resources/Localizable.xcstrings`.
- App Store Guideline 1.4.1: non-medical wellness framing only; explicit wellness & safe-volume disclaimer in About screen.
- Explicitly out of scope for v1: nature-sound audio loops/external WAV backgrounds, visual strobe/screen flicker, AUv3 Audio Unit extension.

## Review Focus

1. Duplicate, unsorted, negative timestamps or NaN/Inf values in `EnvelopeCurve` or imported `.bwg` data → sanitized/clamped deterministically with zero divide-by-zero (`t_{i+1} == t_i`) and finite output (pinned in Task 1 & Task 4).
2. Cyclic (`Voice 0 → Voice 1 → Voice 0`), self-referential, or out-of-range `VoiceTrackingRule` references → flagged by `PresetValidator` and safely skipped without infinite recursion in `SnapshotCompiler` (pinned in Task 3).
3. Live mid-playback preset hot-swap, voice count drop (10 → 1), or rapid seek → `SynthRenderer` applies a 15 ms click-free cross-ramp, never reads stale voice slots, and stays strictly finite (pinned in Task 2).
4. Headphone unplugging during binaural playback or mid-export cancellation → `AudioRoutePolicy` auto-pauses binaural sessions on `.oldDeviceUnavailable` so tones never blast through the phone speaker; `SessionExporter` deletes partial temp files on `CancellationError` (pinned in Task 6).
5. Editing a built-in preset or importing a legacy `.bwg` referencing Windows `.wav` / visual strobe → editing a built-in preset forks into a `Custom` copy leaving the built-in catalog immutable; legacy `.bwg` imports all synthesis voices cleanly and returns a populated `ImportReport` (pinned in Task 4).

---

## File Map

- `Packages/SintoniaCore/Package.swift` — SwiftPM manifest for `SynthCore`, `PresetKit`, `SynthCoreTests`, `PresetKitTests`.
- `Packages/SintoniaCore/Sources/SynthCore/SynthTypes.swift` — `EntrainmentMode`, `Waveform`, `CurveInterpolation`, `CurvePoint`, `CompiledCurve`.
- `Packages/SintoniaCore/Sources/SynthCore/Waveforms.swift` — 5 BWGen waveforms (`WaveformOscillator`) + `IsochronicEnvelope`.
- `Packages/SintoniaCore/Sources/SynthCore/StereoNoiseGenerator.swift` — `Xoshiro256StarStar`, `StereoNoiseGenerator` (`white → pink → brown`).
- `Packages/SintoniaCore/Sources/SynthCore/SynthSnapshot.swift` — `BrainwaveBand`, `VoiceSnapshot`, `NoiseSnapshot`, `SynthSnapshot`, `LiveOverrides`, lock-free triple-buffered `SnapshotChannel`.
- `Packages/SintoniaCore/Sources/SynthCore/TelemetryRingBuffer.swift` — Lock-free SPSC 1024-frame stereo ring buffer + RMS/peak snapshot.
- `Packages/SintoniaCore/Sources/SynthCore/SynthRenderer.swift` — Real-time safe multi-voice + noise DSP renderer and soft-knee limiter.
- `Packages/SintoniaCore/Sources/PresetKit/PresetModels.swift` — `Preset`, `PresetCategory`, `OutputHint`, `NoiseLayer`, `Voice`, `VoiceTrackingRule`, `TrackedParameter`, `EnvelopeCurve`.
- `Packages/SintoniaCore/Sources/PresetKit/PresetValidator.swift` — Range, voice count, and acyclic tracking validation (`PresetValidator`).
- `Packages/SintoniaCore/Sources/PresetKit/SnapshotCompiler.swift` — Resolves tracking rules and compiles `Preset` into `SynthSnapshot`.
- `Packages/SintoniaCore/Sources/PresetKit/PresetCodec.swift` — Versioned `.sintonia` JSON encoder/decoder.
- `Packages/SintoniaCore/Sources/PresetKit/PresetCatalog.swift` — 18 original 30–45 min built-in presets across 5 categories.
- `Packages/SintoniaCore/Sources/PresetKit/BWGImporter.swift` — `.bwg` parser with `ImportReport` and `BWGImportError`.
- `Packages/SintoniaCore/Sources/PresetKit/PresetStore.swift` — Disk persistence for custom presets and fork-on-edit for built-ins.
- `project.yml` — XcodeGen specification generating `Sintonia.xcodeproj`.
- `App/Info.plist` — Background audio mode, portrait/landscape orientations, `.bwg`/`.sintonia` UTI registrations.
- `App/Resources/Localizable.xcstrings` — Full EN + RU string catalog.
- `App/Resources/Assets.xcassets/...` — App icon placeholder set and theme asset catalog.
- `App/Sources/AudioRuntime/AudioRoutePolicy.swift` — Pure route-change decision policy.
- `App/Sources/AudioRuntime/AudioEngineController.swift` — `AVAudioEngine` + `AVAudioSourceNode`, `AVAudioSession`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`.
- `App/Sources/AudioRuntime/SessionExporter.swift` — Background 48 kHz WAV/M4A exporter using `SynthRenderer`.
- `App/Sources/StudioUI/Components/*.swift` — `StudioTheme`, `StudioKnob`, `StudioFader`, `LEDMeterView`, `OscilloscopeView`, `WaveformPicker`, `ModePicker`.
- `App/Sources/StudioUI/Player/*.swift` — `PlayerView`, `MiniTimelineScrubber`, `ExportSheetView`, `AboutSheetView`.
- `App/Sources/StudioUI/Studio/*.swift` — `StudioRackView`, `VoiceInspectorView`, `NoiseInspectorView`, `CurveEditorCanvas`, `CurveEditorView`.
- `App/Sources/StudioUI/Library/*.swift` — `LibraryView`, `PresetSparklineView`, `ImportResultAlert`.
- `App/Sources/StudioUI/SintoniaApp.swift` — `@main` entry point, dependency wiring, `.onOpenURL` import handling.

---

### Task 1: `SintoniaCore` Package + `SynthCore` Curves, Waveforms & Stereo Noise

**Files:**
- Create: `Packages/SintoniaCore/Package.swift`
- Create: `Packages/SintoniaCore/Sources/SynthCore/SynthTypes.swift`
- Create: `Packages/SintoniaCore/Sources/SynthCore/Waveforms.swift`
- Create: `Packages/SintoniaCore/Sources/SynthCore/StereoNoiseGenerator.swift`
- Test: `Packages/SintoniaCore/Tests/SynthCoreTests/CurveWaveformNoiseTests.swift`

**Interfaces:**
- Consumes: `Foundation`, `Darwin`
- Produces:
  - `public enum EntrainmentMode: String, Codable, Sendable, CaseIterable` (`.binaural`, `.monaural`, `.isochronic`)
  - `public enum Waveform: String, Codable, Sendable, CaseIterable` (`.sine`, `.sineSquared`, `.triangle`, `.square`, `.smoothSquare`)
  - `public enum CurveInterpolation: String, Codable, Sendable, CaseIterable` (`.linear`, `.smoothStep`)
  - `public struct CurvePoint: Codable, Sendable, Equatable` (`timeSec: Double`, `value: Double`)
  - `public struct CompiledCurve: Sendable, Equatable` (`init(points: [CurvePoint], interpolation: CurveInterpolation)`, `func evaluate(at timeSec: Double) -> Double`)
  - `public enum WaveformOscillator` (`static func sample(waveform: Waveform, phase: Double, phaseIncrement: Double) -> Double`)
  - `public enum IsochronicEnvelope` (`static func sample(phase: Double, dutyCycle: Double, softness: Double) -> Double`)
  - `public struct Xoshiro256StarStar: Sendable` (`init(seed: UInt64)`, `mutating func nextUnitDouble() -> Double`)
  - `public struct StereoNoiseGenerator: Sendable` (`init(leftSeed: UInt64, rightSeed: UInt64)`, `mutating func nextSample(smoothness: Double) -> (left: Double, right: Double)`)

- [ ] **Step 1: Scaffold `Packages/SintoniaCore/Package.swift` and write failing `SynthCoreTests`**

Create `Packages/SintoniaCore/Package.swift` (`// swift-tools-version: 6.2`, platforms `[.iOS(.v18), .macOS(.v15)]`, targets `SynthCore`, `PresetKit`, `SynthCoreTests`, `PresetKitTests`, Swift 6 strict concurrency). Add `Tests/SynthCoreTests/CurveWaveformNoiseTests.swift`:

```swift
import Testing
@testable import SynthCore

@Suite("Curves, Waveforms, and Stereo Noise")
struct CurveWaveformNoiseTests {
    @Test func curveInterpolationAndEdgeClamping() {
        let linear = CompiledCurve(
            points: [CurvePoint(timeSec: 10, value: 100), CurvePoint(timeSec: 20, value: 200)],
            interpolation: .linear
        )
        #expect(linear.evaluate(at: 0) == 100)
        #expect(linear.evaluate(at: 15) == 150)
        #expect(linear.evaluate(at: 30) == 200)

        let smooth = CompiledCurve(
            points: [CurvePoint(timeSec: 0, value: 0), CurvePoint(timeSec: 10, value: 100)],
            interpolation: .smoothStep
        )
        #expect(abs(smooth.evaluate(at: 2.5) - 15.625) < 1e-6)
        #expect(smooth.evaluate(at: 5.0) == 50)
    }

    @Test func curveSanitizesDuplicateUnsortedAndNaNPoints() {
        let dirty = CompiledCurve(
            points: [
                CurvePoint(timeSec: 20, value: 200),
                CurvePoint(timeSec: .nan, value: 999),
                CurvePoint(timeSec: -5, value: 50),
                CurvePoint(timeSec: 10, value: 120),
                CurvePoint(timeSec: 10, value: 140),
                CurvePoint(timeSec: 15, value: .infinity),
            ],
            interpolation: .smoothStep
        )
        for t in stride(from: -10.0, through: 30.0, by: 0.5) {
            let v = dirty.evaluate(at: t)
            #expect(v.isFinite)
        }
        #expect(dirty.evaluate(at: 0) == 50)
        #expect(dirty.evaluate(at: 25) == 200)
    }

    @Test func allFiveWaveformsRangeAndSineSquaredZeroDC() {
        let steps = 48_000
        let inc = 200.0 / 48_000.0
        for waveform in Waveform.allCases {
            var sum = 0.0
            for i in 0..<steps {
                let phase = (Double(i) * inc).truncatingRemainder(dividingBy: 1.0)
                let s = WaveformOscillator.sample(waveform: waveform, phase: phase, phaseIncrement: inc)
                #expect(s.isFinite && abs(s) <= 1.001)
                sum += s
            }
            if waveform == .sineSquared {
                #expect(abs(sum / Double(steps)) < 1e-3)
            }
        }
    }

    @Test func isochronicEnvelopeSmoothEdges() {
        var prev = IsochronicEnvelope.sample(phase: 0.0, dutyCycle: 0.5, softness: 0.5)
        var minVal = prev
        var maxVal = prev
        for i in 1...1000 {
            let v = IsochronicEnvelope.sample(phase: Double(i) / 1000.0, dutyCycle: 0.5, softness: 0.5)
            #expect(v >= 0.0 && v <= 1.0)
            #expect(abs(v - prev) < 0.02)
            prev = v
            minVal = min(minVal, v)
            maxVal = max(maxVal, v)
        }
        #expect(minVal < 0.01 && maxVal > 0.99)
    }

    @Test func stereoNoiseRMSContinuityAndDecorrelation() {
        var rmsValues: [Double] = []
        for smoothness in [0.0, 0.25, 0.5, 0.75, 1.0] {
            var gen = StereoNoiseGenerator(leftSeed: 111, rightSeed: 222)
            var sumSqL = 0.0
            var dotLR = 0.0
            var sumSqR = 0.0
            let n = 48_000
            for _ in 0..<n {
                let (l, r) = gen.nextSample(smoothness: smoothness)
                #expect(l.isFinite && r.isFinite)
                sumSqL += l * l
                sumSqR += r * r
                dotLR += l * r
            }
            let rmsL = (sumSqL / Double(n)).squareRoot()
            rmsValues.append(rmsL)
            let corr = abs(dotLR / (sumSqL * sumSqR).squareRoot())
            #expect(corr < 0.05)
        }
        for i in 1..<rmsValues.count {
            let ratio = rmsValues[i] / rmsValues[i - 1]
            #expect(ratio > 0.65 && ratio < 1.55)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/SintoniaCore --filter CurveWaveformNoiseTests`
Expected: FAIL because `SynthTypes.swift`, `Waveforms.swift`, and `StereoNoiseGenerator.swift` do not exist.

- [ ] **Step 3: Implement `SynthTypes.swift`, `Waveforms.swift`, and `StereoNoiseGenerator.swift`**

- `SynthTypes.swift`: define `EntrainmentMode`, `Waveform`, `CurveInterpolation`, `CurvePoint`, and `CompiledCurve`. In `CompiledCurve.init`, filter out non-finite points, clamp `timeSec = max(0, p.timeSec)`, sort ascending by `timeSec`, collapse consecutive points with identical `timeSec` (keeping the last), fallback to `[CurvePoint(timeSec: 0, value: 0)]` if empty. `evaluate(at:)` clamps below first / above last and uses binary search + `linear` or Hermite `u*u*(3 - 2*u)` (`smoothStep`).
- `Waveforms.swift`: implement `WaveformOscillator.sample(waveform:phase:phaseIncrement:)` with `sine` (`sin(2πφ)`), `sineSquared` (`2*sin²(πφ) - 1`, DC-free), `triangle` (`1 - 4*abs((φ - 0.25).rounded() - (φ - 0.25))` or symmetric `1 - 4*|round(φ) - φ|`), `square` (with `polyBLEP` at `φ = 0` and `φ = 0.5`), `smoothSquare` (`tanh(3.5 * sin(2πφ)) / tanh(3.5)`). Implement `IsochronicEnvelope.sample(phase:dutyCycle:softness:)` as a raised-cosine trapezoidal pulse in `[0, 1]`.
- `StereoNoiseGenerator.swift`: implement `Xoshiro256StarStar` (SplitMix64 seeding + 256-bit state), Paul Kellet's 6-stage pink filter, leaky-integrator brown filter (`b = 0.996 * b + 0.04 * w`), smooth crossfade `white (0.0) → pink (0.5) → brown (1.0)` with empirically calibrated RMS gain factors (`whiteGain ≈ 0.22`, `pinkGain ≈ 0.28`, `brownGain ≈ 0.55`) so RMS remains uniform across `[0, 1]`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/SintoniaCore --filter CurveWaveformNoiseTests`
Expected: PASS (all 5 tests pass).

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add Packages/SintoniaCore
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(SynthCore): add curves, 5 BWGen waveforms, isochronic envelope, and stereo colored noise"
```

---

### Task 2: `SynthCore` Multi-Voice `SynthRenderer`, Lock-Free `SynthSnapshot` & `TelemetryRingBuffer`

**Files:**
- Create: `Packages/SintoniaCore/Sources/SynthCore/SynthSnapshot.swift`
- Create: `Packages/SintoniaCore/Sources/SynthCore/TelemetryRingBuffer.swift`
- Create: `Packages/SintoniaCore/Sources/SynthCore/SynthRenderer.swift`
- Test: `Packages/SintoniaCore/Tests/SynthCoreTests/SynthRendererTests.swift`

**Interfaces:**
- Consumes: `SynthTypes.swift`, `Waveforms.swift`, `StereoNoiseGenerator.swift`, `Synchronization` (`Atomic`)
- Produces:
  - `public enum BrainwaveBand: String, Sendable, CaseIterable` (`delta`, `theta`, `alpha`, `beta`, `gamma`, `static func from(frequencyHz: Double) -> BrainwaveBand`)
  - `public struct VoiceSnapshot: Sendable, Equatable`
  - `public struct NoiseSnapshot: Sendable, Equatable`
  - `public struct SynthSnapshot: Sendable, Equatable` (up to 10 voices)
  - `public struct LiveOverrides: Sendable, Equatable` (`masterGain: Double`, `tonesGain: Double`, `noiseGain: Double`, `noiseSmoothnessOffset: Double`)
  - `public struct TelemetryFrame: Sendable` (`leftSamples: [Float]`, `rightSamples: [Float]`, `rmsL: Float`, `rmsR: Float`, `peakL: Float`, `peakR: Float`)
  - `public final class TelemetryRingBuffer: @unchecked Sendable` (`init()`, `func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int)`, `func readLatest(into frame: inout TelemetryFrame)`)
  - `public final class SynthRenderer: @unchecked Sendable` (`init(sampleRate: Double = 48_000, snapshot: SynthSnapshot, telemetry: TelemetryRingBuffer? = nil)`, `func render(intoLeft: UnsafeMutablePointer<Float>, intoRight: UnsafeMutablePointer<Float>, frameCount: Int)`, `func seek(to timeSec: Double)`, `func setPlaying(_ playing: Bool)`, `func applySnapshot(_ snapshot: SynthSnapshot)`, `func updateOverrides(_ overrides: LiveOverrides)`, `func currentTimeSeconds() -> Double`, `func dominantBeatHz(at timeSec: Double) -> Double`)

- [ ] **Step 1: Write failing `SynthRendererTests`**

Create `Packages/SintoniaCore/Tests/SynthCoreTests/SynthRendererTests.swift`:

```swift
import Foundation
import Testing
@testable import SynthCore

@Suite("SynthRenderer & Telemetry")
struct SynthRendererTests {
    private func measureFrequencyZeroCrossings(samples: [Float], sampleRate: Double) -> Double {
        var crossings: [Double] = []
        for i in 1..<samples.count {
            let a = Double(samples[i - 1]), b = Double(samples[i])
            if a <= 0 && b > 0 {
                let frac = -a / (b - a)
                crossings.append(Double(i - 1) + frac)
            }
        }
        guard crossings.count >= 2 else { return 0 }
        let totalSamples = crossings.last! - crossings.first!
        let cycles = Double(crossings.count - 1)
        return (cycles * sampleRate) / totalSamples
    }

    @Test func binauralCarrierAndBeatFrequencyAccuracy() {
        for (carrier, beat) in [(200.0, 4.0), (200.0, 10.0), (440.0, 40.0)] {
            let voice = VoiceSnapshot(
                id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
                mode: .binaural, waveform: .sine,
                isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
                carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: carrier)], interpolation: .linear),
                beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: beat)], interpolation: .linear),
                volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.8)], interpolation: .linear)
            )
            let snap = SynthSnapshot(
                durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0,
                noise: .disabled, voices: [voice]
            )
            let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
            renderer.setPlaying(true)
            let n = 48_000
            var left = [Float](repeating: 0, count: n)
            var right = [Float](repeating: 0, count: n)
            left.withUnsafeMutableBufferPointer { lPtr in
                right.withUnsafeMutableBufferPointer { rPtr in
                    renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: n)
                }
            }
            let steadyL = Array(left.dropFirst(4800))
            let steadyR = Array(right.dropFirst(4800))
            let fL = measureFrequencyZeroCrossings(samples: steadyL, sampleRate: 48_000)
            let fR = measureFrequencyZeroCrossings(samples: steadyR, sampleRate: 48_000)
            #expect(abs((fR - fL) - beat) < 0.05)
            #expect(abs(((fL + fR) * 0.5) - carrier) < 0.05)
        }
    }

    @Test func tenMaxedVoicesAndNoiseStayWithinLimiterCeiling() {
        let voices = (0..<10).map { idx in
            VoiceSnapshot(
                id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
                mode: .binaural, waveform: .square,
                isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
                carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 120 + Double(idx) * 35)], interpolation: .linear),
                beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
                volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 1.0)], interpolation: .linear)
            )
        }
        let noise = NoiseSnapshot(
            isEnabled: true,
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 1.0)], interpolation: .linear),
            smoothnessCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.5)], interpolation: .linear),
            pulseEnabled: true, pulseDepth: 0.5, pulseSourceVoiceIndex: 0
        )
        let snap = SynthSnapshot(durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: noise, voices: voices)
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
        renderer.setPlaying(true)
        var left = [Float](repeating: 0, count: 4096)
        var right = [Float](repeating: 0, count: 4096)
        left.withUnsafeMutableBufferPointer { lPtr in
            right.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 4096)
            }
        }
        for s in left + right {
            #expect(s.isFinite && abs(s) <= 1.0)
        }
    }

    @Test func soloAndMuteRoutingLogic() {
        let v0 = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .monaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 200)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 1.0)], interpolation: .linear)
        )
        let v1 = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: true,
            mode: .monaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 440)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 1.0)], interpolation: .linear)
        )
        let snap = SynthSnapshot(durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [v0, v1])
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
        renderer.setPlaying(true)
        var left = [Float](repeating: 0, count: 24_000)
        var right = [Float](repeating: 0, count: 24_000)
        left.withUnsafeMutableBufferPointer { lPtr in
            right.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 24_000)
            }
        }
        let measured = measureFrequencyZeroCrossings(samples: Array(left.dropFirst(4800)), sampleRate: 48_000)
        #expect(abs(measured - 440.0) < 2.0)
    }

    @Test func deterministicRenderMatchesBitForBit() {
        let voice = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sineSquared, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 180), CurvePoint(timeSec: 2, value: 220)], interpolation: .smoothStep),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 12), CurvePoint(timeSec: 2, value: 8)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.7)], interpolation: .linear)
        )
        let noise = NoiseSnapshot(
            isEnabled: true,
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.3)], interpolation: .linear),
            smoothnessCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.5)], interpolation: .linear),
            pulseEnabled: false, pulseDepth: 0, pulseSourceVoiceIndex: nil
        )
        let snap = SynthSnapshot(durationSec: 10, masterGain: 0.9, fadeInSec: 0.1, fadeOutSec: 0.1, noise: noise, voices: [voice])
        func runOnce() -> ([Float], [Float]) {
            let r = SynthRenderer(sampleRate: 48_000, snapshot: snap)
            r.setPlaying(true)
            var l = [Float](repeating: 0, count: 4096)
            var rBuf = [Float](repeating: 0, count: 4096)
            l.withUnsafeMutableBufferPointer { lPtr in
                rBuf.withUnsafeMutableBufferPointer { rPtr in
                    r.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 4096)
                }
            }
            return (l, rBuf)
        }
        let a = runOnce(), b = runOnce()
        #expect(a.0 == b.0 && a.1 == b.1)
    }

    @Test func hotSwapAndSeekAreClickFreeAndSafe() {
        let tenVoices = (0..<10).map { i in
            VoiceSnapshot(
                id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
                mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
                carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 150 + Double(i) * 20)], interpolation: .linear),
                beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
                volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.8)], interpolation: .linear)
            )
        }
        let oneVoice = [tenVoices[0]]
        let snap10 = SynthSnapshot(durationSec: 120, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: tenVoices)
        let snap1 = SynthSnapshot(durationSec: 120, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: oneVoice)
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap10)
        renderer.setPlaying(true)
        var l = [Float](repeating: 0, count: 2048)
        var r = [Float](repeating: 0, count: 2048)
        l.withUnsafeMutableBufferPointer { lPtr in
            r.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 2048)
                renderer.applySnapshot(snap1)
                renderer.seek(to: 45.0)
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 2048)
            }
        }
        for s in l + r { #expect(s.isFinite && abs(s) <= 1.0) }
        #expect(renderer.currentTimeSeconds() > 45.0)
    }

    @Test func telemetryRingBufferCapturesAudioAndPeaks() {
        let telemetry = TelemetryRingBuffer()
        let voice = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 220)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.8)], interpolation: .linear)
        )
        let snap = SynthSnapshot(durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [voice])
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap, telemetry: telemetry)
        renderer.setPlaying(true)
        var l = [Float](repeating: 0, count: 1024)
        var r = [Float](repeating: 0, count: 1024)
        l.withUnsafeMutableBufferPointer { lPtr in
            r.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 1024)
            }
        }
        var frame = TelemetryFrame()
        telemetry.readLatest(into: &frame)
        #expect(frame.leftSamples.count == 1024 && frame.rightSamples.count == 1024)
        #expect(frame.rmsL > 0.1 && frame.peakL > 0.2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/SintoniaCore --filter SynthRendererTests`
Expected: FAIL because `SynthSnapshot`, `TelemetryRingBuffer`, and `SynthRenderer` do not exist.

- [ ] **Step 3: Implement `SynthSnapshot.swift`, `TelemetryRingBuffer.swift`, and `SynthRenderer.swift`**

- `SynthSnapshot.swift`: define `BrainwaveBand` (thresholds: `<4` delta, `<8` theta, `<13` alpha, `<30` beta, `>=30` gamma), `VoiceSnapshot`, `NoiseSnapshot`, `SynthSnapshot`, `LiveOverrides`, and a lock-free `SnapshotChannel` built on pre-allocated raw/POD buffer slots (fixed-size `FixedCurve` holding up to 64 `CurvePoint`s or 256-sample pre-evaluated lookup table + fixed 10-slot voice array) swapped via `Synchronization.Atomic<Int>` active/pending indices so the audio thread performs zero Swift ARC retains/releases and zero heap allocations.
- `TelemetryRingBuffer.swift`: 1024-frame SPSC ring buffer backed by pre-allocated `UnsafeMutablePointer<Float>` L/R buffers and `Atomic<Int>` write head + atomic UInt32-bitpacked RMS/Peak values so `push` on audio thread is allocation-free and `readLatest` copies out safely on the UI thread.
- `SynthRenderer.swift`: maintain `Double` phase accumulators (`phaseL`, `phaseR`, `modPhase` for 10 voice slots), `StereoNoiseGenerator`, smoothed `LiveOverrides` (`tau = 0.015` s), 15 ms transport/seek/swap cross-ramp, Solo/Mute filtering, `1 / sqrt(activeCount)` voice normalization, session `fadeInSec`/`fadeOutSec` envelope, `0.944 * tanh(x / 0.944)` soft-knee limiter + `clamp(-1, 1)` + NaN guard, and push to `TelemetryRingBuffer`. Note: clamp session time at `durationSec` and stop advancing once complete (emitting silence after fade-out).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/SintoniaCore --filter SynthRendererTests`
Expected: PASS (all 6 tests pass).

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add Packages/SintoniaCore
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(SynthCore): implement lock-free SynthRenderer, snapshots, limiter, and telemetry"
```

---

### Task 3: `PresetKit` Canonical Model, Validator, `SnapshotCompiler` & JSON Codec

**Files:**
- Create: `Packages/SintoniaCore/Sources/PresetKit/PresetModels.swift`
- Create: `Packages/SintoniaCore/Sources/PresetKit/PresetValidator.swift`
- Create: `Packages/SintoniaCore/Sources/PresetKit/SnapshotCompiler.swift`
- Create: `Packages/SintoniaCore/Sources/PresetKit/PresetCodec.swift`
- Test: `Packages/SintoniaCore/Tests/PresetKitTests/PresetModelTests.swift`

**Interfaces:**
- Consumes: `SynthCore` (`EntrainmentMode`, `Waveform`, `CurveInterpolation`, `CurvePoint`, `CompiledCurve`, `VoiceSnapshot`, `NoiseSnapshot`, `SynthSnapshot`)
- Produces:
  - `public enum PresetCategory: String, Codable, Sendable, CaseIterable` (`.focus`, `.relax`, `.sleep`, `.meditation`, `.study`, `.creative`, `.custom`)
  - `public enum OutputHint: String, Codable, Sendable` (`.headphones`, `.any`)
  - `public enum TrackedParameter: String, Codable, Sendable, CaseIterable` (`.carrier`, `.beat`)
  - `public struct VoiceTrackingRule: Codable, Sendable, Equatable` (`sourceVoiceIndex: Int`, `targetParameter: TrackedParameter`, `ratio: Double`, `offset: Double`)
  - `public struct EnvelopeCurve: Codable, Sendable, Equatable` (`points: [CurvePoint]`, `interpolation: CurveInterpolation`)
  - `public struct NoiseLayer: Codable, Sendable, Equatable`
  - `public struct Voice: Codable, Sendable, Equatable, Identifiable`
  - `public struct Preset: Codable, Sendable, Equatable, Identifiable`
  - `public enum PresetValidationError: Error, Equatable, Sendable`
  - `public enum PresetValidator` (`static func validate(_ preset: Preset) -> [PresetValidationError]`)
  - `public enum SnapshotCompiler` (`static func compile(_ preset: Preset) -> SynthSnapshot`)
  - `public enum PresetCodec` (`static func encode(_ preset: Preset) throws -> Data`, `static func decode(_ data: Data) throws -> Preset`)

- [ ] **Step 1: Write failing `PresetModelTests`**

Create `Packages/SintoniaCore/Tests/PresetKitTests/PresetModelTests.swift`:

```swift
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
        let preset = samplePreset()
        let data = try PresetCodec.encode(preset)
        let decoded = try PresetCodec.decode(data)
        #expect(decoded == preset)
    }

    @Test func validatorDetectsInvalidRangesAndVoiceCounts() {
        let emptyVoices = samplePreset(voices: [])
        #expect(PresetValidator.validate(emptyVoices).contains(.invalidVoiceCount))

        var tooShort = samplePreset()
        tooShort.durationSec = 30
        #expect(PresetValidator.validate(tooShort).contains(.invalidDuration))

        var badFreq = samplePreset()
        badFreq.voices[0].carrierCurve = EnvelopeCurve(points: [CurvePoint(timeSec: 0, value: 2500)], interpolation: .linear)
        #expect(PresetValidator.validate(badFreq).contains(.carrierOutOfRange(voiceIndex: 0)))
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
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/SintoniaCore --filter PresetModelTests`
Expected: FAIL because `PresetKit` files do not exist.

- [ ] **Step 3: Implement `PresetModels.swift`, `PresetValidator.swift`, `SnapshotCompiler.swift`, and `PresetCodec.swift`**

- `PresetModels.swift`: define all model structs/enums matching Spec Section 3.
- `PresetValidator.swift`: validate `durationSec` in `60...7200`, `voices.count` in `1...10`, `masterGain` in `0...1`, `fadeInSec`/`fadeOutSec` in `0...120`, carrier curve values in `40...1000`, beat curve values in `0.5...60`, volume/smoothness in `0...1`, `pan` in `-1...1`, `isochronicSoftness` in `0.05...1.0`, `isochronicDutyCycle` in `0.2...0.8`, and tracking rules (bounds check + cycle detection via DFS coloring).
- `SnapshotCompiler.swift`: compute topological order for valid tracking rules (falling back to voice's own curve on any cycle or out-of-range index), sample/combine source curves cleanly (`ratio * source(t) + offset`, clamped to `[40, 1000]` for carrier or `[0.5, 60]` for beat), and emit `SynthSnapshot`.
- `PresetCodec.swift`: encode/decode `PresetDocument(schemaVersion: 1, preset: preset)` with pretty-printed sorted-keys JSON.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/SintoniaCore --filter PresetModelTests`
Expected: PASS (all 4 tests pass).

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add Packages/SintoniaCore
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(PresetKit): add canonical models, validator, tracking compiler, and JSON codec"
```

---

### Task 4: `PresetKit` 18 Built-In Presets, `BWGImporter` (`.bwg` Parser) & `PresetStore`

**Files:**
- Create: `Packages/SintoniaCore/Sources/PresetKit/PresetCatalog.swift`
- Create: `Packages/SintoniaCore/Sources/PresetKit/BWGImporter.swift`
- Create: `Packages/SintoniaCore/Sources/PresetKit/PresetStore.swift`
- Test: `Packages/SintoniaCore/Tests/PresetKitTests/CatalogImporterStoreTests.swift`

**Interfaces:**
- Consumes: `PresetModels.swift`, `PresetValidator.swift`, `SnapshotCompiler.swift`, `PresetCodec.swift`, `SynthRenderer`
- Produces:
  - `public enum PresetCatalog` (`static let builtInPresets: [Preset]`)
  - `public enum BWGImportError: Error, Equatable, Sendable` (`.emptyFile`, `.invalidHeader`, `.corruptedStructure`, `.noValidVoices`)
  - `public enum SkippedLegacyFeature: String, Equatable, Sendable` (`.externalWavBackground`, `.visualStimulation`)
  - `public struct ImportReport: Equatable, Sendable` (`skippedFeatures: [SkippedLegacyFeature]`, `warnings: [String]`)
  - `public struct BWGImportResult: Equatable, Sendable` (`preset: Preset`, `report: ImportReport`)
  - `public enum BWGImporter` (`static func importPreset(from data: Data, fallbackName: String) throws -> BWGImportResult`)
  - `public final class PresetStore: @unchecked Sendable` (`init(storageDirectory: URL)`, `func allPresets() -> [Preset]`, `func saveCustom(_ preset: Preset) throws`, `func saveEdited(_ preset: Preset) throws -> Preset`, `func deleteCustom(id: UUID) throws`)

- [ ] **Step 1: Write failing `CatalogImporterStoreTests`**

Create `Packages/SintoniaCore/Tests/PresetKitTests/CatalogImporterStoreTests.swift`:

```swift
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
        #expect(result.preset.voices.count == 1)
        #expect(result.preset.voices[0].waveform == .sine)
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
    }

    @Test func bwgImporterRejectsInvalidAndEmptyFiles() {
        #expect(throws: BWGImportError.emptyFile) {
            _ = try BWGImporter.importPreset(from: Data(), fallbackName: "Empty")
        }
        #expect(throws: BWGImportError.invalidHeader) {
            _ = try BWGImporter.importPreset(from: Data("Not a BWG file".utf8), fallbackName: "Bad")
        }
    }

    @Test func presetStoreForksBuiltInOnEditLeavingBuiltInImmutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SintoniaStore-\(UUID().uuidString)")
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/SintoniaCore --filter CatalogImporterStoreTests`
Expected: FAIL because `PresetCatalog`, `BWGImporter`, and `PresetStore` do not exist.

- [ ] **Step 3: Implement `PresetCatalog.swift`, `BWGImporter.swift`, and `PresetStore.swift`**

- `PresetCatalog.swift`: author all 18 presets from Spec Section 6 (deterministic UUIDs, accurate durations `1800...2700`, categories `.focus`, `.relax`, `.sleep`, `.meditation`, `.study`, `.creative`, multi-phase curves, tracking rules on `Study Anchor`, `Schumann Earth 7.83 Hz`, `Memory Retention`, noise smoothness curves).
- `BWGImporter.swift`: validate non-empty data and `"BrainWave Generator File"` ASCII prefix; support both structured key-value / INI-style `.bwg` text blocks AND resilient heuristic extraction of voice/segment tokens in legacy binary `.bwg` payloads (extracting embedded ASCII parameter runs, duration, voices 1...10, waveforms `Sine/SineSquared/Triangle/Square/SmoothedSquare`, noise levels); detect `.wav` background file references and AudioStrobe/VisualStimulation flags to populate `ImportReport` without failing; clamp imported values into valid ranges and reject files yielding 0 valid voices with `.noValidVoices` / `.corruptedStructure`.
- `PresetStore.swift`: load `PresetCatalog.builtInPresets` + persisted `.sintonia` files from `storageDirectory`; `saveEdited(_:)` checks if `isBuiltIn` (or matches a built-in ID) and automatically generates a new `UUID`, sets `isBuiltIn = false`, `category = .custom`, and writes `<id>.sintonia` atomically.

- [ ] **Step 4: Run entire `SintoniaCore` test suite**

Run: `swift test --package-path Packages/SintoniaCore`
Expected: PASS (all tests in `SynthCoreTests` and `PresetKitTests` pass).

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add Packages/SintoniaCore
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(PresetKit): add 18 built-in presets, BWGImporter, and PresetStore"
```

---

### Task 5: XcodeGen App Skeleton (`project.yml`), `Info.plist`, Assets & EN/RU Localization

**Files:**
- Create: `project.yml`
- Create: `App/Info.plist`
- Create: `App/Resources/Localizable.xcstrings`
- Create: `App/Resources/Assets.xcassets/Contents.json`
- Create: `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `App/Sources/StudioUI/SintoniaApp.swift`

**Interfaces:**
- Consumes: `Packages/SintoniaCore` (`SynthCore`, `PresetKit`)
- Produces: Build-clean iOS 27.2 Xcode project `Sintonia.xcodeproj` with targets `Sintonia` and `SintoniaTests`.

- [ ] **Step 1: Create `project.yml` and `App/Info.plist`**

- `project.yml`: `Sintonia` iOS app target (`deploymentTarget: iOS: "27.2"`, `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, sources `App/Sources` and `App/Resources`, local package `Packages/SintoniaCore` linking `SynthCore` and `PresetKit`), plus `SintoniaTests` unit-test target (`App/Tests/AudioRuntimeTests`) hosted by `Sintonia` so `@testable import Sintonia` resolves cleanly.
- `App/Info.plist`: `UIBackgroundModes` (`audio`), `UISupportedInterfaceOrientations` (portrait + landscapeLeft + landscapeRight), `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` (`com.sintonia.preset` for `.sintonia`), `UTImportedTypeDeclarations` (`com.noromaa.bwg` for `.bwg`), `LSSupportsOpeningDocumentsInPlace = true`.

- [ ] **Step 2: Create `Assets.xcassets`, `Localizable.xcstrings` (EN + RU), and minimal `SintoniaApp.swift`**

- `Localizable.xcstrings`: include all UI strings for Player, Studio Rack, Curve Editor, Library, Export, Route warnings, Import errors, and the App Store Guideline 1.4.1 non-medical wellness & safe-volume disclaimer in both `en` and `ru`.
- `SintoniaApp.swift`: minimal `@main struct SintoniaApp: App` shell rendering a `NavigationStack` placeholder so the build succeeds cleanly.

- [ ] **Step 3: Generate Xcode project and build for iOS 27.2 Simulator**

Run:
```bash
cd /Users/andy/.gemini/antigravity/scratch/Sintonia
xcodegen generate
xcodebuild build -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add project.yml App Sintonia.xcodeproj
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "chore: scaffold XcodeGen iOS 27.2 project, Info.plist, and EN/RU localization"
```

---

### Task 6: `AudioRuntime` — `AudioEngineController`, Route/Interruption Policy, `NowPlaying` & `SessionExporter`

**Files:**
- Create: `App/Sources/AudioRuntime/AudioRoutePolicy.swift`
- Create: `App/Sources/AudioRuntime/AudioEngineController.swift`
- Create: `App/Sources/AudioRuntime/SessionExporter.swift`
- Create: `App/Tests/AudioRuntimeTests/AudioRuntimeTests.swift`

**Interfaces:**
- Consumes: `SynthCore`, `PresetKit`, `AVFoundation`, `MediaPlayer`
- Produces:
  - `public enum AudioOutputRoute: Sendable, Equatable` (`.headphones`, `.speaker`, `.other`)
  - `public enum AudioRoutePolicy` (`static func shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: Bool, presetHasActiveBinaural: Bool) -> Bool`, `static func classifyRoute(portTypes: [AVAudioSession.Port]) -> AudioOutputRoute`)
  - `@MainActor @Observable public final class AudioEngineController` (properties: `isPlaying`, `currentTime`, `duration`, `currentPreset`, `liveOverrides`, `outputRoute`, `showHeadphoneBanner`, `telemetryBuffer`; methods: `load(_:)`, `play()`, `pause()`, `togglePlayPause()`, `seek(to:)`, `skip(by:)`, `applyEditedPreset(_:)`, `updateOverrides(_:)`)
  - `public enum ExportFormat: String, CaseIterable, Sendable` (`.wav`, `.m4a`)
  - `public enum ExportError: Error, LocalizedError`
  - `public enum SessionExporter` (`static func export(preset: Preset, format: ExportFormat, sampleRate: Double = 48_000, onProgress: @Sendable (Double) -> Void) async throws -> URL`)

- [ ] **Step 1: Write failing `AudioRuntimeTests`**

Create `App/Tests/AudioRuntimeTests/AudioRuntimeTests.swift`:

```swift
import AVFoundation
import Testing
import PresetKit
import SynthCore
@testable import Sintonia

@Suite("AudioRuntime Policy and Exporter")
struct AudioRuntimeTests {
    @Test func audioRoutePolicyAutoPausesBinauralOnHeadphoneDisconnect() {
        #expect(AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: true, presetHasActiveBinaural: true))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: true, presetHasActiveBinaural: false))
        #expect(!AudioRoutePolicy.shouldAutoPauseOnRouteChange(reasonIsOldDeviceUnavailable: false, presetHasActiveBinaural: true))
    }

    @Test func sessionExporterProducesValidWavAndM4AWithExactDuration() async throws {
        var preset = PresetCatalog.builtInPresets[0]
        preset.durationSec = 2.0

        let wavURL = try await SessionExporter.export(preset: preset, format: .wav, sampleRate: 48_000) { _ in }
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let wavFile = try AVAudioFile(forReading: wavURL)
        #expect(wavFile.processingFormat.sampleRate == 48_000)
        #expect(wavFile.processingFormat.channelCount == 2)
        #expect(abs((Double(wavFile.length) / 48_000.0) - 2.0) < 0.05)

        let m4aURL = try await SessionExporter.export(preset: preset, format: .m4a, sampleRate: 48_000) { _ in }
        defer { try? FileManager.default.removeItem(at: m4aURL) }
        let m4aFile = try AVAudioFile(forReading: m4aURL)
        #expect(m4aFile.processingFormat.channelCount == 2)
        #expect(abs((Double(m4aFile.length) / m4aFile.processingFormat.sampleRate) - 2.0) < 0.15)
    }

    @Test func sessionExporterCleansUpTempFileOnCancellation() async throws {
        var preset = PresetCatalog.builtInPresets[0]
        preset.durationSec = 1800.0
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])

        let task = Task {
            try await SessionExporter.export(preset: preset, format: .wav, sampleRate: 48_000) { _ in }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        let leftoverSintoniaFiles = after.subtracting(before).filter { $0.contains("Sintonia-") }
        #expect(leftoverSintoniaFiles.isEmpty)
    }
}
```

- [ ] **Step 2: Implement `AudioRoutePolicy.swift`, `AudioEngineController.swift`, and `SessionExporter.swift`**

- `AudioRoutePolicy.swift`: map `AVAudioSession.Port` values (`.headphones`, `.bluetoothA2DP`, `.bluetoothHFP`, `.bluetoothLE`, `.usbAudio` → `.headphones`; `.builtInSpeaker` → `.speaker`; else `.other`) and implement `shouldAutoPauseOnRouteChange`.
- `AudioEngineController.swift`: manage `AVAudioEngine` + `AVAudioSourceNode` (non-interleaved stereo 48 kHz Float32 calling `SynthRenderer.render`), `AVAudioSession` (`.playback` category), interruption notifications (fade/pause on `.began`, conditional resume on `.ended` with `.shouldResume`), route change notifications using `AudioRoutePolicy` (setting `showHeadphoneBanner = true` on auto-pause), `MPNowPlayingInfoCenter` updates, `MPRemoteCommandCenter` play/pause/skip/scrub handlers, and a display-refresh polling timer syncing `currentTime` + `isPlaying` to SwiftUI.
- `SessionExporter.swift`: render `preset` in 4096-frame blocks via an isolated `SynthRenderer` on a background detached task; write `.wav` (24-bit Linear PCM `AVAudioFile`) or `.m4a` (`kAudioFormatMPEG4AAC`, 256 kbps `AVAudioFile`); check `Task.isCancelled` on every chunk; delete temporary file in `catch`/cancellation paths before rethrowing.

- [ ] **Step 3: Build & test `AudioRuntimeTests`**

Run:
```bash
cd /Users/andy/.gemini/antigravity/scratch/Sintonia
xcodebuild build-for-testing -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
```
Note: Also run `xcodebuild test` if Simulator services are active on the host, or verify via a dedicated macOS `swift test` target / simulator runtime check.
Expected: `** TEST BUILD SUCCEEDED **` (and tests pass).

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/AudioRuntime App/Tests/AudioRuntimeTests
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(AudioRuntime): add AVAudioEngine controller, route policy, NowPlaying, and WAV/M4A exporter"
```

---

### Task 7: `StudioUI` Theme & GarageBand Tactile Components

**Files:**
- Create: `App/Sources/StudioUI/Components/StudioTheme.swift`
- Create: `App/Sources/StudioUI/Components/StudioKnob.swift`
- Create: `App/Sources/StudioUI/Components/StudioFader.swift`
- Create: `App/Sources/StudioUI/Components/LEDMeterView.swift`
- Create: `App/Sources/StudioUI/Components/OscilloscopeView.swift`
- Create: `App/Sources/StudioUI/Components/HardwarePickers.swift`

**Interfaces:**
- Consumes: `SwiftUI`, `UIKit`, `SynthCore` (`BrainwaveBand`, `Waveform`, `EntrainmentMode`, `TelemetryRingBuffer`, `TelemetryFrame`)
- Produces: `StudioTheme`, `StudioKnob`, `StudioFader`, `LEDMeterView`, `OscilloscopeView`, `WaveformPicker`, `ModePicker`

- [ ] **Step 1: Implement `StudioTheme.swift` and `LEDMeterView.swift`**

- `StudioTheme.swift`: define dark graphite/obsidian palette (`#101216`, `#1A1D24`, brushed metal gradients), brainwave band accent colors (`delta` indigo, `theta` purple, `alpha` teal, `beta` amber, `gamma` coral), iOS 27 `.glassEffect()` surface helpers, and formatted time helpers (`MM:SS`).
- `LEDMeterView.swift`: segmented vertical/horizontal stereo meter (green → amber → red segments with peak-hold cap decay).

- [ ] **Step 2: Implement `StudioKnob.swift` and `StudioFader.swift`**

- `StudioKnob`: `@Binding var value: Double`, `range: ClosedRange<Double>`, `defaultValue: Double`, `title: String`, `valueFormatter: (Double) -> String`, `accentColor: Color`. Vertical drag changes value; horizontal drag offset `> 36 pt` engages 0.2× fine-tuning mode; double-tap resets to `defaultValue`; `UIImpactFeedbackGenerator` fires subtle ticks at 10% detents and limits; `.accessibilityAdjustableAction` for VoiceOver.
- `StudioFader`: metallic thumb cap on recessed groove with dB tick marks and live dragging haptic feedback.

- [ ] **Step 3: Implement `OscilloscopeView.swift` and `HardwarePickers.swift`**

- `OscilloscopeView`: `TimelineView(.animation)` driving a `Canvas` backed by `TelemetryRingBuffer` + current `BrainwaveBand` & `dominantBeatHz`. Tap cycles `.waveform` (glowing L/R traces), `.lissajous` (X-Y phase plot), and `.bandMonitor` (large frequency readout + band badge + active voice LEDs).
- `HardwarePickers`: `WaveformPicker` (5 custom vector waveform shapes) and `ModePicker` (`Binaural` / `Monaural` / `Isochronic`) styled as backlit GarageBand hardware pushbuttons.

- [ ] **Step 4: Build to verify compilation and zero Swift 6 warnings**

Run: `xcodebuild build -project /Users/andy/.gemini/antigravity/scratch/Sintonia/Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/StudioUI/Components
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(StudioUI): add iOS 27 Liquid Glass theme and GarageBand tactile controls"
```

---

### Task 8: `StudioUI` Screen 1 — `PlayerView`, `MiniTimelineScrubber`, `ExportSheetView` & `AboutSheetView`

**Files:**
- Create: `App/Sources/StudioUI/Player/PlayerView.swift`
- Create: `App/Sources/StudioUI/Player/MiniTimelineScrubber.swift`
- Create: `App/Sources/StudioUI/Player/ExportSheetView.swift`
- Create: `App/Sources/StudioUI/Player/AboutSheetView.swift`

**Interfaces:**
- Consumes: `AudioEngineController`, `SessionExporter`, `StudioTheme`, `StudioKnob`, `OscilloscopeView`, `PresetKit`
- Produces: `PlayerView`, `MiniTimelineScrubber`, `ExportSheetView`, `AboutSheetView`

- [ ] **Step 1: Implement `MiniTimelineScrubber.swift` and `PlayerView.swift`**

- `MiniTimelineScrubber`: displays overall beat-frequency sparkline across `0...durationSec`, elapsed progress fill, current/remaining time labels, and drag-to-seek gesture calling `engine.seek(to:)`.
- `PlayerView`:
  - Top Liquid Glass bar: Library button, preset title, live colored brainwave pill (`Alpha • 9.4 Hz`), headphone route pill / banner when binaural is playing over speaker or auto-paused on unplug, Studio button, Export button, About button.
  - Center: `OscilloscopeView` + `MiniTimelineScrubber`.
  - Bottom Smart Controls rack: 4 large `StudioKnob`s (`Master`, `Tones`, `Noise`, `Noise Color`) wired to `engine.liveOverrides`, plus floating Liquid Glass transport bar (`-30s`, `Play/Pause`, `+30s`).

- [ ] **Step 2: Implement `ExportSheetView.swift` and `AboutSheetView.swift`**

- `ExportSheetView`: format picker (`WAV 24-bit` / `M4A AAC`), estimated render summary, progress bar with live percentage, Cancel button cancelling the `Task`, and `ShareLink` once exported URL is ready; localized error banner on failure.
- `AboutSheetView`: localized App Store Guideline 1.4.1 wellness & safe-listening disclaimer, feature overview, and `.bwg` compatibility note.

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -project /Users/andy/.gemini/antigravity/scratch/Sintonia/Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/StudioUI/Player
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(StudioUI): add PlayerView, MiniTimelineScrubber, ExportSheetView, and AboutSheetView"
```

---

### Task 9: `StudioUI` Screen 2 — `StudioRackView`, `VoiceInspectorView`, `NoiseInspectorView` & `CurveEditorView`

**Files:**
- Create: `App/Sources/StudioUI/Studio/StudioRackView.swift`
- Create: `App/Sources/StudioUI/Studio/VoiceInspectorView.swift`
- Create: `App/Sources/StudioUI/Studio/NoiseInspectorView.swift`
- Create: `App/Sources/StudioUI/Studio/CurveEditorCanvas.swift`
- Create: `App/Sources/StudioUI/Studio/CurveEditorView.swift`

**Interfaces:**
- Consumes: `Preset`, `Voice`, `NoiseLayer`, `EnvelopeCurve`, `PresetValidator`, `PresetStore`, `AudioEngineController`, `StudioKnob`, `StudioFader`, `LEDMeterView`, `HardwarePickers`
- Produces: `StudioRackView`, `VoiceInspectorView`, `NoiseInspectorView`, `CurveEditorCanvas`, `CurveEditorView`

- [ ] **Step 1: Implement `VoiceInspectorView.swift` and `NoiseInspectorView.swift`**

- `VoiceInspectorView`: `ModePicker`, `WaveformPicker`, `StudioKnob`s for quick/initial offsets (`Carrier Hz`, `Beat Hz`, `Pan`, plus `Iso Softness` & `Iso Duty` when `.isochronic`), and acyclic `Tracking` picker (only showing valid non-cyclic source voices, target parameter `.carrier`/`.beat`, ratio, offset).
- `NoiseInspectorView`: Enable toggle, `Pulse Sync` toggle, `Pulse Depth` knob, source voice selector (`Auto` or `Ch 1...10`).

- [ ] **Step 2: Implement `CurveEditorCanvas.swift` and `CurveEditorView.swift`**

- `CurveEditorCanvas`: interactive SwiftUI `Canvas` for editing `EnvelopeCurve` (`0...durationSec` on X, parameter range on Y). Supports: tap empty space to add control point; drag control point with floating coordinate readout `(14:30 • 8.5 Hz)`; context/long-press delete (never deleting the last remaining point); pinch-to-zoom time axis; optional 1-minute snap toggle; interpolation switcher (`Linear` / `Smooth S-Curve`); live playback cursor synced to `engine.currentTime`.
- `CurveEditorView`: parameter selector (`Beat Hz`, `Carrier Hz`, `Voice Volume`, `Noise Volume`, `Noise Color`) + `CurveEditorCanvas`. Automatically adapts into a full-screen studio layout with side parameter rail when horizontal size class / landscape orientation is active.

- [ ] **Step 3: Implement `StudioRackView.swift`**

- Voice channel strip rack (`1...10` voices): each strip shows channel index/name, `M` (Mute) & `S` (Solo) hardware buttons, waveform/mode badge, live `LEDMeterView`, `StudioFader` for quick voice level scaling, `+ Add Voice` button (disabled at 10), duplicate/delete actions.
- Any edit live-pushes via `engine.applyEditedPreset(_:)` and marks dirty; tapping **Save** saves via `PresetStore.saveEdited(_:)` (auto-forking built-in presets to `Custom`).

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -project /Users/andy/.gemini/antigravity/scratch/Sintonia/Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/StudioUI/Studio
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(StudioUI): add StudioRackView, Voice/Noise inspectors, and landscape CurveEditorView"
```

---

### Task 10: `StudioUI` Screen 3 — `LibraryView`, `PresetSparklineView`, System Import & App Wiring

**Files:**
- Create: `App/Sources/StudioUI/Library/LibraryView.swift`
- Create: `App/Sources/StudioUI/Library/PresetSparklineView.swift`
- Create: `App/Sources/StudioUI/Library/ImportResultAlert.swift`
- Modify: `App/Sources/StudioUI/SintoniaApp.swift`

**Interfaces:**
- Consumes: `PresetStore`, `PresetCatalog`, `BWGImporter`, `PresetCodec`, `AudioEngineController`, `PlayerView`, `StudioRackView`
- Produces: Complete end-to-end Sintonia app (`LibraryView`, `PresetSparklineView`, `ImportResultAlert`, wired `SintoniaApp`).

- [ ] **Step 1: Implement `PresetSparklineView.swift`, `ImportResultAlert.swift`, and `LibraryView.swift`**

- `PresetSparklineView`: lightweight `Canvas` rendering the primary voice's `beatCurve` contour colored by dominant brainwave band.
- `LibraryView`: searchable list/grid with category filter chips (`All` + `PresetCategory.allCases`), cards showing name, category, localized summary, duration badge, headphone indicator, and `PresetSparklineView`; `+ New Preset` template button; `.fileImporter` supporting `.bwg` and `.sintonia` UTIs; swipe/context actions (Duplicate, Export `.sintonia` via `ShareLink`, Delete custom); `ImportResultAlert` surfacing `ImportReport` skipped legacy items or typed import error messages.

- [ ] **Step 2: Wire `SintoniaApp.swift` end-to-end**

- Initialize `PresetStore` in `Application Support/Sintonia/Presets` and `AudioEngineController` loaded with `Deep Focus` (`PresetCatalog.builtInPresets[0]`).
- Attach `.onOpenURL` handler reading security-scoped `.bwg` / `.sintonia` files from Files/Safari/AirDrop, saving imported presets into `PresetStore`, auto-loading into `AudioEngineController`, and presenting `ImportResultAlert` if legacy features were skipped or the file was invalid.

- [ ] **Step 3: Full verification across SwiftPM tests and iOS 27.2 Simulator build**

Run:
```bash
swift test --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore
cd /Users/andy/.gemini/antigravity/scratch/Sintonia && xcodegen generate && xcodebuild build -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
```
Expected: All `SynthCoreTests` and `PresetKitTests` pass (`0` failures), and `xcodebuild build` outputs `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/StudioUI/Library App/Sources/StudioUI/SintoniaApp.swift Sintonia.xcodeproj
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(StudioUI): add LibraryView, .bwg/.sintonia system import, and full app wiring"
```
