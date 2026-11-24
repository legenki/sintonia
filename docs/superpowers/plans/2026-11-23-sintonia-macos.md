# Sintonia macOS 27 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native App Store–ready **macOS 27.2** desktop version of **Sintonia** (`SintoniaMac` + `SintoniaMacTests`) reusing the existing `SintoniaCore` DSP/preset/export engine, featuring a compact Player window alongside resizable Library and dual-pane Studio/Curve Editor windows, system Menu Bar mini-player, CoreAudio HAL output device selection with binaural headphone auto-pause, native menus/shortcuts, drag-and-drop, and full EN+RU localization—while keeping the iOS `Sintonia` target 100% green.

**Architecture:** Option A adds native `SintoniaMac` (`PRODUCT_NAME = Sintonia`, Bundle ID `com.sintonia.mac`) and `SintoniaMacTests` targets alongside `Sintonia` and `SintoniaTests` in `project.yml`. Shared audio/export route classification rules live in `SintoniaExport` (`AudioRoutePolicy.swift`), CoreAudio HAL enumeration/binding lives in `AudioRuntime/MacAudioDeviceManager.swift` (`#if os(macOS)`), shared `StudioUI` views shed direct `UIKit` imports via `PlatformViewModifiers.swift` and `StudioControlHaptics`, and macOS-specific multi-window orchestration (`MacAppCoordinator`), `MenuBarExtra`, `Commands`, and window wrappers live in `App/Sources/MacUI/` and `App/Mac/`.

**Tech Stack:** Swift 6.4 (`SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`), SwiftUI (macOS 27.2 SDK / Liquid Glass), AVFoundation, CoreAudio HAL, MediaPlayer, AppKit (`NSHapticFeedbackManager`, `NSApp`), Swift Testing (`Testing`), XcodeGen 2.48. Zero external third-party packages.

**Spec:** `docs/superpowers/specs/2026-11-23-sintonia-macos-design.md`

---

## Global Constraints

- Minimum deployment targets: `MACOSX_DEPLOYMENT_TARGET = 27.2` for `SintoniaMac` / `SintoniaMacTests`; preserve `IPHONEOS_DEPLOYMENT_TARGET = 27.2` for `Sintonia` / `SintoniaTests` (`Xcode 27.2`, Swift 6 strict concurrency, warnings as errors).
- Zero external third-party packages (Apple system frameworks only).
- Bundle IDs: `com.sintonia.app` (iOS), `com.sintonia.mac` (macOS), `com.sintonia.tests` (iOS tests), `com.sintonia.mac.tests` (macOS tests).
- Mac App Sandbox entitlements (`App/Mac/SintoniaMac.entitlements`): `com.apple.security.app-sandbox = true`, `com.apple.security.files.user-selected.read-write = true` (no network or audio-input entitlements).
- Privacy manifest (`App/Resources/PrivacyInfo.xcprivacy`): `NSPrivacyTracking = false`, empty `NSPrivacyTrackingDomains` and `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPICategoryDiskSpace` with reason `E174.1` (replacing `85F4.1`), bundled in both iOS and macOS `.app` resources.
- Document UTIs (`App/Mac/Info.plist` via `project.yml`): `LSApplicationCategoryType = public.app-category.music`, `com.sintonia.preset` (`.sintonia`), `com.noromaa.bwg` (`.bwg` conforming to `public.data`, `public.content`).
- Localization: English (`en`) and Russian (`ru`) in shared `App/Resources/Localizable.xcstrings`; canonical 18 built-in preset names stay English; App Store Guideline 1.4.1 non-medical wellness disclaimer in `AboutSheetView` accessible from `Sintonia → About Sintonia`.
- Real-time audio safety: `SynthRenderer.render` and `AVAudioSourceNode` callback remain lock-free, allocation-free, and non-blocking on both platforms.
- Explicitly out of scope for v1: Floating / Always-on-Top Player window mode, external `.wav` nature loops, visual strobe / AudioStrobe, AUv3 extension, iCloud/accounts.
- Sandbox build flags: pass `--disable-sandbox` to `swift test`; pass `-derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO` plus platform-appropriate `-load-plugin-library` flags for `libObservationMacros.dylib` and `libSwiftUIMacros.dylib` (`MacOSX.platform` for macOS, `iPhoneOS.platform` for iOS) to `xcodebuild`; omit `#Preview` blocks so sandboxed macro expansion stays reliable.

## Review Focus

1. Disconnecting explicitly selected or system-default headphones (wired jack, AirPods, USB DAC) during active binaural playback → auto-pauses immediately, raises `showHeadphoneBanner`, and falls back `selectedOutputDeviceUID` to System Default (`nil`) so subsequent `play()` does not error (pinned in Task 1 & Task 6).
2. Switching presets from Library, Menu Bar, or Finder `.onOpenURL` while Studio Rack has unsaved edits → intercepts switch and presents Save / Discard / Cancel confirmation instead of silently dropping edits (pinned in Task 5 & Task 6).
3. Pressing `Space` while typing inside Library search bar or Studio text fields (`Preset Name`, `Voice Name`) → inserts a space normally without triggering Play/Pause shortcut (`@FocusedValue(\.isTextInputFocused)` + AppKit `firstResponder` guard; pinned in Task 5 & Task 6).
4. Dropping or opening invalid/corrupted files (`.txt`, empty/truncated `.bwg`) or multi-file drop onto Player/Library → rejects cleanly with localized `ImportResultAlert` while leaving current playback and `PresetStore` intact (pinned in Task 5 & Task 6).
5. Launching macOS app with a stale persisted `selectedOutputDeviceUID` in `UserDefaults` or zero available hardware audio output devices → falls back cleanly to System Default without crashing or falsely claiming `.headphones` (pinned in Task 1, Task 2 & Task 6).

---

## File Structure

