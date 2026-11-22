import Darwin
import Foundation
import Synchronization

private struct VoiceRenderState {
    var phaseL: Double = 0.0
    var phaseR: Double = 0.0
    var modPhase: Double = 0.0
    var smoothedCarrierHz: Double = 200.0
    var smoothedBeatHz: Double = 10.0
    var smoothedVolume: Double = 0.0
    var smoothedPan: Double = 0.0
    var wasAudible: Bool = false
}

private enum SeekPhase {
    case idle
    case fadingOut
    case fadingIn
}

/// Real-time lock-free multi-voice synthesizer and stereo noise renderer.
public final class SynthRenderer: @unchecked Sendable {
    private static let limiterCeiling: Double = 0.944 // -0.5 dBFS
    private static let smoothingTimeSec: Double = 0.015 // 15 ms
    private static let noiseLeftSeed: UInt64 = 0x5741_5645_4C45_4654
    private static let noiseRightSeed: UInt64 = 0x5741_5645_5249_4748

    private let sampleRate: Double
    private let invSampleRate: Double
    private let maxOscFreq: Double
    private let smoothAlpha: Double
    private let declickDecay: Double
    private let rampStep: Double

    // Channel stored via pre-allocated pointer; telemetry retained for lifetime while accessed via raw POD storage.
    private let channel: UnsafeMutablePointer<SnapshotChannel>
    private let telemetryOwner: TelemetryRingBuffer?
    private let telemetryStorage: UnsafeMutablePointer<TelemetryStorage>?

    // Atomic control state (written by UI/caller threads, read lock-free by audio thread).
    private let atomicIsPlaying = Atomic<Bool>(false)
    private let atomicCurrentTimeBits = Atomic<UInt64>(0)
    private let overrideMasterBits = Atomic<UInt64>((1.0 as Double).bitPattern)
    private let overrideTonesBits = Atomic<UInt64>((1.0 as Double).bitPattern)
    private let overrideNoiseBits = Atomic<UInt64>((1.0 as Double).bitPattern)
    private let overrideSmoothOffsetBits = Atomic<UInt64>((0.0 as Double).bitPattern)

    // Lock-free double-slot seek transfer preserving exact Double precision.
    private let seekTargets: UnsafeMutablePointer<Atomic<UInt64>>
    private let seekControl = Atomic<UInt64>(0)
    private let seekProducerLock = Atomic<Bool>(false)

    // Pre-allocated POD audio-thread render state (never touched outside render/init/deinit).
    private let voiceStates: UnsafeMutablePointer<VoiceRenderState>
    private let voiceAudibleFlags: UnsafeMutablePointer<Bool>
    private var noiseGenerator: StereoNoiseGenerator

    private var renderTime: Double = 0.0
    private var previousVoiceCount: Int = 0
    private var lastHandledSeekSeq: UInt64 = 0
    private var seekPhase: SeekPhase = .idle
    private var pendingSeekTarget: Double = 0.0
    private var transportEnvelope: Double = 0.0
    private var seekEnvelope: Double = 1.0

    private var smoothedMasterGain: Double = 1.0
    private var smoothedNormFactor: Double = 1.0
    private var smoothedNoiseVolume: Double = 0.0
    private var smoothedNoiseSmoothness: Double = 0.5
    private var smoothedOverrideMaster: Double = 1.0
    private var smoothedOverrideTones: Double = 1.0
    private var smoothedOverrideNoise: Double = 1.0
    private var smoothedOverrideSmoothOffset: Double = 0.0

    private var declickL: Double = 0.0
    private var declickR: Double = 0.0
    private var lastPreEnvL: Double = 0.0
    private var lastPreEnvR: Double = 0.0
    private var hasRenderedAnyAudio: Bool = false

