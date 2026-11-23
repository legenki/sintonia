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

    @Test func brainwaveBandThresholds() {
        #expect(BrainwaveBand.from(frequencyHz: 0.5) == .delta)
        #expect(BrainwaveBand.from(frequencyHz: 3.99) == .delta)
        #expect(BrainwaveBand.from(frequencyHz: 4.0) == .theta)
        #expect(BrainwaveBand.from(frequencyHz: 7.99) == .theta)
        #expect(BrainwaveBand.from(frequencyHz: 8.0) == .alpha)
        #expect(BrainwaveBand.from(frequencyHz: 12.99) == .alpha)
        #expect(BrainwaveBand.from(frequencyHz: 13.0) == .beta)
        #expect(BrainwaveBand.from(frequencyHz: 29.99) == .beta)
        #expect(BrainwaveBand.from(frequencyHz: 30.0) == .gamma)
        #expect(BrainwaveBand.from(frequencyHz: 60.0) == .gamma)
        #expect(BrainwaveBand.from(frequencyHz: .nan) == .delta)
    }

    @Test func isochronicMonauralPanAndSessionCompletion() {
        let isoVoice = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .isochronic, waveform: .sine,
            isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: -1.0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 300)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.9)], interpolation: .linear)
        )
        let snap = SynthSnapshot(durationSec: 1.0, masterGain: 1.0, fadeInSec: 0.1, fadeOutSec: 0.1, noise: .disabled, voices: [isoVoice])
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
        renderer.setPlaying(true)

        var left = [Float](repeating: 0, count: 60_000)
        var right = [Float](repeating: 0, count: 60_000)
        left.withUnsafeMutableBufferPointer { lPtr in
            right.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 60_000)
            }
        }
        // Hard-panned left: right channel stays strictly silent, left channel has signal.
        let maxR = right.map { abs($0) }.max() ?? 1.0
        let maxL = left[4800..<24000].map { abs($0) }.max() ?? 0.0
        #expect(maxR < 1e-6)
        #expect(maxL > 0.5)

        // Past durationSec (48_000 samples = 1.0 s): time clamps at 1.0 and emits silence.
        #expect(abs(renderer.currentTimeSeconds() - 1.0) < 1e-6)
        for s in left[48_000..<60_000] {
            #expect(s == 0.0)
        }
    }

    @Test func liveOverridesDominantBeatAndLongCurveResampling() {
        var pts: [CurvePoint] = []
        for i in 0..<400 {
            pts.append(CurvePoint(timeSec: Double(i), value: 100.0 + Double(i)))
        }
        let v0 = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: pts, interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 6.0)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.4)], interpolation: .linear)
        )
        let v1 = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 300)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 40.0)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.9)], interpolation: .linear)
        )
        let snap = SynthSnapshot(durationSec: 500, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [v0, v1])
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)
        #expect(abs(renderer.dominantBeatHz(at: 0) - 40.0) < 1e-6)

        // Muting v1 makes v0 dominant.
        var mutedSnap = snap
        mutedSnap.voices[1].isMuted = true
        renderer.applySnapshot(mutedSnap)
        #expect(abs(renderer.dominantBeatHz(at: 0) - 6.0) < 1e-6)

        // Seek near end of >256-point curve and verify carrier resampled accurately (~499 Hz).
        renderer.seek(to: 399.0)
        renderer.setPlaying(true)
        var l = [Float](repeating: 0, count: 24_000)
        var r = [Float](repeating: 0, count: 24_000)
        l.withUnsafeMutableBufferPointer { lPtr in
            r.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 24_000)
            }
        }
        let steadyCarrierL = measureFrequencyZeroCrossings(samples: Array(l.dropFirst(4800)), sampleRate: 48_000)
        #expect(abs(steadyCarrierL - 496.0) < 2.0)

        // Zeroing master gain override fades output down toward silence.
        renderer.updateOverrides(LiveOverrides(masterGain: 0.0, tonesGain: 1.0, noiseGain: 1.0, noiseSmoothnessOffset: 0.0))
        var l2 = [Float](repeating: 0, count: 9600)
        var r2 = [Float](repeating: 0, count: 9600)
        l2.withUnsafeMutableBufferPointer { lPtr in
            r2.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 9600)
            }
        }
        let tailPeak = l2.suffix(1024).map { abs($0) }.max() ?? 1.0
        #expect(tailPeak < 0.01)
    }

    @Test func hotSwapBoundaryIsContinuousAndTelemetryTracksRollingHistory() {
        let tenVoices = (0..<10).map { i in
            VoiceSnapshot(
                id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
                mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
                carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 180 + Double(i) * 15)], interpolation: .linear),
                beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
                volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.8)], interpolation: .linear)
            )
        }
        let snap10 = SynthSnapshot(durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: tenVoices)
        let snap1 = SynthSnapshot(durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [tenVoices[0]])
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap10)
        renderer.setPlaying(true)

        var l1 = [Float](repeating: 0, count: 2048)
        var r1 = [Float](repeating: 0, count: 2048)
        l1.withUnsafeMutableBufferPointer { lPtr in
            r1.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 2048)
            }
        }
        renderer.applySnapshot(snap1)
        var l2 = [Float](repeating: 0, count: 2048)
        var r2 = [Float](repeating: 0, count: 2048)
        l2.withUnsafeMutableBufferPointer { lPtr in
            r2.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 2048)
            }
        }
        // Boundary sample jump between end of l1 and start of l2 must be smooth (no hard discontinuity).
        let boundaryDiffL = abs(l2[0] - l1[l1.count - 1])
        let boundaryDiffR = abs(r2[0] - r1[r1.count - 1])
        #expect(boundaryDiffL < 0.05 && boundaryDiffR < 0.05)

        // Verify TelemetryRingBuffer preserves chronological order across partial pushes and sanitizes NaNs.
        let ring = TelemetryRingBuffer()
        var chunk1 = (0..<512).map { Float($0) / 1000.0 }
        chunk1[10] = .nan
        let chunk2 = (512..<1024).map { Float($0) / 1000.0 }
        chunk1.withUnsafeBufferPointer { p1 in
            ring.push(left: p1.baseAddress!, right: p1.baseAddress!, count: p1.count)
        }
        chunk2.withUnsafeBufferPointer { p2 in
            ring.push(left: p2.baseAddress!, right: p2.baseAddress!, count: p2.count)
        }
        var frame = TelemetryFrame()
        ring.readLatest(into: &frame)
        #expect(frame.leftSamples[0] == 0.0)
        #expect(frame.leftSamples[10] == 0.0)
        #expect(abs(frame.leftSamples[1023] - 1.023) < 1e-5)
        #expect(frame.rmsL.isFinite && frame.peakL.isFinite)
    }

    @Test func pauseRampsCleanlyAndConcurrentStressStaysFinite() async {
        let voices = (0..<4).map { idx in
            VoiceSnapshot(
                id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
                mode: .binaural, waveform: .sine, isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
                carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 180 + Double(idx) * 30)], interpolation: .linear),
                beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 10)], interpolation: .linear),
                volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.8)], interpolation: .linear)
            )
        }
        let snap4 = SynthSnapshot(durationSec: 120, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: voices)
        let snap1 = SynthSnapshot(durationSec: 120, masterGain: 0.9, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [voices[0]])

        let telemetry = TelemetryRingBuffer()
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap4, telemetry: telemetry)
        renderer.setPlaying(true)

        var bufL = [Float](repeating: 0, count: 2048)
        var bufR = [Float](repeating: 0, count: 2048)
        bufL.withUnsafeMutableBufferPointer { lPtr in
            bufR.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 2048)
            }
        }

        // Pause should ramp smoothly to 0 over 15 ms and halt time advancement thereafter.
        renderer.setPlaying(false)
        bufL.withUnsafeMutableBufferPointer { lPtr in
            bufR.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 2048)
            }
        }
        let pausedTime = renderer.currentTimeSeconds()
        for s in bufL.suffix(512) + bufR.suffix(512) {
            #expect(s == 0.0)
        }
        bufL.withUnsafeMutableBufferPointer { lPtr in
            bufR.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 1024)
            }
        }
        #expect(abs(renderer.currentTimeSeconds() - pausedTime) < 1e-9)

        // Concurrent audio render vs snapshot hot-swaps, overrides, seeks, and telemetry reads.
        renderer.setPlaying(true)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var l = [Float](repeating: 0, count: 512)
                var r = [Float](repeating: 0, count: 512)
                l.withUnsafeMutableBufferPointer { lPtr in
                    r.withUnsafeMutableBufferPointer { rPtr in
                        for _ in 0..<80 {
                            renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 512)
                            for s in lPtr {
                                #expect(s.isFinite && abs(s) <= 1.0)
                            }
                            for s in rPtr {
                                #expect(s.isFinite && abs(s) <= 1.0)
                            }
                        }
                    }
                }
            }
            group.addTask {
                var frame = TelemetryFrame()
                for step in 0..<80 {
                    renderer.applySnapshot(step.isMultiple(of: 2) ? snap4 : snap1)
                    renderer.updateOverrides(LiveOverrides(masterGain: 0.8, tonesGain: 1.0, noiseGain: 0.5, noiseSmoothnessOffset: 0.1))
                    if step == 30 {
                        renderer.seek(to: 12.0)
                    }
                    let beat = renderer.dominantBeatHz(at: renderer.currentTimeSeconds())
                    #expect(beat.isFinite && beat >= 0.0)
                    telemetry.readLatest(into: &frame)
                    #expect(frame.rmsL.isFinite && frame.peakL.isFinite)
                    await Task.yield()
                }
            }
        }
    }

    @Test func telemetryTripleBufferNeverTearsUnderConcurrentPushAndRead() async {
        let ring = TelemetryRingBuffer()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var bufL = [Float](repeating: 0, count: 1024)
                var bufR = [Float](repeating: 0, count: 1024)
                for step in 1...400 {
                    let vL = Float(step) * 0.001
                    let vR = -vL
                    for i in 0..<1024 {
                        bufL[i] = vL
                        bufR[i] = vR
                    }
                    bufL.withUnsafeBufferPointer { lPtr in
                        bufR.withUnsafeBufferPointer { rPtr in
                            ring.push(left: lPtr.baseAddress!, right: rPtr.baseAddress!, count: 1024)
                        }
                    }
                    if step.isMultiple(of: 20) {
                        await Task.yield()
                    }
                }
            }
            group.addTask {
                var frame = TelemetryFrame()
                var lastSeenVal: Float = 0.0
                for _ in 0..<400 {
                    ring.readLatest(into: &frame)
                    let expected = frame.leftSamples[0]
                    #expect(expected >= lastSeenVal - 1e-6)
                    lastSeenVal = expected
                    for i in 0..<1024 {
                        #expect(frame.leftSamples[i] == expected)
                        #expect(frame.rightSamples[i] == -expected)
                    }
                    #expect(abs(frame.peakL - expected) < 1e-6)
                    #expect(abs(frame.rmsL - expected) < 1e-4)
                    #expect(abs(frame.peakR - expected) < 1e-6)
                    #expect(abs(frame.rmsR - expected) < 1e-4)
                    await Task.yield()
                }
            }
        }
    }

    @Test func loadSnapshotResetsTimeEnvelopesPhasesAndDeclickStateCleanly() {
        let voiceA = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine,
            isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 440)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 12)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.9)], interpolation: .linear)
        )
        let snapA = SynthSnapshot(durationSec: 120, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [voiceA])

        let voiceB = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine,
            isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 180)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 6)], interpolation: .linear),
            volumeCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 0.8)], interpolation: .linear)
        )
        let snapB = SynthSnapshot(durationSec: 60, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [voiceB])

        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snapA)
        renderer.setPlaying(true)

        // Render presetA well past the 15 ms ramp so transportEnvelope == 1.0 and renderTime > 0.25 s.
        var warmupL = [Float](repeating: 0, count: 12_000)
        var warmupR = [Float](repeating: 0, count: 12_000)
        warmupL.withUnsafeMutableBufferPointer { lPtr in
            warmupR.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 12_000)
            }
        }
        #expect(renderer.currentTimeSeconds() >= 0.24)

        // Request a stale seek, pause without rendering, and load presetB.
        renderer.seek(to: 45.0)
        renderer.setPlaying(false)
        renderer.loadSnapshot(snapB)
        #expect(renderer.currentTimeSeconds() == 0.0)

        // Immediately press Play and render 24_000 frames (0.5 s).
        renderer.setPlaying(true)
        var bL = [Float](repeating: 0, count: 24_000)
        var bR = [Float](repeating: 0, count: 24_000)
        bL.withUnsafeMutableBufferPointer { lPtr in
            bR.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 24_000)
            }
        }

        // Frame 0 must ramp smoothly up from near-zero (zero declick burst or old-timestamp burst).
        #expect(abs(bL[0]) < 0.005)
        #expect(abs(bR[0]) < 0.005)
        // Elapsed render time must start cleanly from 0.0 -> 0.5 s (not ~45.5 s or ~0.75 s).
        #expect(abs(renderer.currentTimeSeconds() - 0.5) < 1e-6)

        let measuredL = measureFrequencyZeroCrossings(samples: Array(bL.dropFirst(4800)), sampleRate: 48_000)
        let measuredR = measureFrequencyZeroCrossings(samples: Array(bR.dropFirst(4800)), sampleRate: 48_000)
        #expect(abs(((measuredL + measuredR) * 0.5) - 180.0) < 0.1)
        #expect(abs((measuredR - measuredL) - 6.0) < 0.1)

        // A seek issued *after* loadSnapshot (before next render) must still be honored.
        renderer.setPlaying(false)
        renderer.loadSnapshot(snapB)
        renderer.seek(to: 10.0)
        #expect(abs(renderer.currentTimeSeconds() - 10.0) < 1e-6)
        renderer.setPlaying(true)
        var seekL = [Float](repeating: 0, count: 1024)
        var seekR = [Float](repeating: 0, count: 1024)
        seekL.withUnsafeMutableBufferPointer { lPtr in
            seekR.withUnsafeMutableBufferPointer { rPtr in
                renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 1024)
            }
        }
        #expect(abs(seekL[0]) < 0.005)
        #expect(abs(renderer.currentTimeSeconds() - (10.0 + 1024.0 / 48_000.0)) < 1e-6)
    }

    @Test func deepBreathSync301PointCurvePacksLosslesslyAndResamplingUsesLinear() {
        let duration = 1800.0
        let cycleSec = 12.0
        let cycleCount = Int(duration / cycleSec)
        var points: [CurvePoint] = []
        points.reserveCapacity(cycleCount * 2 + 1)
        for cycle in 0..<cycleCount {
            let start = Double(cycle) * cycleSec
            let peak = start + cycleSec * 0.45
            points.append(CurvePoint(timeSec: start, value: 0.45))
            if peak < duration {
                points.append(CurvePoint(timeSec: peak, value: 0.80))
            }
        }
        points.append(CurvePoint(timeSec: duration, value: 0.45))
        #expect(points.count == 301)

        let volumeCurve = CompiledCurve(points: points, interpolation: .smoothStep)
        let voice = VoiceSnapshot(
            id: UUID(), isEnabled: true, isMuted: false, isSolo: false,
            mode: .binaural, waveform: .sine,
            isochronicSoftness: 0.5, isochronicDutyCycle: 0.5, pan: 0,
            carrierCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 174)], interpolation: .linear),
            beatCurve: CompiledCurve(points: [CurvePoint(timeSec: 0, value: 7.0)], interpolation: .linear),
            volumeCurve: volumeCurve
        )
        let snap = SynthSnapshot(durationSec: duration, masterGain: 1.0, fadeInSec: 0, fadeOutSec: 0, noise: .disabled, voices: [voice])
        let renderer = SynthRenderer(sampleRate: 48_000, snapshot: snap)

        func rmsAt(timeSec: Double) -> Double {
            renderer.loadSnapshot(snap)
            renderer.seek(to: timeSec)
            renderer.setPlaying(true)
            var l = [Float](repeating: 0, count: 4800)
            var r = [Float](repeating: 0, count: 4800)
            l.withUnsafeMutableBufferPointer { lPtr in
                r.withUnsafeMutableBufferPointer { rPtr in
                    renderer.render(intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!, frameCount: 4800)
                }
            }
            let steady = Array(l.dropFirst(1600))
            let sq = steady.reduce(0.0) { $0 + Double($1) * Double($1) }
            return (sq / Double(steady.count)).squareRoot()
        }

        // Verify every cycle's trough (0.45) and peak (0.80) pack losslessly with zero Nyquist aliasing.
        let podChannel = SnapshotChannel(initial: snap)
        let podSlot = podChannel.initialAudioSlot()
        #expect(podSlot.pointee.voices[0].volumeCurve.count == 301)
        #expect(podSlot.pointee.voices[0].volumeCurve.interpolationRaw == 1)
        for cycle in 0..<cycleCount {
            let troughT = Double(cycle) * cycleSec
            let peakT = troughT + cycleSec * 0.45
            let troughVal = podSlot.pointee.voices[0].volumeCurve.evaluate(at: troughT, points: podSlot.pointee.curvePoints)
            let peakVal = podSlot.pointee.voices[0].volumeCurve.evaluate(at: peakT, points: podSlot.pointee.curvePoints)
            #expect(abs(troughVal - 0.45) < 1e-6)
            #expect(abs(peakVal - 0.80) < 1e-6)
        }

        // Verify audio output RMS across early, mid, and late cycles tracks peaks vs troughs.
        for cycle in [10, 74, 140] {
            let troughT = Double(cycle) * cycleSec
            let peakT = troughT + cycleSec * 0.45
            let troughRMS = rmsAt(timeSec: troughT)
            let peakRMS = rmsAt(timeSec: peakT)
            #expect(peakRMS / max(1e-6, troughRMS) > 1.55)
        }

        // Verify >512-point smoothStep curve disables second-pass smoothStep when resampled.
        var longPoints: [CurvePoint] = []
        for i in 0...600 {
            longPoints.append(CurvePoint(timeSec: Double(i), value: Double(i)))
        }
        let longCurve = CompiledCurve(points: longPoints, interpolation: .smoothStep)
        var longSnap = snap
        longSnap.voices[0].carrierCurve = longCurve
        let channel = SnapshotChannel(initial: longSnap)
        let slot = channel.initialAudioSlot()
        #expect(slot.pointee.voices[0].carrierCurve.count == SnapshotChannel.maxPointsPerCurve)
        #expect(slot.pointee.voices[0].carrierCurve.interpolationRaw == 0)
    }
}