- `Packages/SintoniaCore/Sources/SintoniaExport/AudioRoutePolicy.swift` — Add `CoreAudioTransportKind`, `AudioDeviceCandidate`, `AudioDeviceSelectionResult`, `AudioDeviceSelectionPolicy`, `classifyCoreAudioRoute`, and `shouldAutoPauseOnMacRouteTransition`.
- `Packages/SintoniaCore/Tests/SintoniaExportTests/SintoniaExportTests.swift` — Unit tests for CoreAudio transport classification, device selection/fallback, and macOS binaural disconnect auto-pause.
- `App/Resources/PrivacyInfo.xcprivacy` — Update `NSPrivacyAccessedAPICategoryDiskSpace` reason from `85F4.1` to `E174.1`.
- `App/Sources/AudioRuntime/MacAudioDeviceManager.swift` — `#if os(macOS)` `AudioOutputDevice` and `MacAudioDeviceManager` (CoreAudio HAL enumeration, output device binding via `kAudioOutputUnitProperty_CurrentDevice`, real-time listeners, `UserDefaults` UID persistence).
- `App/Sources/AudioRuntime/AudioEngineController.swift` — Conditionalize `#if os(iOS)` (`AVAudioSession`) vs `#if os(macOS)` (`MacAudioDeviceManager`), expose `availableOutputDevices` / `selectedOutputDeviceUID` / `selectOutputDevice(uid:)`, and sync `MPNowPlayingInfoCenter.playbackState` on macOS.
- `App/Sources/StudioUI/PlatformViewModifiers.swift` — Cross-platform view modifiers (`wfInlineNavigationBarDark()`, `wfSearchable(text:prompt:)`, `wfIsCompactLandscape`) and shared `TextInputFocusKey` (`FocusedValues.isTextInputFocused`).
- `App/Sources/StudioUI/Components/StudioTheme.swift` — Conditionalize `StudioControlHaptics` using `NSHapticFeedbackManager` on macOS and `UIImpactFeedbackGenerator` on iOS; remove unconditional `import UIKit`.
- `App/Sources/StudioUI/Components/{HardwarePickers,OscilloscopeView,StudioKnob,StudioFader}.swift` — Replace direct `UIImpactFeedbackGenerator` with `StudioControlHaptics`; add macOS hover/Option/Shift fine-tune + double-click ergonomics.
- `App/Sources/StudioUI/Player/{MiniTimelineScrubber,PlayerView,ExportSheetView,AboutSheetView}.swift` — Remove `import UIKit`, use `.wfInlineNavigationBarDark()`, add `headerAccessory` slot on `PlayerView`, and add native macOS `.fileExporter` (`Save As…`) on `ExportSheetView`.
- `App/Sources/StudioUI/Studio/{StudioRackView,VoiceInspectorView,CurveEditorView,CurveEditorCanvas}.swift` — Remove `import UIKit`, isolate `verticalSizeClass` to iOS, track text focus via `.focusedValue(\.isTextInputFocused, ...)`, add desktop dual-pane split layout (`width >= 880` when `showsDualPaneWhenWide`), `externalSyncTrigger` / `onDirtyStateChanged` / `onRegisterSaveHandler` hooks on `StudioRackView`, and right-click point delete menu in `CurveEditorCanvas`.
- `App/Sources/StudioUI/Library/{LibraryView,ImportResultAlert}.swift` — Use `wfInlineNavigationBarDark()` / `wfSearchable()`, propagate search text focus, add `adaptiveDesktopGrid`, `hidesDoneButton`, `loadsDirectlyOnSelect`, `onDoubleClickPreset`, `onCreateNewTemplate`, and macOS `.fileExporter` for `.sintonia`.
- `App/iOS/SintoniaIOSApp.swift` — Moved iOS `@main` entry point from `App/Sources/StudioUI/SintoniaApp.swift`.
- `App/Mac/{SintoniaMacApp.swift,SintoniaMac.entitlements,Info.plist}` — macOS `@main` entry point (`Window("player")`, `Window("library")`, `Window("studio")`, `MenuBarExtra`, `Commands`), App Sandbox entitlements, and XcodeGen-managed macOS `Info.plist`.
- `App/Sources/MacUI/{MacAppCoordinator,MacOutputDeviceMenu,MacPlayerWindowView,MacLibraryWindowView,MacStudioWindowView,MacMenuBarView,MacCommands}.swift` — Shared window coordinator, CoreAudio output menu, three hybrid desktop windows, Menu Bar mini-player, native commands/shortcuts, and drag-and-drop.
- `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` — Add macOS app icon slots (`16x16`–`512x512` 1x/2x) alongside universal iOS `1024x1024`.
- `App/Resources/Localizable.xcstrings` — Add complete EN + RU translations for all macOS strings while preserving existing iOS translations.
- `App/Tests/MacRuntimeTests/MacRuntimeTests.swift` — Native macOS 27.2 Swift Testing suite verifying runtime, CoreAudio device policy, coordinator, shortcuts guard, import rejections, and localization.
- `project.yml` — Declare `SintoniaMac` + `SintoniaMacTests` alongside `Sintonia` + `SintoniaTests`.

---

### Task 1: CoreAudio Route Policy & Privacy Manifest (`E174.1`)

**Files:**
- Modify: `Packages/SintoniaCore/Sources/SintoniaExport/AudioRoutePolicy.swift`
- Modify: `App/Resources/PrivacyInfo.xcprivacy`
- Test: `Packages/SintoniaCore/Tests/SintoniaExportTests/SintoniaExportTests.swift`

**Interfaces:**
- Consumes: `Foundation`, `AVFoundation`, `PresetKit`, `SynthCore`
- Produces in `SintoniaExport`:
  - `public enum CoreAudioTransportKind: UInt32, Sendable, Equatable` (`.builtIn`, `.bluetooth`, `.bluetoothLE`, `.usb`, `.airPlay`, `.displayPort`, `.hdmi`, `.virtual`, `.aggregate`, `.other`)
  - `public struct AudioDeviceCandidate: Sendable, Equatable` (`public let uid: String`, `public let route: AudioOutputRoute`, `public init(uid: String, route: AudioOutputRoute)`)
  - `public struct AudioDeviceSelectionResult: Sendable, Equatable` (`public let resolvedUID: String?`, `public let activeRoute: AudioOutputRoute`, `public let didLoseSelectedDevice: Bool`)
  - `public enum AudioDeviceSelectionPolicy` (`public static func resolveSelection(selectedUID: String?, availableDevices: [AudioDeviceCandidate], systemDefaultUID: String?) -> AudioDeviceSelectionResult`)
  - `AudioRoutePolicy.classifyCoreAudioRoute(transport: CoreAudioTransportKind, hasWiredHeadphonesConnected: Bool) -> AudioOutputRoute`
  - `AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(previousRoute: AudioOutputRoute, newRoute: AudioOutputRoute, selectedDeviceWasRemoved: Bool, isPlaying: Bool, presetHasActiveBinaural: Bool) -> Bool`

- [ ] **Step 1: Write failing CoreAudio policy & device selection tests in `SintoniaExportTests.swift`**

