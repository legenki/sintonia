#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Observation
import Synchronization
import SintoniaExport

/// Represents an enumerated macOS CoreAudio output device.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let deviceID: UInt32
    public let uid: String
    public let name: String
    public let route: AudioOutputRoute
    public let isSystemDefault: Bool

    public init(
        deviceID: UInt32 = 0,
        uid: String,
        name: String = "",
        route: AudioOutputRoute,
        isSystemDefault: Bool = false
    ) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
        self.route = route
        self.isSystemDefault = isSystemDefault
    }
}

/// Thread-safe registry retaining exact `AudioObjectPropertyListenerBlock` references for race-free `deinit` cleanup.
private final class CoreAudioListenerRegistry: @unchecked Sendable {
    private struct Entry: @unchecked Sendable {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
    }

    private let systemEntries = Mutex<[Entry]>([])
    private let deviceEntries = Mutex<[Entry]>([])
    private let monitoredBuiltInDeviceIDs = Mutex<Set<AudioDeviceID>>([])

    deinit {
        removeAll()
    }

    func addSystemListener(
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(systemObjectID, &address) else { return }

        let status = AudioObjectAddPropertyListenerBlock(systemObjectID, &address, queue, block)
        guard status == noErr else { return }

        let entry = Entry(objectID: systemObjectID, address: address, queue: queue, block: block)
        systemEntries.withLock { $0.append(entry) }
    }

    func syncBuiltInDeviceListeners(
        deviceIDs: Set<AudioDeviceID>,
        queue: DispatchQueue,
        makeBlock: () -> AudioObjectPropertyListenerBlock
    ) {
        let unchanged = monitoredBuiltInDeviceIDs.withLock { current in
            if current == deviceIDs {
                return true
            }
            current = deviceIDs
            return false
        }
        guard !unchanged else { return }

        let oldEntries = deviceEntries.withLock { entries -> [Entry] in
            let existing = entries
            entries.removeAll()
            return existing
        }
        for entry in oldEntries {
            var addr = entry.address
            _ = AudioObjectRemovePropertyListenerBlock(entry.objectID, &addr, entry.queue, entry.block)
        }

        var newEntries: [Entry] = []
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyDataSource,
            kAudioDevicePropertyJackIsConnected,
        ]
        for deviceID in deviceIDs where deviceID != 0 {
            for selector in selectors {
                guard let scope = Self.resolvePropertyScope(objectID: deviceID, selector: selector) else {
                    continue
                }
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                let block = makeBlock()
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
                if status == noErr {
                    newEntries.append(Entry(objectID: deviceID, address: address, queue: queue, block: block))
                }
            }
        }
        if !newEntries.isEmpty {
            deviceEntries.withLock { $0.append(contentsOf: newEntries) }
        }
    }

    func removeAll() {
        let oldSystem = systemEntries.withLock { entries -> [Entry] in
            let existing = entries
            entries.removeAll()
            return existing
        }
        let oldDevices = deviceEntries.withLock { entries -> [Entry] in
            let existing = entries
            entries.removeAll()
            return existing
        }
        monitoredBuiltInDeviceIDs.withLock { $0.removeAll() }

        for entry in oldSystem + oldDevices {
            var addr = entry.address
            _ = AudioObjectRemovePropertyListenerBlock(entry.objectID, &addr, entry.queue, entry.block)
        }
    }

    private static func resolvePropertyScope(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyScope? {
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(objectID, &outputAddress) {
            return kAudioObjectPropertyScopeOutput
        }
        var globalAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(objectID, &globalAddress) {
            return kAudioObjectPropertyScopeGlobal
        }
        return nil
    }
}

/// Manages CoreAudio HAL output device enumeration, selection persistence, AUHAL binding,
/// and live hardware route monitoring on macOS.
@MainActor
@Observable
public final class MacAudioDeviceManager {
    public static let selectedDeviceUIDDefaultsKey = "sintonia.mac.selectedOutputDeviceUID"
    private static let headphonesDataSource: UInt32 = 0x6864_706E // 'hdpn'
    private static let internalSpeakerDataSource: UInt32 = 0x6973_706B // 'ispk'

    public private(set) var availableDevices: [AudioOutputDevice] = []
    public private(set) var selectedDeviceUID: String?
    public private(set) var currentRoute: AudioOutputRoute = .other

    @ObservationIgnored
    public var onRouteStateChanged: ((_ previousRoute: AudioOutputRoute, _ newRoute: AudioOutputRoute, _ selectedDeviceWasRemoved: Bool) -> Void)?