    public init(sampleRate: Double = 48_000, snapshot: SynthSnapshot, telemetry: TelemetryRingBuffer? = nil) {
        let safeRate = (sampleRate.isFinite && sampleRate > 0.0) ? sampleRate : 48_000.0
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate
        self.maxOscFreq = safeRate * 0.45

        let samplesPerTau = max(1.0, Self.smoothingTimeSec * safeRate)
        self.smoothAlpha = 1.0 - exp(-1.0 / samplesPerTau)
        self.declickDecay = exp(-1.0 / samplesPerTau)
        self.rampStep = 1.0 / samplesPerTau

        let channelPtr = UnsafeMutablePointer<SnapshotChannel>.allocate(capacity: 1)
        channelPtr.initialize(to: SnapshotChannel(initial: snapshot))
        self.channel = channelPtr
        self.telemetryOwner = telemetry
        self.telemetryStorage = telemetry?.storage
        self.noiseGenerator = StereoNoiseGenerator(leftSeed: Self.noiseLeftSeed, rightSeed: Self.noiseRightSeed)

        let seekPtr = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 2)
        (seekPtr + 0).initialize(to: Atomic<UInt64>(0))
        (seekPtr + 1).initialize(to: Atomic<UInt64>(0))
        self.seekTargets = seekPtr

        let statesPtr = UnsafeMutablePointer<VoiceRenderState>.allocate(capacity: SnapshotChannel.maxVoices)
        statesPtr.initialize(repeating: VoiceRenderState(), count: SnapshotChannel.maxVoices)
        self.voiceStates = statesPtr

        let flagsPtr = UnsafeMutablePointer<Bool>.allocate(capacity: SnapshotChannel.maxVoices)
        flagsPtr.initialize(repeating: false, count: SnapshotChannel.maxVoices)
        self.voiceAudibleFlags = flagsPtr