Add 3 tests to `Packages/SintoniaCore/Tests/SintoniaExportTests/SintoniaExportTests.swift`:
```swift
@Test func coreAudioTransportClassificationDistinguishesWiredJackBluetoothUSBAndSpeakers() {
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .builtIn, hasWiredHeadphonesConnected: true) == .headphones)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .builtIn, hasWiredHeadphonesConnected: false) == .speaker)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .bluetooth, hasWiredHeadphonesConnected: false) == .headphones)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .bluetoothLE, hasWiredHeadphonesConnected: false) == .headphones)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .usb, hasWiredHeadphonesConnected: false) == .headphones)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .airPlay, hasWiredHeadphonesConnected: false) == .other)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .displayPort, hasWiredHeadphonesConnected: false) == .other)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .hdmi, hasWiredHeadphonesConnected: false) == .other)
    #expect(AudioRoutePolicy.classifyCoreAudioRoute(transport: .virtual, hasWiredHeadphonesConnected: false) == .other)
}

@Test func deviceSelectionPolicyResolvesSelectedUIDAndFallsBackCleanlyWhenLostOrEmpty() {
    let speakers = AudioDeviceCandidate(uid: "builtin-spk", route: .speaker)
    let airpods = AudioDeviceCandidate(uid: "bt-airpods", route: .headphones)

    let systemResult = AudioDeviceSelectionPolicy.resolveSelection(
        selectedUID: nil, availableDevices: [speakers, airpods], systemDefaultUID: "builtin-spk"
    )
    #expect(systemResult == AudioDeviceSelectionResult(resolvedUID: nil, activeRoute: .speaker, didLoseSelectedDevice: false))

    let explicitResult = AudioDeviceSelectionPolicy.resolveSelection(
        selectedUID: "bt-airpods", availableDevices: [speakers, airpods], systemDefaultUID: "builtin-spk"
    )
    #expect(explicitResult == AudioDeviceSelectionResult(resolvedUID: "bt-airpods", activeRoute: .headphones, didLoseSelectedDevice: false))

    let lostResult = AudioDeviceSelectionPolicy.resolveSelection(
        selectedUID: "usb-dac-gone", availableDevices: [speakers], systemDefaultUID: "builtin-spk"
    )
    #expect(lostResult == AudioDeviceSelectionResult(resolvedUID: nil, activeRoute: .speaker, didLoseSelectedDevice: true))

    let emptyResult = AudioDeviceSelectionPolicy.resolveSelection(
        selectedUID: "stale", availableDevices: [], systemDefaultUID: nil
    )
    #expect(emptyResult == AudioDeviceSelectionResult(resolvedUID: nil, activeRoute: .other, didLoseSelectedDevice: true))
}

@Test func macRouteTransitionAutoPauseTriggersOnlyWhenBinauralLosesHeadphonesDuringPlayback() {
    #expect(AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(
        previousRoute: .headphones, newRoute: .speaker, selectedDeviceWasRemoved: false, isPlaying: true, presetHasActiveBinaural: true
    ))
    #expect(AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(
        previousRoute: .headphones, newRoute: .headphones, selectedDeviceWasRemoved: true, isPlaying: true, presetHasActiveBinaural: true
    ))
    #expect(!AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(
        previousRoute: .speaker, newRoute: .headphones, selectedDeviceWasRemoved: false, isPlaying: true, presetHasActiveBinaural: true
    ))
    #expect(!AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(
        previousRoute: .headphones, newRoute: .speaker, selectedDeviceWasRemoved: false, isPlaying: false, presetHasActiveBinaural: true
    ))
    #expect(!AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(
        previousRoute: .headphones, newRoute: .speaker, selectedDeviceWasRemoved: false, isPlaying: true, presetHasActiveBinaural: false
    ))
}
```

- [ ] **Step 2: Run SwiftPM tests to verify failure**

Run: `swift test --disable-sandbox --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore`
Expected: FAIL to compile (`CoreAudioTransportKind` and `AudioDeviceSelectionPolicy` not defined).

- [ ] **Step 3: Implement CoreAudio policy types in `AudioRoutePolicy.swift` and update `PrivacyInfo.xcprivacy`**

1. Add `CoreAudioTransportKind`, `AudioDeviceCandidate`, `AudioDeviceSelectionResult`, `AudioDeviceSelectionPolicy`, `AudioRoutePolicy.classifyCoreAudioRoute(transport:hasWiredHeadphonesConnected:)`, and `AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(...)` in `Packages/SintoniaCore/Sources/SintoniaExport/AudioRoutePolicy.swift` without importing `CoreAudio`.
2. In `App/Resources/PrivacyInfo.xcprivacy`, replace `<string>85F4.1</string>` with `<string>E174.1</string>`.

- [ ] **Step 4: Run SwiftPM tests and verify privacy plist**

Run:
```bash
swift test --disable-sandbox --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore
plutil -lint /Users/andy/.gemini/antigravity/scratch/Sintonia/App/Resources/PrivacyInfo.xcprivacy
grep -n "E174.1" /Users/andy/.gemini/antigravity/scratch/Sintonia/App/Resources/PrivacyInfo.xcprivacy
```
Expected: All SwiftPM tests pass (`0` failures); `PrivacyInfo.xcprivacy: OK` containing `E174.1`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add Packages/SintoniaCore/Sources/SintoniaExport/AudioRoutePolicy.swift Packages/SintoniaCore/Tests/SintoniaExportTests/SintoniaExportTests.swift App/Resources/PrivacyInfo.xcprivacy
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(SintoniaExport): add CoreAudio route selection policy and update PrivacyInfo to E174.1"
```

---

### Task 2: `MacAudioDeviceManager` & Cross-Platform `AudioEngineController`

**Files:**
- Create: `App/Sources/AudioRuntime/MacAudioDeviceManager.swift`
- Modify: `App/Sources/AudioRuntime/AudioEngineController.swift`

**Interfaces:**
- Consumes: `SintoniaExport` (`AudioOutputRoute`, `CoreAudioTransportKind`, `AudioDeviceCandidate`, `AudioDeviceSelectionPolicy`), `CoreAudio`, `AudioToolbox`, `AVFoundation`, `MediaPlayer`
- Produces:
  - `#if os(macOS) public struct AudioOutputDevice: Identifiable, Hashable, Sendable` (`id: String`, `deviceID: UInt32`, `uid: String`, `name: String`, `route: AudioOutputRoute`, `isSystemDefault: Bool`)
  - `#if os(macOS) @MainActor @Observable public final class MacAudioDeviceManager` (`init(userDefaults: UserDefaults = .standard, startHardwareMonitoring: Bool = true)`, `availableDevices: [AudioOutputDevice]`, `selectedDeviceUID: String?`, `currentRoute: AudioOutputRoute`, `onRouteStateChanged: ((_ previousRoute: AudioOutputRoute, _ newRoute: AudioOutputRoute, _ selectedDeviceWasRemoved: Bool) -> Void)?`, `func selectDevice(uid: String?, for engine: AVAudioEngine) throws`, `func bindCurrentDevice(to engine: AVAudioEngine) throws`, `func applySnapshotForTesting(devices: [AudioOutputDevice], defaultUID: String?)`)
  - `AudioEngineController`:
    - `#if os(macOS)`: `public var availableOutputDevices: [AudioOutputDevice]`, `public var selectedOutputDeviceUID: String?`, `public func selectOutputDevice(uid: String?)`, `internal func applyMacDeviceSnapshotForTesting(devices: [AudioOutputDevice], defaultUID: String?)`
    - On both iOS and macOS: `MPNowPlayingInfoCenter.default()` updates; `#if os(macOS)` sets `.playbackState = isPlaying ? .playing : .paused`.

- [ ] **Step 1: Create `App/Sources/AudioRuntime/MacAudioDeviceManager.swift` (`#if os(macOS)`)**