    @ObservationIgnored
    internal var onHardwareDevicesRefreshed: (() -> Void)?

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let startHardwareMonitoring: Bool
    @ObservationIgnored private let listenerRegistry = CoreAudioListenerRegistry()
    @ObservationIgnored private var systemDefaultUID: String?
    @ObservationIgnored private var systemDefaultDeviceID: AudioDeviceID = 0
    @ObservationIgnored private var builtInDeviceIDs: Set<AudioDeviceID> = []
    @ObservationIgnored internal private(set) var isUsingTestingSnapshot: Bool = false

    public init(userDefaults: UserDefaults = .standard, startHardwareMonitoring: Bool = true) {
        self.userDefaults = userDefaults
        self.startHardwareMonitoring = startHardwareMonitoring

        let persisted = userDefaults.string(forKey: Self.selectedDeviceUIDDefaultsKey)
        if let persisted, !persisted.isEmpty {
            self.selectedDeviceUID = persisted
        } else {
            if persisted != nil {
                userDefaults.removeObject(forKey: Self.selectedDeviceUIDDefaultsKey)
            }
            self.selectedDeviceUID = nil
        }

        refreshDevices()
        if startHardwareMonitoring {
            registerHardwareListeners()
        }
    }

    deinit {
        listenerRegistry.removeAll()
    }

    /// Selects a preferred output device UID (`nil` uses the System Default output device) and binds it to `engine`.
    public func selectDevice(uid: String?, for engine: AVAudioEngine) throws {
        let normalizedUID = (uid?.isEmpty == false) ? uid : nil
        let previousRoute = currentRoute

        let candidates = availableDevices.map { AudioDeviceCandidate(uid: $0.uid, route: $0.route) }
        let result = AudioDeviceSelectionPolicy.resolveSelection(
            selectedUID: normalizedUID,
            availableDevices: candidates,
            systemDefaultUID: systemDefaultUID
        )

        let targetDeviceID = resolveTargetDeviceID(for: result.resolvedUID)
        try bindDeviceID(targetDeviceID, to: engine) {
            self.selectedDeviceUID = result.resolvedUID
            self.persistSelectedUID(result.resolvedUID)
            self.currentRoute = result.activeRoute

            if result.didLoseSelectedDevice {
                self.onRouteStateChanged?(previousRoute, result.activeRoute, true)
            }
        }
    }

    /// Binds the currently resolved CoreAudio output device (`selectedDeviceUID` or System Default) to `engine`.
    public func bindCurrentDevice(to engine: AVAudioEngine) throws {
        try bindDeviceID(resolveTargetDeviceID(for: selectedDeviceUID), to: engine)
    }

    private func bindDeviceID(
        _ targetDeviceID: AudioDeviceID,
        to engine: AVAudioEngine,
        beforeRestart: (() -> Void)? = nil
    ) throws {
        guard targetDeviceID != 0 else {
            beforeRestart?()
            return
        }

        let needsRebind = engine.outputNode.withAudioUnit { audioUnit -> Bool in
            guard let audioUnit else { return false }
            var currentDeviceID: AudioDeviceID = 0
            var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let getStatus = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentDeviceID,
                &propertySize
            )
            return !(getStatus == noErr && currentDeviceID == targetDeviceID)
        }
        guard needsRebind else {
            beforeRestart?()
            return
        }

        let wasRunning = engine.isRunning
        if wasRunning {
            // Stop before rebinding AUHAL so hardware sample-rate or layout changes reinitialize cleanly.
            engine.stop()
        }

        let setStatus = engine.outputNode.withAudioUnit { audioUnit -> OSStatus? in
            guard let audioUnit else { return nil }
            var mutableDeviceID = targetDeviceID
            return AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        guard let setStatus else {
            beforeRestart?()
            if wasRunning {
                engine.prepare()
                try engine.start()
            }
            return
        }

        guard setStatus == noErr else {
            if wasRunning {
                engine.prepare()
                try? engine.start()
            }
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(setStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Failed to bind CoreAudio output device (OSStatus \(setStatus)).")
                ]
            )
        }

        // Commit selection and route state once AUHAL accepts the device, before restarting the engine.
        beforeRestart?()

