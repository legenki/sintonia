import AVFoundation
import Foundation
import PresetKit
import SynthCore

/// Canonical classification of the active audio output route for headphone safety notices.
public enum AudioOutputRoute: Sendable, Equatable {
    case headphones
    case speaker
    case other
}

/// CoreAudio device transport kinds mirrored as `UInt32` FourCC values without importing `CoreAudio`.
public enum CoreAudioTransportKind: UInt32, Sendable, Equatable {
    case builtIn = 0x626C_746E     // 'bltn'
    case bluetooth = 0x626C_7565   // 'blue'
    case bluetoothLE = 0x626C_6561 // 'blea'
    case usb = 0x7573_6220         // 'usb '
    case airPlay = 0x6169_7270     // 'airp'
    case displayPort = 0x6470_7274 // 'dprt'
    case hdmi = 0x6864_6D69        // 'hdmi'
    case virtual = 0x7669_7274     // 'virt'
    case aggregate = 0x6772_7570   // 'grup'
    case other = 0
}

/// Candidate macOS audio output device evaluated by `AudioDeviceSelectionPolicy`.
public struct AudioDeviceCandidate: Sendable, Equatable {
    public let uid: String
    public let route: AudioOutputRoute

    public init(uid: String, route: AudioOutputRoute) {
        self.uid = uid
        self.route = route
    }
}

/// Outcome of resolving a preferred output device UID against currently available devices.
public struct AudioDeviceSelectionResult: Sendable, Equatable {
    public let resolvedUID: String?
    public let activeRoute: AudioOutputRoute
    public let didLoseSelectedDevice: Bool

    public init(resolvedUID: String?, activeRoute: AudioOutputRoute, didLoseSelectedDevice: Bool) {
        self.resolvedUID = resolvedUID
        self.activeRoute = activeRoute
        self.didLoseSelectedDevice = didLoseSelectedDevice
    }
}

/// Pure selection resolver for preferred vs. system-default output devices.
public enum AudioDeviceSelectionPolicy {
    /// Resolves the active device UID and output route, falling back to system default if a selected device disappears.
    public static func resolveSelection(
        selectedUID: String?,
        availableDevices: [AudioDeviceCandidate],
        systemDefaultUID: String?
    ) -> AudioDeviceSelectionResult {
        if let selectedUID,
           let matched = availableDevices.first(where: { $0.uid == selectedUID }) {
            return AudioDeviceSelectionResult(
                resolvedUID: matched.uid,
                activeRoute: matched.route,
                didLoseSelectedDevice: false
            )
        }

        let fallbackRoute = systemDefaultUID
            .flatMap { defaultUID in availableDevices.first(where: { $0.uid == defaultUID })?.route }
            ?? availableDevices.first?.route
            ?? .other

        return AudioDeviceSelectionResult(
            resolvedUID: nil,
            activeRoute: fallbackRoute,
            didLoseSelectedDevice: selectedUID != nil
        )
    }
}

/// Pure route classification and auto-pause policy evaluated on audio route changes.
public enum AudioRoutePolicy {
    #if os(iOS)
    private static let headphonePortRawValues: Set<String> = [
        AVAudioSession.Port.headphones.rawValue,
        AVAudioSession.Port.bluetoothA2DP.rawValue,
        AVAudioSession.Port.bluetoothHFP.rawValue,
        AVAudioSession.Port.bluetoothLE.rawValue,
        AVAudioSession.Port.usbAudio.rawValue,
    ]

    private static let speakerPortRawValues: Set<String> = [
        AVAudioSession.Port.builtInSpeaker.rawValue,
    ]

    /// Maps active `AVAudioSession` output ports into a simplified `AudioOutputRoute`.
    public static func classifyRoute(portTypes: [AVAudioSession.Port]) -> AudioOutputRoute {
        classifyPortRawValues(portTypes.map(\.rawValue))
    }
    #else
    private static let headphonePortRawValues: Set<String> = [
        "Headphones",
        "BluetoothA2DPOutput",
        "BluetoothHFP",
        "BluetoothLE",
        "USBAudio",
    ]

    private static let speakerPortRawValues: Set<String> = [
        "Speaker",
    ]
    #endif

    /// Pure string-based port classifier shared across iOS and macOS unit tests.
    public static func classifyPortRawValues(_ rawValues: [String]) -> AudioOutputRoute {
        if rawValues.contains(where: headphonePortRawValues.contains) {
            return .headphones
        }
        if rawValues.contains(where: speakerPortRawValues.contains) {
            return .speaker
        }
        return .other
    }

    /// Returns `true` when disconnecting an output device should auto-pause binaural playback.
    public static func shouldAutoPauseOnRouteChange(
        reasonIsOldDeviceUnavailable: Bool,
        presetHasActiveBinaural: Bool
    ) -> Bool {
        reasonIsOldDeviceUnavailable && presetHasActiveBinaural
    }

    /// Maps a CoreAudio transport kind and wired jack state into a canonical `AudioOutputRoute`.
    public static func classifyCoreAudioRoute(
        transport: CoreAudioTransportKind,
        hasWiredHeadphonesConnected: Bool
    ) -> AudioOutputRoute {
        switch transport {
        case .builtIn:
            hasWiredHeadphonesConnected ? .headphones : .speaker
        case .bluetooth, .bluetoothLE, .usb:
            .headphones
        case .airPlay, .displayPort, .hdmi, .virtual, .aggregate, .other:
            .other
        }
    }

    /// Returns `true` when a macOS route transition drops active headphone playback for a binaural preset.
    public static func shouldAutoPauseOnMacRouteTransition(
        previousRoute: AudioOutputRoute,
        newRoute: AudioOutputRoute,
        selectedDeviceWasRemoved: Bool,
        isPlaying: Bool,
        presetHasActiveBinaural: Bool
    ) -> Bool {
        guard isPlaying, presetHasActiveBinaural, previousRoute == .headphones else {
            return false
        }
        return newRoute != .headphones || selectedDeviceWasRemoved
    }

    /// Returns `true` if any audible voice (within `SynthSnapshot.maxVoices`) runs in `.binaural` mode.
    public static func hasActiveBinauralVoices(in preset: Preset) -> Bool {
        let activeVoices = preset.voices.prefix(SynthSnapshot.maxVoices)
        let hasSolo = activeVoices.contains { $0.isEnabled && $0.isSolo }
        return activeVoices.contains { voice in
            voice.isEnabled
                && !voice.isMuted
                && (!hasSolo || voice.isSolo)
                && voice.mode == .binaural
        }
    }
}