Guard the entire file with `#if os(macOS) ... #endif`.
- Enumerate output devices using CoreAudio (`AudioObjectGetPropertyData`):
  - `kAudioHardwarePropertyDevices` on `AudioObjectID(kAudioObjectSystemObject)`
  - Keep devices whose `kAudioDevicePropertyStreamConfiguration` (`kAudioDevicePropertyScopeOutput`) sums `mNumberChannels > 0`
  - Read `kAudioDevicePropertyDeviceUID` (CFString), `kAudioObjectPropertyName` (CFString), `kAudioDevicePropertyTransportType` (`UInt32`), and for `kAudioDeviceTransportTypeBuiltIn` read `kAudioDevicePropertyDataSource` (`'hdpn'` vs `'ispk'`) + `kAudioDevicePropertyJackIsConnected` (`UInt32 != 0`)
  - Map Apple CoreAudio `kAudioDeviceTransportType*` constants to `CoreAudioTransportKind` and classify via `AudioRoutePolicy.classifyCoreAudioRoute(transport:hasWiredHeadphonesConnected:)`
  - Read `kAudioHardwarePropertyDefaultOutputDevice` to mark `isSystemDefault` and resolve effective `AudioDeviceID` when `selectedDeviceUID == nil`
- Persist `selectedDeviceUID` in injected `UserDefaults` under `"sintonia.mac.selectedOutputDeviceUID"` and expose `applySnapshotForTesting(devices:defaultUID:)` delegating through `AudioDeviceSelectionPolicy.resolveSelection(...)` + firing `onRouteStateChanged`.
- Implement `bindCurrentDevice(to engine: AVAudioEngine)`: when target `AudioDeviceID != 0` and `outputNode.audioUnit != nil`, call `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))`; handle headless/zero-device test hosts gracefully.
- Register `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultOutputDevice`, and current built-in device's `kAudioDevicePropertyDataSource` / `kAudioDevicePropertyJackIsConnected` when `startHardwareMonitoring == true`, forwarding onto `@MainActor` and removing listener blocks cleanly on `deinit`.

- [ ] **Step 2: Update `App/Sources/AudioRuntime/AudioEngineController.swift` for iOS & macOS**

- Gate `AVAudioSession` imports/calls strictly with `#if os(iOS)`:
  - `configureAudioSessionCategory()`, `refreshOutputRoute()`, `play()`, `registerNotifications()` keep existing iOS behavior unchanged.
  - `#if os(macOS)` instantiates `MacAudioDeviceManager`, exposes `availableOutputDevices`, `selectedOutputDeviceUID`, `selectOutputDevice(uid:)`, and `@testable` helper `applyMacDeviceSnapshotForTesting(devices:defaultUID:)`, and wires `macDeviceManager.onRouteStateChanged` to `AudioRoutePolicy.shouldAutoPauseOnMacRouteTransition(...)` (auto-pausing and setting `showHeadphoneBanner = true` on headphone loss, or clearing banner on `.headphones`).
  - Keep `.AVAudioEngineConfigurationChange` shared across both platforms.
- In `updateNowPlayingInfo(force:)`: under `#if os(macOS)`, set `MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused`.

- [ ] **Step 3: Verify iOS `build-for-testing` & macOS CoreAudio typecheck**

Run:
```bash
swift test --disable-sandbox --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore
cd /Users/andy/.gemini/antigravity/scratch/Sintonia && xcodebuild build-for-testing -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'
swift build --disable-sandbox --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore
swiftc -typecheck -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macos27.2 -swift-version 6 -strict-concurrency=complete -I /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore/.build/arm64-apple-macosx/debug/Modules /Users/andy/.gemini/antigravity/scratch/Sintonia/App/Sources/AudioRuntime/MacAudioDeviceManager.swift /Users/andy/.gemini/antigravity/scratch/Sintonia/App/Sources/AudioRuntime/AudioEngineController.swift
```
Expected: SwiftPM 100% pass; iOS `** TEST BUILD SUCCEEDED **`; macOS `swiftc -typecheck` exits 0 with 0 warnings.

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/AudioRuntime/MacAudioDeviceManager.swift App/Sources/AudioRuntime/AudioEngineController.swift
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(AudioRuntime): add CoreAudio HAL MacAudioDeviceManager and cross-platform AudioEngineController"
```

---

### Task 3: Cross-Platform `StudioUI` Adaptation (`PlatformViewModifiers`, Haptics & Desktop Polish)

**Files:**
- Create: `App/Sources/StudioUI/PlatformViewModifiers.swift`
- Modify: `App/Sources/StudioUI/Components/StudioTheme.swift`
- Modify: `App/Sources/StudioUI/Components/HardwarePickers.swift`
- Modify: `App/Sources/StudioUI/Components/OscilloscopeView.swift`
- Modify: `App/Sources/StudioUI/Components/StudioKnob.swift`
- Modify: `App/Sources/StudioUI/Components/StudioFader.swift`
- Modify: `App/Sources/StudioUI/Player/MiniTimelineScrubber.swift`
- Modify: `App/Sources/StudioUI/Player/PlayerView.swift`
- Modify: `App/Sources/StudioUI/Player/ExportSheetView.swift`
- Modify: `App/Sources/StudioUI/Player/AboutSheetView.swift`
- Modify: `App/Sources/StudioUI/Studio/StudioRackView.swift`
- Modify: `App/Sources/StudioUI/Studio/VoiceInspectorView.swift`
- Modify: `App/Sources/StudioUI/Studio/CurveEditorView.swift`
- Modify: `App/Sources/StudioUI/Studio/CurveEditorCanvas.swift`
- Modify: `App/Sources/StudioUI/Library/LibraryView.swift`
- Modify: `App/Sources/StudioUI/Library/ImportResultAlert.swift`

**Interfaces:**
- Consumes: `SwiftUI`, `AudioRuntime`, `PresetKit`, `SynthCore`, `SintoniaExport`, `#if os(iOS) UIKit`, `#if os(macOS) AppKit`
- Produces:
  - `public struct TextInputFocusKey: FocusedValueKey` (`Value == Bool`) + `public extension FocusedValues { var isTextInputFocused: Bool? }`
  - `View.wfInlineNavigationBarDark()`, `View.wfSearchable(text:prompt:)`
  - `StudioControlHaptics` (unified cross-platform haptics helper replacing direct `UIImpactFeedbackGenerator` properties across `StudioUI`)
  - `PlayerView<HeaderAccessory: View>`: preserves `PlayerView(engine:onOpenLibrary:onOpenStudio:onOpenExport:onOpenAbout:)` convenience `init` when `HeaderAccessory == EmptyView` AND adds `init(..., @ViewBuilder headerAccessory: () -> HeaderAccessory)`
  - `StudioRackView`: adds `showsDualPaneWhenWide: Bool = false`, `externalSyncTrigger: UUID = UUID()`, `onDirtyStateChanged: @escaping (Bool) -> Void = { _ in }`, `onRegisterSaveHandler: @escaping ((() -> Bool)?) -> Void = { _ in }` while keeping existing iOS call sites unchanged
  - `LibraryView`: adds `adaptiveDesktopGrid: Bool = false`, `hidesDoneButton: Bool = false`, `loadsDirectlyOnSelect: Bool = true`, `onDoubleClickPreset: ((Preset) -> Void)? = nil`, `onCreateNewTemplate: ((Preset) -> Void)? = nil`, and `.fileExporter` for `.sintonia` on macOS
  - `ExportSheetView`: on `#if os(macOS)`, displays a native `"Save As…"` `.fileExporter` button alongside `ShareLink` on export completion

