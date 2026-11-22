import AVFoundation
import Foundation
import MediaPlayer
import Observation
import PresetKit
import Synchronization
import SynthCore
@_exported import WaveForgeExport

/// Thread-safe RAII wrapper removing a `NotificationCenter` block observer on deinit.
private final class NotificationToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter = .default, token: any NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

/// Thread-safe RAII wrapper removing an `MPRemoteCommand` target on deinit.
private final class RemoteCommandToken: @unchecked Sendable {
    private let command: MPRemoteCommand
    private let target: Any

    init(command: MPRemoteCommand, target: Any) {
        self.command = command
        self.target = target
    }

    deinit {
        command.removeTarget(target)
    }
}

/// Owns the `AVAudioEngine` instance so deallocation stops audio cleanly outside `@MainActor`.
private final class AudioEngineHolder: @unchecked Sendable {
    let engine = AVAudioEngine()
    var sourceNode: AVAudioSourceNode?

    deinit {
        if engine.isRunning {
            engine.stop()
        }
    }
}

/// Main-actor controller managing real-time `AVAudioEngine` playback, `AVAudioSession` policies,
/// Lock Screen Now Playing metadata, remote commands, and live UI telemetry/state synchronization.
@MainActor
@Observable
public final class AudioEngineController {
    public static let sampleRate: Double = 48_000.0
    private static let pollingInterval: Duration = .milliseconds(33)
    private static let pauseFadeGracePeriod: Duration = .milliseconds(30)
    private static let remoteSkipIntervalSeconds: Double = 30.0
    private static let nowPlayingRefreshIntervalSeconds: Double = 1.0

    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: Double = 0.0
    public private(set) var duration: Double = 0.0
    public private(set) var currentPreset: Preset
    public private(set) var liveOverrides: LiveOverrides = .identity
    public private(set) var outputRoute: AudioOutputRoute = .other
    public private(set) var showHeadphoneBanner: Bool = false
    public private(set) var lastErrorMessage: String?
    public private(set) var dominantBeatHz: Double = 0.0
    public private(set) var dominantBand: BrainwaveBand = .delta

    public let telemetryBuffer: TelemetryRingBuffer

    /// Indicates whether the active preset currently produces binaural entrainment audio.
    public var presetHasActiveBinaural: Bool {
        AudioRoutePolicy.hasActiveBinauralVoices(in: currentPreset)
    }

    @ObservationIgnored private let engineHolder = AudioEngineHolder()
    @ObservationIgnored private let renderer: SynthRenderer
    @ObservationIgnored private var notificationTokens: [NotificationToken] = []
    @ObservationIgnored private var remoteCommandTokens: [RemoteCommandToken] = []
    @ObservationIgnored private let pollingTaskBox = Mutex<Task<Void, Never>?>(nil)
    @ObservationIgnored private let pauseEngineTaskBox = Mutex<Task<Void, Never>?>(nil)
    @ObservationIgnored private var wasInterruptedWhilePlaying: Bool = false
    @ObservationIgnored private var lastNowPlayingSyncTime: Double = -.infinity

    public init(preset: Preset = PresetCatalog.builtInPresets[0]) {
        let telemetry = TelemetryRingBuffer()
        let snapshot = SnapshotCompiler.compile(preset)
        let synthRenderer = SynthRenderer(
            sampleRate: Self.sampleRate,
            snapshot: snapshot,
            telemetry: telemetry
        )

        self.currentPreset = preset
        self.duration = snapshot.durationSec
        self.telemetryBuffer = telemetry
        self.renderer = synthRenderer

        let initialBeat = synthRenderer.dominantBeatHz(at: 0.0)
        self.dominantBeatHz = initialBeat
        self.dominantBand = BrainwaveBand.from(frequencyHz: initialBeat)

        configureAudioSessionCategory()
        refreshOutputRoute()
        configureAudioEngineGraph()
        registerNotifications()
        registerRemoteCommands()
        updateNowPlayingInfo(force: true)
    }