        if wasRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Applies an explicit device snapshot in unit tests, resolving selection and firing `onRouteStateChanged`.
    public func applySnapshotForTesting(devices: [AudioOutputDevice], defaultUID: String?) {
        isUsingTestingSnapshot = true
        let filteredDevices = devices.filter { !$0.uid.isEmpty }
        let normalizedDefaultUID = (defaultUID?.isEmpty == false) ? defaultUID : nil
        let defaultDeviceID = normalizedDefaultUID
            .flatMap { uid in filteredDevices.first(where: { $0.uid == uid })?.deviceID }
            ?? filteredDevices.first(where: \.isSystemDefault)?.deviceID
            ?? 0

        applyEnumeratedSnapshot(
            devices: filteredDevices,
            defaultUID: normalizedDefaultUID,
            defaultDeviceID: defaultDeviceID,
            builtInIDs: []
        )
    }

    /// Re-enumerates live CoreAudio HAL output devices and updates selection/route state.
    internal func refreshDevices() {
        isUsingTestingSnapshot = false
        let enumeration = Self.enumerateCoreAudioDevices()
        applyEnumeratedSnapshot(
            devices: enumeration.devices,
            defaultUID: enumeration.defaultUID,
            defaultDeviceID: enumeration.defaultDeviceID,
            builtInIDs: enumeration.builtInDeviceIDs
        )
        if startHardwareMonitoring {
            syncBuiltInDeviceListeners()
        }
    }

    // MARK: - Selection & Snapshot Application

    private func applyEnumeratedSnapshot(
        devices: [AudioOutputDevice],
        defaultUID: String?,
        defaultDeviceID: AudioDeviceID,
        builtInIDs: Set<AudioDeviceID>
    ) {
        let previousRoute = currentRoute
        availableDevices = devices
        systemDefaultUID = defaultUID
        systemDefaultDeviceID = defaultDeviceID
        builtInDeviceIDs = builtInIDs

        let candidates = devices.map { AudioDeviceCandidate(uid: $0.uid, route: $0.route) }
        let result = AudioDeviceSelectionPolicy.resolveSelection(
            selectedUID: selectedDeviceUID,
            availableDevices: candidates,
            systemDefaultUID: defaultUID
        )

        if result.didLoseSelectedDevice {
            selectedDeviceUID = nil
            persistSelectedUID(nil)
        } else {
            selectedDeviceUID = result.resolvedUID
        }

        currentRoute = result.activeRoute

        if result.activeRoute != previousRoute || result.didLoseSelectedDevice {
            onRouteStateChanged?(previousRoute, result.activeRoute, result.didLoseSelectedDevice)
        }
    }

    private func persistSelectedUID(_ uid: String?) {
        if let uid, !uid.isEmpty {
            userDefaults.set(uid, forKey: Self.selectedDeviceUIDDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.selectedDeviceUIDDefaultsKey)
        }
    }

    private func resolveTargetDeviceID(for resolvedUID: String?) -> AudioDeviceID {
        if let resolvedUID,
           let selected = availableDevices.first(where: { $0.uid == resolvedUID }) {
            return selected.deviceID
        }
        if systemDefaultDeviceID != 0 {
            return systemDefaultDeviceID
        }
        if let defaultDevice = availableDevices.first(where: \.isSystemDefault) {
            return defaultDevice.deviceID
        }
        return isUsingTestingSnapshot ? 0 : Self.readDefaultOutputDeviceID()
    }

    // MARK: - CoreAudio HAL Listeners

    private func registerHardwareListeners() {
        let queue = DispatchQueue.main
        listenerRegistry.addSystemListener(
            selector: kAudioHardwarePropertyDevices,
            queue: queue,
            block: makeHardwareListenerBlock()
        )
        listenerRegistry.addSystemListener(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            queue: queue,
            block: makeHardwareListenerBlock()
        )
        syncBuiltInDeviceListeners()
    }

    private func syncBuiltInDeviceListeners() {
        listenerRegistry.syncBuiltInDeviceListeners(
            deviceIDs: builtInDeviceIDs,
            queue: DispatchQueue.main,
            makeBlock: { [weak self] in
                Self.makeHardwareListenerBlock(for: self)
            }
        )
    }

    private func makeHardwareListenerBlock() -> AudioObjectPropertyListenerBlock {
        Self.makeHardwareListenerBlock(for: self)
    }

    nonisolated private static func makeHardwareListenerBlock(
        for manager: MacAudioDeviceManager?
    ) -> AudioObjectPropertyListenerBlock {
        { [weak manager] _, _ in
            Task { @MainActor [weak manager] in
                manager?.handleHardwareChangeNotification()
            }
        }
    }

    private func handleHardwareChangeNotification() {
        guard !isUsingTestingSnapshot else { return }
        refreshDevices()
        onHardwareDevicesRefreshed?()
    }