- [ ] **Step 1: Create `PlatformViewModifiers.swift` and update `StudioControlHaptics` in `StudioTheme.swift`**

- In `PlatformViewModifiers.swift`:
  - Define `TextInputFocusKey: FocusedValueKey` (`typealias Value = Bool`) + `extension FocusedValues { public var isTextInputFocused: Bool? }`.
  - Add `wfInlineNavigationBarDark()` (`#if os(iOS)` `.navigationBarTitleDisplayMode(.inline)` + `.toolbarColorScheme(.dark, for: .navigationBar)` / `#if os(macOS)` passthrough).
  - Add `wfSearchable(text:prompt:)` (`#if os(iOS)` `.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)` / `#if os(macOS)` `.searchable(text: text, prompt: prompt)`).
- In `StudioTheme.swift`: replace unconditional `import UIKit` with `#if os(iOS) import UIKit` + `#if os(macOS) import AppKit`, and implement macOS `StudioControlHaptics` using `NSHapticFeedbackManager.defaultPerformer.perform(.alignment/.levelChange, performanceTime: .now)`.

- [ ] **Step 2: Decouple `UIKit` & add desktop ergonomics in Components and Player views**

- Replace direct `UIImpactFeedbackGenerator` + `import UIKit` in `HardwarePickers.swift`, `OscilloscopeView.swift`, `MiniTimelineScrubber.swift`, `PlayerView.swift`, and `StudioRackView.swift` with `StudioControlHaptics`.
- In `StudioKnob.swift` & `StudioFader.swift`: add `#if os(macOS)` hover highlight (`.onHover`) and Option/Shift fine-tune trigger (`NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.shift)`) alongside offset-drag fine-tuning and double-click/tap reset.
- In `PlayerView.swift`: parameterize over `<HeaderAccessory: View>` with `headerAccessory()` placed neatly in `topGlassBar`, preserving default `PlayerView(engine:onOpenLibrary:onOpenStudio:onOpenExport:onOpenAbout:)` initializer when `HeaderAccessory == EmptyView`.
- In `ExportSheetView.swift`: use `.wfInlineNavigationBarDark()`. Inside `#if os(macOS)`, add `ExportedAudioFileDocument: FileDocument` (`UTType.wav`, `UTType.mpeg4Audio`) and `"Save As…"` `.fileExporter` button alongside `ShareLink`.
- In `AboutSheetView.swift`: use `.wfInlineNavigationBarDark()` and clean desktop minimum frame (`minWidth: 420, minHeight: 500` inside `#if os(macOS)`).

- [ ] **Step 3: Adapt `StudioRackView`, `VoiceInspectorView`, `CurveEditor`, and `LibraryView`**

- `CurveEditorCanvas.swift`: add `.contextMenu` on hits / selected control point (`Button("Delete Point", role: .destructive)` disabled when `points.count <= 1`).
- `CurveEditorView.swift` & `StudioRackView.swift`: gate `@Environment(\.verticalSizeClass)` strictly under `#if os(iOS)` (returning `false` for `isCompactLandscape` on macOS).
- `VoiceInspectorView.swift` & `StudioRackView.swift`: attach `@FocusState` to `TextField("Voice Name", ...)` and `TextField("Preset Name", ...)` publishing `.focusedValue(\.isTextInputFocused, ...)` cleanly.
- `StudioRackView.swift`: add `showsDualPaneWhenWide`, `externalSyncTrigger`, `onDirtyStateChanged`, and `onRegisterSaveHandler`:
  - Read geometry width to enable desktop dual-pane split (`width >= 880 && showsDualPaneWhenWide`): top `presetMetadataSection` + `voiceRackSection`; bottom `HStack` with `Voice/Noise` inspector column (`width: 350`) on left + persistent `CurveEditorView` on right.
  - Propagate `isDirty` via `onDirtyStateChanged`, register/unregister `{ saveDraft() }` via `onRegisterSaveHandler`, and sync `draft`/`baselinePreset`/`hasSavedInStore`/`isDirty = false` when `externalSyncTrigger` changes.
- `LibraryView.swift`: apply `.wfInlineNavigationBarDark()` & `.wfSearchable(...)`; hide `Done` toolbar item when `hidesDoneButton`; support `adaptiveDesktopGrid` (2-column `LazyVGrid` when width >= `640`, single column when narrower) with `.onTapGesture(count: 2)` calling `onDoubleClickPreset`; gate direct `engine.load(preset)` behind `loadsDirectlyOnSelect` (default `true`); invoke `onCreateNewTemplate?(template)` when provided; add macOS `"Save .sintonia…"` (`.fileExporter` using `SintoniaPresetFileDocument: FileDocument`) alongside `ShareLink`.

- [ ] **Step 4: Verify SwiftPM tests, macOS `StudioUI` typecheck, and iOS `build-for-testing`**

Run:
```bash
swift test --disable-sandbox --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore
cd /Users/andy/.gemini/antigravity/scratch/Sintonia && xcodebuild build-for-testing -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'
```
Also verify modified `AudioRuntime` + `StudioUI` files (excluding `SintoniaApp.swift`) typecheck cleanly against `-sdk macosx -target arm64-apple-macos27.2`.
Expected: SwiftPM 100% pass; iOS `** TEST BUILD SUCCEEDED **`; macOS typecheck 0 errors, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Sources/StudioUI
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "refactor(StudioUI): decouple UIKit and add cross-platform desktop controls and layouts"
```

---

### Task 4: Dual-Target XcodeGen Project (`SintoniaMac` + `SintoniaMacTests`)

**Files:**
- Move: `App/Sources/StudioUI/SintoniaApp.swift` → `App/iOS/SintoniaIOSApp.swift`
- Create: `App/Mac/SintoniaMac.entitlements`
- Create: `App/Mac/SintoniaMacApp.swift` (minimal compiling `@main` scaffold; fully wired in Task 5)
- Create: `App/Sources/MacUI/MacAppCoordinator.swift` (minimal compiling stub; completed in Task 5)
- Create: `App/Tests/MacRuntimeTests/MacRuntimeTests.swift` (smoke tests verifying bundle `PrivacyInfo.xcprivacy` `E174.1` and macOS `AudioEngineController`)
- Modify: `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Modify: `project.yml`
- Regenerate: `Sintonia.xcodeproj`

