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