        let initialSlot = channelPtr.pointee.initialAudioSlot()
        self.previousVoiceCount = initialSlot.pointee.voiceCount
        snapSmoothers(to: 0.0, slot: initialSlot, snapOverrides: nil)
    }

    deinit {
        channel.deinitialize(count: 1)
        channel.deallocate()
        seekTargets.deinitialize(count: 2)
        seekTargets.deallocate()
        voiceStates.deinitialize(count: SnapshotChannel.maxVoices)
        voiceStates.deallocate()
        voiceAudibleFlags.deinitialize(count: SnapshotChannel.maxVoices)
        voiceAudibleFlags.deallocate()
    }

    /// Updates transport play/pause state; `render` applies a 15 ms click-free ramp.
    public func setPlaying(_ playing: Bool) {
        atomicIsPlaying.store(playing, ordering: .releasing)
    }

    /// Requests a click-free seek to `timeSec`, clamped within `[0, durationSec]`.
    public func seek(to timeSec: Double) {
        let duration = channel.pointee.latestDurationSec()
        let clamped = timeSec.isFinite ? min(duration, max(0.0, timeSec)) : 0.0

        while seekProducerLock.exchange(true, ordering: .acquiring) {
            // Producer-side only; audio thread never accesses `seekProducerLock`.
        }
        defer { seekProducerLock.store(false, ordering: .releasing) }

        let prevCtrl = seekControl.load(ordering: .relaxed)
        let nextSlot = Int((prevCtrl & 1) ^ 1)
        let nextSeq = (prevCtrl >> 1) &+ 1
        (seekTargets + nextSlot).pointee.store(clamped.bitPattern, ordering: .releasing)
        seekControl.store((nextSeq << 1) | UInt64(nextSlot), ordering: .releasing)
        atomicCurrentTimeBits.store(clamped.bitPattern, ordering: .releasing)
    }

    /// Hot-swaps the active synthesis snapshot lock-free for the next audio render block.
    public func applySnapshot(_ snapshot: SynthSnapshot) {
        channel.pointee.publish(snapshot)
    }

    /// Updates live player performance multipliers lock-free; smoothed with tau = 15 ms.
    public func updateOverrides(_ overrides: LiveOverrides) {
        let master = overrides.masterGain.isFinite ? min(1.0, max(0.0, overrides.masterGain)) : 1.0
        let tones = overrides.tonesGain.isFinite ? min(2.0, max(0.0, overrides.tonesGain)) : 1.0
        let noise = overrides.noiseGain.isFinite ? min(2.0, max(0.0, overrides.noiseGain)) : 1.0
        let smoothOffset = overrides.noiseSmoothnessOffset.isFinite ? min(1.0, max(-1.0, overrides.noiseSmoothnessOffset)) : 0.0

        overrideMasterBits.store(master.bitPattern, ordering: .relaxed)
        overrideTonesBits.store(tones.bitPattern, ordering: .relaxed)
        overrideNoiseBits.store(noise.bitPattern, ordering: .relaxed)
        overrideSmoothOffsetBits.store(smoothOffset.bitPattern, ordering: .relaxed)
    }

    /// Returns the latest playback timestamp in seconds.
    public func currentTimeSeconds() -> Double {
        Double(bitPattern: atomicCurrentTimeBits.load(ordering: .acquiring))
    }

    /// Evaluates the loudest audible voice's beat frequency at `timeSec` for UI band monitoring.
    public func dominantBeatHz(at timeSec: Double) -> Double {
        channel.pointee.dominantBeatHz(at: timeSec)
    }

    /// Renders `frameCount` stereo frames with zero heap allocations, zero ARC, and zero locks.
    public func render(
        intoLeft leftOut: UnsafeMutablePointer<Float>,
        intoRight rightOut: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        let targetPlaying = atomicIsPlaying.load(ordering: .acquiring)
        let targetOvMaster = Double(bitPattern: overrideMasterBits.load(ordering: .relaxed))
        let targetOvTones = Double(bitPattern: overrideTonesBits.load(ordering: .relaxed))
        let targetOvNoise = Double(bitPattern: overrideNoiseBits.load(ordering: .relaxed))
        let targetOvSmoothOffset = Double(bitPattern: overrideSmoothOffsetBits.load(ordering: .relaxed))
        let targetOverrides = (targetOvMaster, targetOvTones, targetOvNoise, targetOvSmoothOffset)

        let (slotPtr, didSwap) = channel.pointee.acquireAudioSlotIfUpdated()
        let slot = slotPtr.pointee
        let (audibleCount, pulseSourceIdx) = computeRouting(slot: slot)

        var captureDeclickThisBlock = false
        if didSwap {
            handleSnapshotSwap(slot: slot)
            if hasRenderedAnyAudio && (transportEnvelope * seekEnvelope) > 0.0 {
                captureDeclickThisBlock = true
            }
        }

        if handlePendingSeek(slotPtr: slotPtr, targetOverrides: targetOverrides) {
            captureDeclickThisBlock = false
        }

        let targetNormFactor = 1.0 / Double(max(1, audibleCount)).squareRoot()
        let duration = slot.durationSec

        for frame in 0..<frameCount {
            transportEnvelope = targetPlaying
                ? min(1.0, transportEnvelope + rampStep)
                : max(0.0, transportEnvelope - rampStep)

            if advanceSeekEnvelope(slotPtr: slotPtr, duration: duration, targetOverrides: targetOverrides) {
                captureDeclickThisBlock = false
            }

            let envGain = transportEnvelope * seekEnvelope

            if (envGain <= 0.0 && !targetPlaying) || (renderTime >= duration && seekPhase != .fadingOut) {
                if seekPhase == .fadingOut {
                    jumpToPendingSeek(slotPtr: slotPtr, duration: duration, targetOverrides: targetOverrides)
                    seekPhase = .idle
                    seekEnvelope = 1.0
                }
                if renderTime >= duration {
                    renderTime = duration
                }
                leftOut[frame] = 0.0
                rightOut[frame] = 0.0
                lastPreEnvL = 0.0
                lastPreEnvR = 0.0
                declickL = 0.0
                declickR = 0.0
                continue
            }

            smoothedOverrideMaster += smoothAlpha * (targetOvMaster - smoothedOverrideMaster)
            smoothedOverrideTones += smoothAlpha * (targetOvTones - smoothedOverrideTones)
            smoothedOverrideNoise += smoothAlpha * (targetOvNoise - smoothedOverrideNoise)
            smoothedOverrideSmoothOffset += smoothAlpha * (targetOvSmoothOffset - smoothedOverrideSmoothOffset)
            smoothedMasterGain += smoothAlpha * (slot.masterGain - smoothedMasterGain)
            smoothedNormFactor += smoothAlpha * (targetNormFactor - smoothedNormFactor)

            let t = renderTime
            let (tonesSumL, tonesSumR) = renderVoicesSample(at: t, slot: slot, pulseSourceIdx: pulseSourceIdx)
            let tonesScale = smoothedNormFactor * smoothedOverrideTones
            let (noiseL, noiseR) = renderNoiseSample(at: t, slot: slot, pulseSourceIdx: pulseSourceIdx)

            let sessEnv = sessionEnvelope(at: t, duration: duration, fadeIn: slot.fadeInSec, fadeOut: slot.fadeOutSec)
            let totalMaster = smoothedMasterGain * smoothedOverrideMaster
            let preDeclickL = (tonesSumL * tonesScale + noiseL) * sessEnv * totalMaster
            let preDeclickR = (tonesSumR * tonesScale + noiseR) * sessEnv * totalMaster

            if captureDeclickThisBlock {
                declickL = lastPreEnvL - preDeclickL
                declickR = lastPreEnvR - preDeclickR
                captureDeclickThisBlock = false
            } else {
                declickL *= declickDecay
                declickR *= declickDecay
            }

            let preEnvL = preDeclickL + declickL
            let preEnvR = preDeclickR + declickR
            lastPreEnvL = preEnvL
            lastPreEnvR = preEnvR
            hasRenderedAnyAudio = true

            leftOut[frame] = softLimit(preEnvL * envGain)
            rightOut[frame] = softLimit(preEnvR * envGain)

            if seekPhase != .fadingOut {
                renderTime = min(duration, renderTime + invSampleRate)
            }
        }

        if seekPhase != .fadingOut {
            atomicCurrentTimeBits.store(renderTime.bitPattern, ordering: .releasing)
        }

        telemetryStorage?.pointee.push(left: UnsafePointer(leftOut), right: UnsafePointer(rightOut), count: frameCount)
    }

    // MARK: - Audio-Thread Helpers (Zero Allocations / Zero ARC)

    @inline(__always)
    private func renderVoicesSample(at t: Double, slot: PODSnapshotSlot, pulseSourceIdx: Int) -> (Double, Double) {
        var sumL = 0.0
        var sumR = 0.0

        for i in 0..<slot.voiceCount {
            let voice = slot.voices[i]
            let isAudible = voiceAudibleFlags[i]
            let isPulseSource = (i == pulseSourceIdx)
            guard isAudible || isPulseSource || voiceStates[i].smoothedVolume > 1e-7 else {
                continue
            }

            let targetCarrier = clampCarrier(voice.carrierCurve.evaluate(at: t, points: slot.curvePoints))
            let targetBeat = clampBeat(voice.beatCurve.evaluate(at: t, points: slot.curvePoints))
            let targetVol = isAudible ? clampUnit(voice.volumeCurve.evaluate(at: t, points: slot.curvePoints)) : 0.0

            voiceStates[i].smoothedCarrierHz += smoothAlpha * (targetCarrier - voiceStates[i].smoothedCarrierHz)
            voiceStates[i].smoothedBeatHz += smoothAlpha * (targetBeat - voiceStates[i].smoothedBeatHz)
            voiceStates[i].smoothedVolume += smoothAlpha * (targetVol - voiceStates[i].smoothedVolume)
            voiceStates[i].smoothedPan += smoothAlpha * (voice.pan - voiceStates[i].smoothedPan)

            let carrierHz = voiceStates[i].smoothedCarrierHz
            let beatHz = voiceStates[i].smoothedBeatHz
            let vol = voiceStates[i].smoothedVolume
            let pan = voiceStates[i].smoothedPan
            let modInc = beatHz * invSampleRate

            if isAudible || vol > 1e-7 {
                let waveform = voice.waveform
                var vL = 0.0
                var vR = 0.0

                switch voice.mode {
                case .binaural:
                    let fL = max(20.0, carrierHz - 0.5 * beatHz)
                    let fR = min(maxOscFreq, max(20.0, carrierHz + 0.5 * beatHz))
                    let incL = fL * invSampleRate
                    let incR = fR * invSampleRate
                    vL = WaveformOscillator.sample(waveform: waveform, phase: voiceStates[i].phaseL, phaseIncrement: incL)
                    vR = WaveformOscillator.sample(waveform: waveform, phase: voiceStates[i].phaseR, phaseIncrement: incR)
                    advancePhase(&voiceStates[i].phaseL, by: incL)
                    advancePhase(&voiceStates[i].phaseR, by: incR)

                case .monaural:
                    let fL = max(20.0, carrierHz - 0.5 * beatHz)
                    let fR = min(maxOscFreq, max(20.0, carrierHz + 0.5 * beatHz))
                    let incL = fL * invSampleRate
                    let incR = fR * invSampleRate
                    let sL = WaveformOscillator.sample(waveform: waveform, phase: voiceStates[i].phaseL, phaseIncrement: incL)
                    let sR = WaveformOscillator.sample(waveform: waveform, phase: voiceStates[i].phaseR, phaseIncrement: incR)
                    let mono = 0.5 * (sL + sR)
                    let theta = (pan + 1.0) * (.pi * 0.25)
                    vL = mono * cos(theta)
                    vR = mono * sin(theta)
                    advancePhase(&voiceStates[i].phaseL, by: incL)
                    advancePhase(&voiceStates[i].phaseR, by: incR)

                case .isochronic:
                    let incC = min(maxOscFreq, max(20.0, carrierHz)) * invSampleRate
                    let carrierSample = WaveformOscillator.sample(waveform: waveform, phase: voiceStates[i].phaseL, phaseIncrement: incC)
                    let isoEnv = IsochronicEnvelope.sample(
                        phase: voiceStates[i].modPhase,
                        dutyCycle: voice.isochronicDutyCycle,
                        softness: voice.isochronicSoftness
                    )
                    let mono = carrierSample * isoEnv
                    let theta = (pan + 1.0) * (.pi * 0.25)
                    vL = mono * cos(theta)
                    vR = mono * sin(theta)
                    advancePhase(&voiceStates[i].phaseL, by: incC)
                    voiceStates[i].phaseR = voiceStates[i].phaseL
                }

                sumL += vL * vol
                sumR += vR * vol
            }

            advancePhase(&voiceStates[i].modPhase, by: modInc)
        }

        return (sumL, sumR)
    }

    @inline(__always)
    private func renderNoiseSample(at t: Double, slot: PODSnapshotSlot, pulseSourceIdx: Int) -> (Double, Double) {
        let targetNoiseVol = slot.noise.isEnabled ? clampUnit(slot.noise.volumeCurve.evaluate(at: t, points: slot.curvePoints)) : 0.0
        let targetNoiseSmooth = clampUnit(slot.noise.smoothnessCurve.evaluate(at: t, points: slot.curvePoints))
        smoothedNoiseVolume += smoothAlpha * (targetNoiseVol - smoothedNoiseVolume)
        smoothedNoiseSmoothness += smoothAlpha * (targetNoiseSmooth - smoothedNoiseSmoothness)

        guard slot.noise.isEnabled || smoothedNoiseVolume > 1e-7 else {
            return (0.0, 0.0)
        }

        let effectiveSmoothness = min(1.0, max(0.0, smoothedNoiseSmoothness + smoothedOverrideSmoothOffset))
        let rawNoise = noiseGenerator.nextSample(smoothness: effectiveSmoothness)
        var pulseGain = 1.0
        if slot.noise.pulseEnabled && pulseSourceIdx >= 0 && pulseSourceIdx < slot.voiceCount {
            let srcVoice = slot.voices[pulseSourceIdx]
            let pulseEnv = IsochronicEnvelope.sample(
                phase: voiceStates[pulseSourceIdx].modPhase,
                dutyCycle: srcVoice.isochronicDutyCycle,
                softness: srcVoice.isochronicSoftness
            )
            pulseGain = 1.0 - slot.noise.pulseDepth * (1.0 - pulseEnv)
        }
        let noiseAmp = smoothedNoiseVolume * smoothedOverrideNoise * pulseGain
        return (rawNoise.left * noiseAmp, rawNoise.right * noiseAmp)
    }

    @inline(__always)
    private func handlePendingSeek(
        slotPtr: UnsafePointer<PODSnapshotSlot>,
        targetOverrides: (Double, Double, Double, Double)
    ) -> Bool {
        let ctrl = seekControl.load(ordering: .acquiring)
        let ctrlSeq = ctrl >> 1
        guard ctrlSeq != lastHandledSeekSeq else { return false }

        let slot = slotPtr.pointee
        let slotIdx = Int(ctrl & 1)
        let rawTarget = Double(bitPattern: (seekTargets + slotIdx).pointee.load(ordering: .acquiring))
        lastHandledSeekSeq = ctrlSeq
        pendingSeekTarget = rawTarget.isFinite ? min(slot.durationSec, max(0.0, rawTarget)) : 0.0

        if (transportEnvelope <= 0.0 && seekPhase != .fadingIn) || !hasRenderedAnyAudio || renderTime >= slot.durationSec {
            jumpToPendingSeek(slotPtr: slotPtr, duration: slot.durationSec, targetOverrides: targetOverrides)
            if transportEnvelope > 0.0 {
                seekEnvelope = 0.0
                seekPhase = .fadingIn
            } else {
                seekEnvelope = 1.0
                seekPhase = .idle
            }
            return true
        }

        seekPhase = .fadingOut
        return false
    }

    @inline(__always)
    private func advanceSeekEnvelope(
        slotPtr: UnsafePointer<PODSnapshotSlot>,
        duration: Double,
        targetOverrides: (Double, Double, Double, Double)
    ) -> Bool {
        switch seekPhase {
        case .idle:
            seekEnvelope = 1.0
            return false
        case .fadingOut:
            seekEnvelope = max(0.0, seekEnvelope - rampStep)
            if seekEnvelope <= 0.0 {
                jumpToPendingSeek(slotPtr: slotPtr, duration: duration, targetOverrides: targetOverrides)
                seekPhase = .fadingIn
                return true
            }
            return false
        case .fadingIn:
            seekEnvelope = min(1.0, seekEnvelope + rampStep)
            if seekEnvelope >= 1.0 {
                seekPhase = .idle
            }
            return false
        }
    }

    @inline(__always)
    private func jumpToPendingSeek(
        slotPtr: UnsafePointer<PODSnapshotSlot>,
        duration: Double,
        targetOverrides: (Double, Double, Double, Double)
    ) {
        renderTime = min(duration, max(0.0, pendingSeekTarget))
        snapSmoothers(to: renderTime, slot: slotPtr, snapOverrides: targetOverrides)
        declickL = 0.0
        declickR = 0.0
    }

    @inline(__always)
    private func computeRouting(slot: PODSnapshotSlot) -> (audibleCount: Int, pulseSourceIdx: Int) {
        let hasSolo = slot.hasActiveSoloVoice()
        var audibleCount = 0
        var firstAudible = -1
        var firstEnabled = -1

        for i in 0..<SnapshotChannel.maxVoices {
            if i < slot.voiceCount {
                let audible = slot.isVoiceAudible(i, hasSolo: hasSolo)
                voiceAudibleFlags[i] = audible
                if audible {
                    audibleCount += 1
                    if firstAudible < 0 { firstAudible = i }
                }
                if slot.voices[i].isEnabled && firstEnabled < 0 {
                    firstEnabled = i
                }
            } else {
                voiceAudibleFlags[i] = false
            }
        }

        var pulseSourceIdx = -1
        if slot.noise.pulseEnabled {
            let requested = slot.noise.pulseSourceVoiceIndex
            if requested >= 0 && requested < slot.voiceCount && slot.voices[requested].isEnabled {
                pulseSourceIdx = requested
            } else if firstAudible >= 0 {
                pulseSourceIdx = firstAudible
            } else {
                pulseSourceIdx = firstEnabled
            }
        }

        return (audibleCount, pulseSourceIdx)
    }

    private func handleSnapshotSwap(slot: PODSnapshotSlot) {
        let t = renderTime
        for i in 0..<slot.voiceCount {
            let v = slot.voices[i]
            let isAudible = voiceAudibleFlags[i]
            if i >= previousVoiceCount {
                voiceStates[i] = VoiceRenderState(
                    phaseL: 0.0,
                    phaseR: 0.0,
                    modPhase: 0.0,
                    smoothedCarrierHz: clampCarrier(v.carrierCurve.evaluate(at: t, points: slot.curvePoints)),
                    smoothedBeatHz: clampBeat(v.beatCurve.evaluate(at: t, points: slot.curvePoints)),
                    smoothedVolume: 0.0,
                    smoothedPan: v.pan,
                    wasAudible: isAudible
                )
            } else {
                if !voiceStates[i].wasAudible && isAudible {
                    voiceStates[i].smoothedCarrierHz = clampCarrier(v.carrierCurve.evaluate(at: t, points: slot.curvePoints))
                    voiceStates[i].smoothedBeatHz = clampBeat(v.beatCurve.evaluate(at: t, points: slot.curvePoints))
                    voiceStates[i].smoothedPan = v.pan
                }
                voiceStates[i].wasAudible = isAudible
            }
        }

        for i in slot.voiceCount..<SnapshotChannel.maxVoices {
            voiceStates[i] = VoiceRenderState()
        }
        previousVoiceCount = slot.voiceCount
    }

    private func snapSmoothers(
        to timeSec: Double,
        slot slotPtr: UnsafePointer<PODSnapshotSlot>,
        snapOverrides: (master: Double, tones: Double, noise: Double, smoothOffset: Double)?
    ) {
        let slot = slotPtr.pointee
        let (audibleCount, _) = computeRouting(slot: slot)

        for i in 0..<slot.voiceCount {
            let v = slot.voices[i]
            let audible = voiceAudibleFlags[i]
            voiceStates[i].smoothedCarrierHz = clampCarrier(v.carrierCurve.evaluate(at: timeSec, points: slot.curvePoints))
            voiceStates[i].smoothedBeatHz = clampBeat(v.beatCurve.evaluate(at: timeSec, points: slot.curvePoints))
            voiceStates[i].smoothedVolume = audible ? clampUnit(v.volumeCurve.evaluate(at: timeSec, points: slot.curvePoints)) : 0.0
            voiceStates[i].smoothedPan = v.pan
            voiceStates[i].wasAudible = audible
        }
        for i in slot.voiceCount..<SnapshotChannel.maxVoices {
            voiceStates[i] = VoiceRenderState()
        }

        smoothedMasterGain = slot.masterGain
        smoothedNormFactor = 1.0 / Double(max(1, audibleCount)).squareRoot()
        smoothedNoiseVolume = slot.noise.isEnabled ? clampUnit(slot.noise.volumeCurve.evaluate(at: timeSec, points: slot.curvePoints)) : 0.0
        smoothedNoiseSmoothness = clampUnit(slot.noise.smoothnessCurve.evaluate(at: timeSec, points: slot.curvePoints))

        if let ov = snapOverrides {
            smoothedOverrideMaster = ov.master
            smoothedOverrideTones = ov.tones
            smoothedOverrideNoise = ov.noise
            smoothedOverrideSmoothOffset = ov.smoothOffset
        }
    }

    @inline(__always)
    private func clampCarrier(_ hz: Double) -> Double {
        hz.isFinite ? min(maxOscFreq, max(20.0, hz)) : 200.0
    }

    @inline(__always)
    private func clampBeat(_ hz: Double) -> Double {
        hz.isFinite ? min(maxOscFreq, max(0.0, hz)) : 10.0
    }

    @inline(__always)
    private func clampUnit(_ value: Double) -> Double {
        value.isFinite ? min(1.0, max(0.0, value)) : 0.0
    }

    @inline(__always)
    private func advancePhase(_ phase: inout Double, by inc: Double) {
        var next = phase + inc
        if next >= 1.0 || next < 0.0 || !next.isFinite {
            next -= floor(next)
            if !next.isFinite || next >= 1.0 || next < 0.0 {
                next = 0.0
            }
        }
        phase = next
    }

    @inline(__always)
    private func sessionEnvelope(at timeSec: Double, duration: Double, fadeIn: Double, fadeOut: Double) -> Double {
        guard duration > 0.0, timeSec < duration else { return 0.0 }
        let inGain = (fadeIn > 0.0 && timeSec < fadeIn) ? min(1.0, max(0.0, timeSec / fadeIn)) : 1.0
        let remaining = duration - timeSec
        let outGain = (fadeOut > 0.0 && remaining < fadeOut) ? min(1.0, max(0.0, remaining / fadeOut)) : 1.0
        return inGain * outGain
    }

    @inline(__always)
    private func softLimit(_ x: Double) -> Float {
        guard x.isFinite else { return 0.0 }
        let limited = Self.limiterCeiling * tanh(x / Self.limiterCeiling)
        guard limited.isFinite else { return 0.0 }
        return Float(min(1.0, max(-1.0, limited)))
    }
}