**Interfaces:**
- Produces:
  - `project.yml` with `Sintonia` (`com.sintonia.app`, iOS 27.2), `SintoniaTests` (`com.sintonia.tests`, iOS 27.2), `SintoniaMac` (`PRODUCT_NAME: Sintonia`, `com.sintonia.mac`, macOS 27.2), `SintoniaMacTests` (`com.sintonia.mac.tests`, macOS 27.2)
  - `App/Mac/SintoniaMac.entitlements` (`com.apple.security.app-sandbox = true`, `com.apple.security.files.user-selected.read-write = true`)
  - Generated `App/Mac/Info.plist` via `SintoniaMac.info.properties`
  - Passing macOS `xcodebuild test` + passing iOS `xcodebuild build-for-testing`

- [ ] **Step 1: Move iOS entry point and create Mac entitlements, AppIcon slots & scaffolds**

1. Move `App/Sources/StudioUI/SintoniaApp.swift` → `App/iOS/SintoniaIOSApp.swift` (`git mv`).
2. Create `App/Mac/SintoniaMac.entitlements` with `com.apple.security.app-sandbox = true` and `com.apple.security.files.user-selected.read-write = true`.
3. Update `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` to include macOS icon entries (`16x16`, `32x32`, `128x128`, `256x256`, `512x512` at `1x`/`2x`) alongside universal iOS `1024x1024`.
4. Add minimal compiling `App/Sources/MacUI/MacAppCoordinator.swift` + `App/Mac/SintoniaMacApp.swift` (`Window(Text("Sintonia"), id: "player")`), and smoke tests in `App/Tests/MacRuntimeTests/MacRuntimeTests.swift` verifying `PrivacyInfo.xcprivacy` (`E174.1`) in the macOS app bundle and `AudioEngineController()` initialization.

- [ ] **Step 2: Configure `Sintonia` + `SintoniaMac` targets in `project.yml`**

- Add `macOS: "27.2"` under `options.deploymentTarget` alongside `iOS: "27.2"`; scope `IPHONEOS_DEPLOYMENT_TARGET: "27.2"` to iOS targets and `MACOSX_DEPLOYMENT_TARGET: "27.2"` to macOS targets.
- `Sintonia` sources: `App/Sources/AudioRuntime`, `App/Sources/StudioUI`, `App/iOS`, `App/Resources`.
- `SintoniaMac`:
  - `type: application`, `platform: macOS`, `deploymentTarget: "27.2"`
  - `sources`: `App/Sources/AudioRuntime`, `App/Sources/StudioUI`, `App/Sources/MacUI`, `App/Mac`, `App/Resources` (excluding `SintoniaMac.entitlements` and `App/Mac/Info.plist` from resources)
  - `info`: `path: App/Mac/Info.plist`, `properties:` with `CFBundleDisplayName: Sintonia`, `CFBundleShortVersionString: $(MARKETING_VERSION)`, `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`, `LSApplicationCategoryType: public.app-category.music`, `LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)`, `NSHighResolutionCapable: true`, `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` (`com.sintonia.preset`), `UTImportedTypeDeclarations` (`com.noromaa.bwg` conforming to `public.data`, `public.content`).
  - `entitlements`: `path: App/Mac/SintoniaMac.entitlements`
  - `settings.base`: `PRODUCT_NAME: Sintonia`, `PRODUCT_BUNDLE_IDENTIFIER: com.sintonia.mac`, `MARKETING_VERSION: "1.0.0"`, `CURRENT_PROJECT_VERSION: "1"`, `CODE_SIGN_ENTITLEMENTS: App/Mac/SintoniaMac.entitlements`, `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `LOCALIZATION_PREFERS_STRING_CATALOGS: YES`, `ENABLE_HARDENED_RUNTIME: YES`.
  - `dependencies`: `SintoniaCore` (`SynthCore`, `PresetKit`, `SintoniaExport`).
- `SintoniaMacTests`:
  - `type: bundle.unit-test`, `platform: macOS`, `deploymentTarget: "27.2"`, `sources: [App/Tests/MacRuntimeTests]`, `PRODUCT_BUNDLE_IDENTIFIER: com.sintonia.mac.tests`, `GENERATE_INFOPLIST_FILE: YES`, depending on `SintoniaMac` + `SintoniaCore`.

- [ ] **Step 3: Regenerate Xcode project twice and run dual builds + macOS smoke test**

Run:
```bash
cd /Users/andy/.gemini/antigravity/scratch/Sintonia && xcodegen generate && xcodegen generate
xcodebuild test -project Sintonia.xcodeproj -scheme SintoniaMac -sdk macosx -destination "platform=macOS" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'
xcodebuild build-for-testing -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'
plutil -lint /Users/andy/.gemini/antigravity/scratch/Sintonia/.build/DerivedData/Build/Products/Debug/Sintonia.app/Contents/Resources/PrivacyInfo.xcprivacy
```
Expected: Both `SintoniaMac` native macOS `xcodebuild test` (`** TEST SUCCEEDED **`) and iOS `Sintonia` (`** TEST BUILD SUCCEEDED **`) pass with `0` warnings; `Sintonia.app/Contents/Resources/PrivacyInfo.xcprivacy: OK`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add project.yml App/iOS/SintoniaIOSApp.swift App/Sources/StudioUI/SintoniaApp.swift App/Mac App/Sources/MacUI App/Tests/MacRuntimeTests App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json Sintonia.xcodeproj
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "chore(project): add SintoniaMac and SintoniaMacTests XcodeGen targets"
```

---

### Task 5: Hybrid Desktop Windows, `MacAppCoordinator`, `MenuBarExtra`, `MacCommands` & Drag-and-Drop

**Files:**
- Modify: `App/Sources/MacUI/MacAppCoordinator.swift`
- Create: `App/Sources/MacUI/MacOutputDeviceMenu.swift`
- Create: `App/Sources/MacUI/MacPlayerWindowView.swift`
- Create: `App/Sources/MacUI/MacLibraryWindowView.swift`
- Create: `App/Sources/MacUI/MacStudioWindowView.swift`
- Create: `App/Sources/MacUI/MacMenuBarView.swift`
- Create: `App/Sources/MacUI/MacCommands.swift`
- Modify: `App/Mac/SintoniaMacApp.swift`