    deinit {
        pollingTaskBox.withLock {
            $0?.cancel()
            $0 = nil
        }
        pauseEngineTaskBox.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    // MARK: - Transport & Preset Control

    /// Loads `preset`, resetting transport position to `0.0` in a paused state.
    public func load(_ preset: Preset) {
        cancelPauseEngineTask()
        stopPolling()
        wasInterruptedWhilePlaying = false

        renderer.setPlaying(false)
        let snapshot = SnapshotCompiler.compile(preset)
        renderer.applySnapshot(snapshot)
        renderer.seek(to: 0.0)

        currentPreset = preset
        duration = snapshot.durationSec
        currentTime = 0.0
        isPlaying = false
        showHeadphoneBanner = false
        lastErrorMessage = nil

        if engineHolder.engine.isRunning {
            engineHolder.engine.pause()
        }

        refreshDominantState()
        updateNowPlayingInfo(force: true)
    }

    /// Starts or resumes audio playback from the current transport timestamp.
    public func play() {
        cancelPauseEngineTask()
        wasInterruptedWhilePlaying = false

        if duration > 0.0, currentTime >= duration - 0.001 {
            seek(to: 0.0)
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            refreshOutputRoute()
        } catch {
            lastErrorMessage = error.localizedDescription
            isPlaying = false
            updateNowPlayingInfo(force: true)
            return
        }

        do {
            if !engineHolder.engine.isRunning {
                engineHolder.engine.prepare()
                try engineHolder.engine.start()
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            isPlaying = false
            updateNowPlayingInfo(force: true)
            return
        }

        lastErrorMessage = nil
        showHeadphoneBanner = false
        renderer.setPlaying(true)
        isPlaying = true
        startPolling()
        updateNowPlayingInfo(force: true)
    }

    /// Smoothly fades out and pauses playback while retaining the current timestamp.
    public func pause() {
        wasInterruptedWhilePlaying = false
        performPause(fadeBeforeStoppingEngine: true)
    }

    /// Toggles between playing and paused transport states.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seeks cleanly to `timeSec`, clamped within `[0, duration]`.
    public func seek(to timeSec: Double) {
        let clamped = timeSec.isFinite ? min(duration, max(0.0, timeSec)) : 0.0
        renderer.seek(to: clamped)
        currentTime = clamped
        refreshDominantState()
        updateNowPlayingInfo(force: true)
    }

    /// Relative jump from `currentTime` by `deltaSec` seconds (e.g., `-30` or `+30`).
    public func skip(by deltaSec: Double) {
        let delta = deltaSec.isFinite ? deltaSec : 0.0
        seek(to: currentTime + delta)
    }

    /// Hot-swaps an edited preset lock-free into the running synthesizer without interrupting playback.
    public func applyEditedPreset(_ preset: Preset) {
        let snapshot = SnapshotCompiler.compile(preset)
        renderer.applySnapshot(snapshot)

        currentPreset = preset
        duration = snapshot.durationSec
        if currentTime > duration {
            renderer.seek(to: duration)
            currentTime = duration
        }

        refreshDominantState()
        updateNowPlayingInfo(force: true)
    }

    /// Updates live player performance multipliers (`Master`, `Tones`, `Noise`, `Noise Color`).
    public func updateOverrides(_ overrides: LiveOverrides) {
        let sanitized = LiveOverrides(
            masterGain: overrides.masterGain.isFinite ? min(1.0, max(0.0, overrides.masterGain)) : 1.0,
            tonesGain: overrides.tonesGain.isFinite ? min(2.0, max(0.0, overrides.tonesGain)) : 1.0,
            noiseGain: overrides.noiseGain.isFinite ? min(2.0, max(0.0, overrides.noiseGain)) : 1.0,
            noiseSmoothnessOffset: overrides.noiseSmoothnessOffset.isFinite
                ? min(1.0, max(-1.0, overrides.noiseSmoothnessOffset))
                : 0.0
        )
        liveOverrides = sanitized
        renderer.updateOverrides(sanitized)
    }

    /// Dismisses the automatic headphone-disconnect warning banner.
    public func dismissHeadphoneBanner() {
        showHeadphoneBanner = false
    }

    /// Clears the last surfaced runtime audio error message.
    public func clearError() {
        lastErrorMessage = nil
    }

    // MARK: - Graph & Session Configuration

    private func configureAudioSessionCategory() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshOutputRoute() {
        let portTypes = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        outputRoute = AudioRoutePolicy.classifyRoute(portTypes: portTypes)
    }

    private func configureAudioEngineGraph() {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            lastErrorMessage = ExportError.audioFormatUnavailable.localizedDescription
            return
        }

        let capturedRenderer = self.renderer
        let node = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let requestedFrames = Int(frameCount)
            guard ablPointer.count >= 2,
                  let leftData = ablPointer[0].mData,
                  let rightData = ablPointer[1].mData else {
                for buffer in ablPointer {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }

            let floatStride = MemoryLayout<Float>.stride
            let capacityL = Int(ablPointer[0].mDataByteSize) / floatStride
            let capacityR = Int(ablPointer[1].mDataByteSize) / floatStride
            let safeFrames = min(requestedFrames, min(capacityL, capacityR))

            let leftPtr = leftData.assumingMemoryBound(to: Float.self)
            let rightPtr = rightData.assumingMemoryBound(to: Float.self)
            capturedRenderer.render(intoLeft: leftPtr, intoRight: rightPtr, frameCount: safeFrames)
            return noErr
        }

        engineHolder.sourceNode = node
        engineHolder.engine.attach(node)
        do {
            try engineHolder.engine.connectNode(node, to: engineHolder.engine.mainMixerNode, format: sourceFormat)
            engineHolder.engine.prepare()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Notifications & Route / Interruption Policy

    private func registerNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        let inactiveObserver = center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext
            MainActor.assumeIsolated {
                self?.handleSessionDeactivated(context: context)
            }
        }

        let resumptionObserver = center.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                as? AVAudioSession.ResumptionContext
            MainActor.assumeIsolated {
                self?.handleResumptionRecommendation(context: context)
            }
        }

        let routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }

        let configObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engineHolder.engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEngineConfigurationChange()
            }
        }

        notificationTokens = [
            NotificationToken(center: center, token: inactiveObserver),
            NotificationToken(center: center, token: resumptionObserver),
            NotificationToken(center: center, token: routeObserver),
            NotificationToken(center: center, token: configObserver),
        ]
    }

    private func handleSessionDeactivated(context: AVAudioSession.DeactivationContext?) {
        if let context, context.source == .app {
            return
        }
        if isPlaying {
            wasInterruptedWhilePlaying = true
            performPause(fadeBeforeStoppingEngine: false)
        }
    }

    private func handleResumptionRecommendation(context: AVAudioSession.ResumptionContext?) {
        let shouldResume = (context?.recommendation == .shouldResume)
        let resumeAfterInterruption = wasInterruptedWhilePlaying && shouldResume
        wasInterruptedWhilePlaying = false
        if resumeAfterInterruption {
            play()
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        refreshOutputRoute()

        let reason = reasonRaw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let isOldDeviceUnavailable = (reason == .oldDeviceUnavailable)

        if isPlaying && AudioRoutePolicy.shouldAutoPauseOnRouteChange(
            reasonIsOldDeviceUnavailable: isOldDeviceUnavailable,
            presetHasActiveBinaural: presetHasActiveBinaural
        ) {
            pause()
            showHeadphoneBanner = true
        } else if outputRoute == .headphones {
            showHeadphoneBanner = false
        }
    }

    private func handleEngineConfigurationChange() {
        refreshOutputRoute()
        guard isPlaying, !engineHolder.engine.isRunning else { return }

        do {
            engineHolder.engine.prepare()
            try engineHolder.engine.start()
        } catch {
            lastErrorMessage = error.localizedDescription
            performPause(fadeBeforeStoppingEngine: false)
        }
    }

    // MARK: - Polling & Pause Lifecycle

    private func performPause(fadeBeforeStoppingEngine: Bool) {
        stopPolling()
        cancelPauseEngineTask()

        renderer.setPlaying(false)
        isPlaying = false
        currentTime = renderer.currentTimeSeconds()
        refreshDominantState()
        updateNowPlayingInfo(force: true)

        if fadeBeforeStoppingEngine {
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.pauseFadeGracePeriod)
                guard let self, !Task.isCancelled, !self.isPlaying else { return }
                if self.engineHolder.engine.isRunning {
                    self.engineHolder.engine.pause()
                }
            }
            pauseEngineTaskBox.withLock { $0 = task }
        } else if engineHolder.engine.isRunning {
            engineHolder.engine.pause()
        }
    }

    private func startPolling() {
        stopPolling()
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                self.syncFromRenderer()
                try? await Task.sleep(for: Self.pollingInterval)
            }
        }
        pollingTaskBox.withLock { $0 = task }
    }

    private func stopPolling() {
        pollingTaskBox.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    private func cancelPauseEngineTask() {
        pauseEngineTaskBox.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    private func syncFromRenderer() {
        let time = renderer.currentTimeSeconds()
        currentTime = time
        refreshDominantState()

        if duration > 0.0, time >= duration {
            currentTime = duration
            pause()
            return
        }

        if abs(time - lastNowPlayingSyncTime) >= Self.nowPlayingRefreshIntervalSeconds {
            updateNowPlayingInfo(force: false)
        }
    }

    private func refreshDominantState() {
        let beat = renderer.dominantBeatHz(at: currentTime)
        dominantBeatHz = beat
        dominantBand = BrainwaveBand.from(frequencyHz: beat)
    }

    // MARK: - Lock Screen NowPlaying & Remote Commands

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.play()
            }
            return .success
        }

        center.pauseCommand.isEnabled = true
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.remoteSkipIntervalSeconds)]
        let skipForwardTarget = center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.remoteSkipIntervalSeconds
            Task { @MainActor [weak self] in
                self?.skip(by: interval)
            }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.remoteSkipIntervalSeconds)]
        let skipBackwardTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.remoteSkipIntervalSeconds
            Task { @MainActor [weak self] in
                self?.skip(by: -interval)
            }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        let scrubTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let targetTime = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: targetTime)
            }
            return .success
        }

        remoteCommandTokens = [
            RemoteCommandToken(command: center.playCommand, target: playTarget),
            RemoteCommandToken(command: center.pauseCommand, target: pauseTarget),
            RemoteCommandToken(command: center.togglePlayPauseCommand, target: toggleTarget),
            RemoteCommandToken(command: center.skipForwardCommand, target: skipForwardTarget),
            RemoteCommandToken(command: center.skipBackwardCommand, target: skipBackwardTarget),
            RemoteCommandToken(command: center.changePlaybackPositionCommand, target: scrubTarget),
        ]
    }

    private func updateNowPlayingInfo(force: Bool) {
        if !force, abs(currentTime - lastNowPlayingSyncTime) < Self.nowPlayingRefreshIntervalSeconds {
            return
        }
        lastNowPlayingSyncTime = currentTime

        let categoryLabel = localizedCategoryTitle(currentPreset.category)
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: currentPreset.name,
            MPMediaItemPropertyArtist: "WaveForge",
            MPMediaItemPropertyAlbumTitle: categoryLabel,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func localizedCategoryTitle(_ category: PresetCategory) -> String {
        switch category {
        case .focus:
            return String(localized: "Focus")
        case .relax:
            return String(localized: "Relax")
        case .sleep:
            return String(localized: "Sleep")
        case .meditation:
            return String(localized: "Meditation")
        case .study:
            return String(localized: "Study")
        case .creative:
            return String(localized: "Creative")
        case .custom:
            return String(localized: "Custom")
        }
    }
}