    // MARK: - CoreAudio HAL Enumeration

    private struct CoreAudioEnumeration {
        let devices: [AudioOutputDevice]
        let defaultUID: String?
        let defaultDeviceID: AudioDeviceID
        let builtInDeviceIDs: Set<AudioDeviceID>
    }

    private static func enumerateCoreAudioDevices() -> CoreAudioEnumeration {
        let deviceIDs = readDeviceIDs()
        let defaultDeviceID = readDefaultOutputDeviceID()

        var devices: [AudioOutputDevice] = []
        var seenUIDs: Set<String> = []
        var builtInIDs: Set<AudioDeviceID> = []
        var defaultUID: String?

        for deviceID in deviceIDs where deviceID != 0 {
            guard hasOutputStreams(deviceID: deviceID) else { continue }
            guard let uid = copyStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty,
                  seenUIDs.insert(uid).inserted else {
                continue
            }

            let rawName = copyStringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
            let name = (rawName?.isEmpty == false) ? rawName! : uid

            let transportRaw = readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyTransportType
            ) ?? kAudioDeviceTransportTypeUnknown
            let transport = mapTransportType(transportRaw)
            if transport == .builtIn {
                builtInIDs.insert(deviceID)
            }

            let wiredHeadphones = (transport == .builtIn)
                ? hasWiredHeadphonesConnected(deviceID: deviceID)
                : false
            let route = AudioRoutePolicy.classifyCoreAudioRoute(
                transport: transport,
                hasWiredHeadphonesConnected: wiredHeadphones
            )
            let isDefault = (defaultDeviceID != 0 && deviceID == defaultDeviceID)
            if isDefault {
                defaultUID = uid
            }

            devices.append(
                AudioOutputDevice(
                    deviceID: deviceID,
                    uid: uid,
                    name: name,
                    route: route,
                    isSystemDefault: isDefault
                )
            )
        }

        return CoreAudioEnumeration(
            devices: devices,
            defaultUID: defaultUID,
            defaultDeviceID: defaultDeviceID,
            builtInDeviceIDs: builtInIDs
        )
    }

    private static func readDeviceIDs() -> [AudioDeviceID] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(systemObjectID, &address) else { return [] }

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let dataStatus = deviceIDs.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, baseAddress)
        }
        guard dataStatus == noErr else { return [] }

        let actualCount = min(count, Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        return Array(deviceIDs.prefix(actualCount))
    }

    private static func readDefaultOutputDeviceID() -> AudioDeviceID {
        readUInt32Property(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) ?? 0
    }

    private static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= UInt32(MemoryLayout<UInt32>.size) else { return false }

        let byteCount = max(Int(dataSize), MemoryLayout<AudioBufferList>.size)
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        memset(rawPointer, 0, byteCount)

        var bufferSize = UInt32(byteCount)
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &bufferSize, rawPointer)
        guard dataStatus == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        )
        return bufferList.reduce(UInt32(0)) { $0 &+ $1.mNumberChannels } > 0
    }

    private static func hasWiredHeadphonesConnected(deviceID: AudioDeviceID) -> Bool {
        let dataSource = readDeviceOutputOrGlobalUInt32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDataSource
        )
        let jackConnected = readDeviceOutputOrGlobalUInt32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyJackIsConnected
        ).map { $0 != 0 }

        if let dataSource {
            if dataSource == headphonesDataSource {
                return jackConnected ?? true
            }
            if dataSource == internalSpeakerDataSource {
                return false
            }
        }
        return jackConnected ?? false
    }

    private static func readDeviceOutputOrGlobalUInt32(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        if let outputValue = readUInt32Property(
            objectID: deviceID,
            selector: selector,
            scope: kAudioObjectPropertyScopeOutput
        ) {
            return outputValue
        }
        return readUInt32Property(
            objectID: deviceID,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, dataSize == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value
    }

    private static func copyStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }

        var unmanagedString: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedString) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cfString = unmanagedString?.takeRetainedValue() else {
            return nil
        }
        return cfString as String
    }

    private static func mapTransportType(_ transportType: UInt32) -> CoreAudioTransportKind {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            .usb
        case kAudioDeviceTransportTypeAirPlay:
            .airPlay
        case kAudioDeviceTransportTypeDisplayPort:
            .displayPort
        case kAudioDeviceTransportTypeHDMI:
            .hdmi
        case kAudioDeviceTransportTypeVirtual:
            .virtual
        case kAudioDeviceTransportTypeAggregate:
            .aggregate
        default:
            .other
        }
    }
}
#endif