**Interfaces:**
- Consumes: `AudioRuntime`, `StudioUI`, `PresetKit`, `SynthCore`, `SintoniaExport`, `AppKit`, `UniformTypeIdentifiers`
- Produces:
  - `public enum SintoniaWindowID` (`static let player = "player"`, `library = "library"`, `studio = "studio"`)
  - `@MainActor @Observable public final class MacAppCoordinator`:
    - `public enum PlayerModalSheet: String, Identifiable { case export, about }`
    - `public enum PendingStudioConflict: Identifiable` (deferred preset load / new template / imported preset pending Save or Discard)
    - Properties: `engine`, `presetStore`, `presetsRevision`, `activePlayerSheet`, `isShowingFileImporter`, `importAlert`, `importToastPresetName`, `studioHasUnsavedChanges`, `studioSyncToken`, `pendingConflict`
    - Methods: `init(presetStore: PresetStore, engine: AudioEngineController)`, `requestLoadPreset(_ preset: Preset, autoPlay: Bool = false)`, `requestCreateNewPreset()`, `requestOpenImportPanel()`, `requestShowExport()`, `requestShowAbout()`, `registerStudioSaveHandler(_ handler: (() -> Bool)?)`, `handleIncomingURLs(_ urls: [URL])`, `resolveConflictSaveThenProceed()`, `resolveConflictDiscardAndProceed()`, `resolveConflictCancel()`, `shouldHandlePlayPauseSpaceShortcut(isTextInputFocused: Bool?, isFirstResponderTextEditor: Bool) -> Bool`
  - Singleton `Window(id:)` scenes + `MenuBarExtra` (`.window`) + `MacCommands` (`⌘N`, `⌘O`, `⌘E`, `⌘1`, `⌘L`, `⌘2`, `Space`, `⌘←`/`⌘→`, `⌘↑`/`⌘↓`, Output Device submenu, About Sintonia)

- [ ] **Step 1: Implement `MacAppCoordinator.swift` and `MacOutputDeviceMenu.swift`**

- `MacAppCoordinator`:
  - Injectable `init(presetStore:engine:)` with default `Application Support/Sintonia/Presets` + `AudioEngineController(preset: PresetCatalog.builtInPresets[0])`.
  - Guards unsaved Studio edits (`studioHasUnsavedChanges`): if true on `requestLoadPreset`, `requestCreateNewPreset`, or valid `.bwg`/`.sintonia` import from `handleIncomingURLs`, defers loading into `engine` and sets `pendingConflict` (Save calls registered Studio `saveHandler` first; Discard discards edits and loads + increments `studioSyncToken`; Cancel aborts switch).
  - For `handleIncomingURLs(_ urls: [URL])`: validates & saves via `PresetImportCoordinator.importFile(at:into:)` first so corrupted/unsupported files immediately raise `importAlert` without touching `engine.currentPreset` or triggering conflict prompts; for multi-file drops, processes files cleanly, activates the last valid preset, and surfaces any legacy skips or failures in `importAlert` or clean confirmation in `importToastPresetName`.
  - `shouldHandlePlayPauseSpaceShortcut(isTextInputFocused:isFirstResponderTextEditor:)`: returns `false` if `isTextInputFocused == true` OR `isFirstResponderTextEditor == true` (checking `NSApp.keyWindow?.firstResponder is NSTextView` on macOS covers `.searchable` `NSSearchField` as well as SwiftUI `TextField`s).
- `MacOutputDeviceMenu`: compact Liquid Glass `Menu` listing `"System Default"` + `engine.availableOutputDevices` with checkmark, headphone/speaker icons, and active route badge.

- [ ] **Step 2: Build Windows, `MacMenuBarView`, `MacCommands`, and wire `SintoniaMacApp.swift`**

- **`MacPlayerWindowView` (`id: "player"`):**
  - Default `430×700`, min `380×620`, maxWidth `540`.
  - Wraps `PlayerView(engine:coordinator.engine, onOpenLibrary: ..., onOpenStudio: ..., onOpenExport: ..., onOpenAbout: ...) { MacOutputDeviceMenu(engine: coordinator.engine) }`.
  - Attaches `.sheet(item: $coordinator.activePlayerSheet)` (`ExportSheetView` / `AboutSheetView`), `.fileImporter`, `.onDrop(of: [.fileURL], isTargeted: $isDropTargeted)` with Liquid Glass highlight overlay, `.importResultAlert($coordinator.importAlert)`, top toast overlay, and unsaved-Studio conflict `.confirmationDialog`.
- **`MacLibraryWindowView` (`id: "library"`):**
  - Default `780×640`, min `560×460`.
  - Wraps `LibraryView(..., adaptiveDesktopGrid: true, hidesDoneButton: true, loadsDirectlyOnSelect: false, onSelectPreset: { coordinator.requestLoadPreset($0, autoPlay: false) }, onDoubleClickPreset: { coordinator.requestLoadPreset($0, autoPlay: true) }, onCreateNewTemplate: { _ in coordinator.requestCreateNewPreset(); openWindow(id: SintoniaWindowID.studio) })`.
  - Supports `.onDrop(of: [.fileURL], isTargeted: $isDropTargeted)`, `.importResultAlert($coordinator.importAlert)`, and unsaved-Studio conflict dialog.
- **`MacStudioWindowView` (`id: "studio"`):**
  - Default `1160×740`, min `860×600`.
  - Wraps `StudioRackView(engine: coordinator.engine, presetStore: coordinator.presetStore, showsDualPaneWhenWide: true, externalSyncTrigger: coordinator.studioSyncToken, onDirtyStateChanged: { coordinator.studioHasUnsavedChanges = $0 }, onRegisterSaveHandler: { coordinator.registerStudioSaveHandler($0) }, onSavedPreset: { _ in coordinator.presetsRevision += 1 })` + unsaved-Studio conflict dialog.
- **`MacMenuBarView` (`MenuBarExtra` `.window`):**
  - Uses explicit `MenuBarExtra { MacMenuBarView(...) } label: { ... }` displaying `waveform.path.ecg` plus tabular beat Hz (`10.0 Hz`) while `coordinator.engine.isPlaying`.
  - Popover (`310 pt` width): preset title, `BrainwaveBandBadge`, timer, `-30s`/`Play-Pause`/`+30s`, Master slider, quick preset menu, `MacOutputDeviceMenu`, Open Player (`⌘1`) / Library (`⌘L`) / Studio (`⌘2`) calling `NSApp.activate(ignoringOtherApps: true)` + `openWindow(id:)`, and Quit.
- **`MacCommands` & `SintoniaMacApp.swift`:**
  - `Window(Text("Sintonia"), id: "player")` with `.handlesExternalEvents(matching: ["*"])` and `.onOpenURL { coordinator.handleIncomingURLs([$0]) }`.
  - `Window(Text("Library"), id: "library")` and `Window(Text("Studio Rack"), id: "studio")`.
  - Menus: `About Sintonia`, File (`⌘N`, `⌘O`, `⌘E`), Playback (`Space` guarded by `@FocusedValue(\.isTextInputFocused)` & `NSApp.keyWindow?.firstResponder is NSTextView`, `⌘←`/`⌘→` ±30 s, `⌘↑`/`⌘↓` Master ±5%, Output Device submenu), Window (`⌘1`, `⌘L`, `⌘2`).

- [ ] **Step 3: Regenerate project, run macOS tests + iOS build-for-testing**

Run:
```bash
cd /Users/andy/.gemini/antigravity/scratch/Sintonia && xcodegen generate
xcodebuild test -project Sintonia.xcodeproj -scheme SintoniaMac -sdk macosx -destination "platform=macOS" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'
xcodebuild build-for-testing -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'
```
Expected: macOS `** TEST SUCCEEDED **` and iOS `** TEST BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Mac/SintoniaMacApp.swift App/Sources/MacUI App/Sources/StudioUI Sintonia.xcodeproj
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "feat(MacUI): add hybrid desktop windows, MenuBarExtra, Commands, and drag-and-drop"
```

---

### Task 6: Complete EN/RU Localization, Full `SintoniaMacTests` & Final Verification

**Files:**
- Modify: `App/Resources/Localizable.xcstrings`
- Modify: `App/Tests/MacRuntimeTests/MacRuntimeTests.swift`

**Interfaces:**
- Consumes: `@testable import SintoniaMac`, `PresetKit`, `SynthCore`, `SintoniaExport`
- Produces: Complete EN + RU translations for all macOS UI keys and comprehensive native macOS tests covering all 5 Review Focus failure modes.

- [ ] **Step 1: Add all new macOS EN + RU translations to `App/Resources/Localizable.xcstrings`**

Inspect every user-facing string introduced across `App/Mac/`, `App/Sources/MacUI/`, and Tasks 3–5 (`System Default`, `Output Device`, `Save As…`, `Export .sintonia…`, `Delete Point`, `About Sintonia`, `Playback`, `Open Player`, `Open Library`, `Open Studio`, `Drop .bwg or .sintonia preset here`, `Skip Backward 30s`, `Skip Forward 30s`, `Increase Master Volume`, `Decrease Master Volume`, `Import Preset…`, `Export Audio…`, `Studio Rack`, `Quit Sintonia`, `Save before switching presets?`, etc.). Add `"en"` and `"ru"` `"translated"` entries in `App/Resources/Localizable.xcstrings`, preserving all existing translated iOS entries cleanly, and validate JSON structure (`python3 -m json.tool`).

- [ ] **Step 2: Write complete `App/Tests/MacRuntimeTests/MacRuntimeTests.swift` covering all Review Focus cases**

Add tests (using injected `PresetStore` temp directory and isolated `UserDefaults` suite—zero side effects on real user defaults):
1. `reviewFocus1_headphoneDisconnectDuringBinauralAutoPausesAndResetsSelection`:
   - Select `AudioOutputDevice(uid: "airpods", route: .headphones)` with `Deep Focus` (`presetHasActiveBinaural == true`), set active binaural transition removing `"airpods"` and leaving built-in speaker → verifies auto-pause triggers, `showHeadphoneBanner == true`, and `selectedOutputDeviceUID == nil`.
2. `reviewFocus2_unsavedStudioDraftGuardsPresetLoadAndOpenURL`:
   - Instantiate `MacAppCoordinator` with temp `PresetStore`; set `studioHasUnsavedChanges = true`; call `requestLoadPreset(otherPreset)` and `handleIncomingURLs([validBWGURL])` → asserts `engine.currentPreset` stays unchanged, `pendingConflict != nil`, and `resolveConflictDiscardAndProceed()` applies the switch cleanly.
3. `reviewFocus3_spaceShortcutBlockedWhileTextInputFocused`:
   - Asserts `coordinator.shouldHandlePlayPauseSpaceShortcut(isTextInputFocused: true, isFirstResponderTextEditor: false) == false`, `(isTextInputFocused: false, isFirstResponderTextEditor: true) == false`, and `(isTextInputFocused: false, isFirstResponderTextEditor: false) == true`.
4. `reviewFocus4_invalidAndMultiFileDropSurfacesImportAlertWithoutDisruptingPlayback`:
   - Calls `coordinator.handleIncomingURLs([invalidTxtURL, truncatedBWGURL])` → asserts `importAlert != nil`, `engine.currentPreset` untouched, and `presetStore.customPresets()` empty; also imports a legacy `.bwg` with skipped `.wav`/strobe features and verifies `importAlert` shows skipped notices while storing the valid preset.
5. `reviewFocus5_stalePersistedUIDAndZeroAudioDevicesFallBackSafely`:
   - Seeds isolated `UserDefaults` with `"stale-usb-dac-uid"`, creates `MacAudioDeviceManager(..., startHardwareMonitoring: false)`, applies `[]` and `[speakerDevice]` snapshots → verifies zero crashes, `selectedDeviceUID == nil`, and `currentRoute` is `.other` (0 devices) / `.speaker` (speaker only).
6. `macBundleContainsPrivacyManifestE174_1AndRussianTranslations`:
   - Verifies `Sintonia.app/Contents/Resources/PrivacyInfo.xcprivacy` parses cleanly with `E174.1` and `NSPrivacyTracking == false`, and verifies key macOS EN & RU strings exist in `ru.lproj/Localizable.strings` inside the built macOS bundle.

- [ ] **Step 3: Full Dual-Platform Verification (SwiftPM + native `SintoniaMacTests` + iOS `build-for-testing`)**

Run all verification commands cleanly in sandbox:
1. `swift test --disable-sandbox --package-path /Users/andy/.gemini/antigravity/scratch/Sintonia/Packages/SintoniaCore`
   Expected: All suites (`SintoniaExportTests`, `SynthCoreTests`, `PresetKitTests`, `>= 50` tests) pass with `0` failures.
2. `xcodebuild test -project Sintonia.xcodeproj -scheme SintoniaMac -sdk macosx -destination "platform=macOS" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'`
   Expected: `** TEST SUCCEEDED **` with all `SintoniaMacTests` passing live on macOS 27.2 and `0` Swift warnings.
3. `xcodebuild build-for-testing -project Sintonia.xcodeproj -scheme Sintonia -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_USE_INTEGRATED_DRIVER=NO OTHER_SWIFT_FLAGS='-load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libObservationMacros.dylib -load-plugin-library /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib'`
   Expected: `** TEST BUILD SUCCEEDED **` (`0` Swift warnings).
4. Inspect macOS bundle manifests:
   ```bash
   plutil -lint /Users/andy/.gemini/antigravity/scratch/Sintonia/.build/DerivedData/Build/Products/Debug/Sintonia.app/Contents/Resources/PrivacyInfo.xcprivacy
   grep -n "E174.1" /Users/andy/.gemini/antigravity/scratch/Sintonia/.build/DerivedData/Build/Products/Debug/Sintonia.app/Contents/Resources/PrivacyInfo.xcprivacy
   plutil -lint /Users/andy/.gemini/antigravity/scratch/Sintonia/App/Mac/SintoniaMac.entitlements
   ```

- [ ] **Step 4: Commit**

```bash
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia add App/Resources/Localizable.xcstrings App/Tests/MacRuntimeTests/MacRuntimeTests.swift
git -C /Users/andy/.gemini/antigravity/scratch/Sintonia commit -m "test(Mac): add EN/RU macOS localizations and comprehensive SintoniaMacTests"
```
