// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import CoreAudio
import Foundation

/// A capture-capable audio device as shown in the menu-bar microphone selector.
///
/// `nominalSampleRate` / `inputChannels` are snapshotted during the same background
/// refresh that reads the name and UID, so the stale-format guard in AudioRecorder can
/// sanity-check the engine's reported input format against the hardware WITHOUT a live
/// HAL read on the main thread (the 2026-07-15 wedge).
public struct AudioInputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool
    public let isBluetooth: Bool
    public let nominalSampleRate: Double
    public let inputChannels: Int
}

/// CoreAudio input-device enumeration for the microphone selector and the
/// default-pin rule. Read-only; setting the app's capture device happens in
/// AudioRecorder via the input unit's current-device property.
public enum AudioDeviceCatalog {

    // MARK: - Cached snapshot (the ONLY surface main-thread code may touch)
    //
    // 2026-07-15 hang postmortem: the menu-bar selector enumerated devices LIVE on the
    // main thread on every menu build, and CoreAudio HAL property reads block on
    // coreaudiod — when the daemon wedged (virtual Splashtop/Zoom devices in the mix),
    // the main thread hung inside a status-bar click, and because speakfree holds an
    // active keyboard event tap, typing died system-wide. Live HAL access is therefore
    // confined to the background refresh below; everything else reads the cache.

    private static let refreshQueue = DispatchQueue(label: "com.speakfree.devicecatalog", qos: .utility)
    private static let cacheLock = NSLock()
    private static var _cachedDevices: [AudioInputDevice] = []
    private static var _cachedDefault: AudioInputDevice?
    /// Called on main after every cache refresh (AppDelegate rebuilds the menu).
    public static var onCacheRefreshed: (() -> Void)?

    /// Called on main ONLY when the set of input-device UIDs actually changed, or when a
    /// retained device's AudioDeviceID was renumbered. AudioRecorder subscribes so its
    /// engine can re-resolve its pinned UID; piggybacking on the catalog's single HAL
    /// listener keeps device-list truth in one place (a second `kAudioHardwarePropertyDevices`
    /// listener in the recorder would race this one over which sees the fresher list).
    /// Both snapshots are passed so the decision stays a pure function.
    public static var onDeviceListChanged: (([AudioInputDevice], [AudioInputDevice]) -> Void)?

    public static var cachedInputDevices: [AudioInputDevice] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return _cachedDevices
    }

    public static var cachedDefaultInput: AudioInputDevice? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return _cachedDefault
    }

    public static func cachedDevice(withUID uid: String) -> AudioInputDevice? {
        cachedInputDevices.first { $0.uid == uid }
    }

    public static var cachedBuiltInInput: AudioInputDevice? {
        cachedInputDevices.first { $0.isBuiltIn }
    }

    /// Any Bluetooth input, preferring the system default when it is one. Used only
    /// to decide whether route churn counts as multi-device contention — speakfree
    /// itself captures the built-in mic unless the user pinned something else.
    public static var cachedBluetoothInput: AudioInputDevice? {
        if let device = cachedDefaultInput, device.isBluetooth { return device }
        return cachedInputDevices.first { $0.isBluetooth }
    }

    public static func cachedDefaultIsBluetooth() -> Bool {
        cachedDefaultInput?.isBluetooth ?? false
    }

    /// Start the background cache: initial refresh plus listeners for device-list and
    /// default-input changes. Call once, from any thread; never blocks the caller.
    public static func startCache() {
        refreshQueue.async { refreshCacheNow() }
        var devicesAddr = address(kAudioHardwarePropertyDevices)
        var defaultAddr = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddr, refreshQueue) { _, _ in
            refreshCacheNow()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, refreshQueue) { _, _ in
            refreshCacheNow()
        }
    }

    /// Force a refresh now and run `completion` on main once the cache holds the new
    /// truth. The wake path uses this: after sleep, device IDs can be renumbered, so
    /// rebuilding the capture engine against the PRE-sleep cache would bind a dead
    /// AudioDeviceID. Chaining the rebuild behind the refresh removes that race.
    public static func refreshNow(completion: (() -> Void)? = nil) {
        refreshQueue.async {
            refreshCacheNow()
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Live HAL read + cache swap. Runs ONLY on refreshQueue.
    private static func refreshCacheNow() {
        let devices = inputDevices()
        let def = defaultInputDevice()
        cacheLock.lock()
        let previous = _cachedDevices
        _cachedDevices = devices
        _cachedDefault = def
        cacheLock.unlock()
        logDeviceListChanges(from: previous, to: devices)
        let listChanged = deviceListChanged(from: previous, to: devices)
        DispatchQueue.main.async {
            onCacheRefreshed?()
            if listChanged { onDeviceListChanged?(previous, devices) }
        }
    }

    /// True when the input-device set changed in a way a bound capture engine must react
    /// to: a UID joined, a UID left, OR a surviving UID was renumbered onto a new
    /// `AudioDeviceID`. That last case is the one a UID-keyed pin still gets wrong — the
    /// pin resolves fine while the ENGINE stays bound to the old, now-dead numeric ID
    /// (the ghost-pepper class: a long-lived engine broken after sleep/wake or a USB
    /// re-enumeration). Pure so the rule is testable without hardware.
    static func deviceListChanged(
        from previous: [AudioInputDevice], to current: [AudioInputDevice]
    ) -> Bool {
        let before = Dictionary(previous.map { ($0.uid, $0.id) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.map { ($0.uid, $0.id) }, uniquingKeysWith: { first, _ in first })
        return before != after
    }

    /// Bluetooth/device event log (2026-07-22, multi-Mac AirPods experiment): every
    /// input device joining or leaving THIS Mac is logged with a transport tag, so
    /// per-machine logs can be correlated to see which computer held the AirPods
    /// when. Piggybacks on the existing catalog refresh — no IOBluetooth, no new
    /// TCC permission. Names only, never audio content.
    private static func logDeviceListChanges(
        from previous: [AudioInputDevice], to current: [AudioInputDevice]
    ) {
        let oldUIDs = Set(previous.map(\.uid))
        let newUIDs = Set(current.map(\.uid))
        for dev in current where !oldUIDs.contains(dev.uid) {
            DiagnosticLogger.shared.log(
                "AudioDeviceCatalog: +\(dev.name) [\(transportLabel(dev))] joined")
        }
        for dev in previous where !newUIDs.contains(dev.uid) {
            DiagnosticLogger.shared.log(
                "AudioDeviceCatalog: -\(dev.name) [\(transportLabel(dev))] left")
        }
    }

    private static func transportLabel(_ dev: AudioInputDevice) -> String {
        if dev.isBluetooth { return "bluetooth" }
        if dev.isBuiltIn { return "built-in" }
        return "other"
    }

    // MARK: - Live enumeration (background/refresh use only — blocks on coreaudiod)

    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            let channels = inputChannelCount(of: id)
            guard channels > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            let transport = transportType(of: id)
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE,
                nominalSampleRate: nominalSampleRate(of: id),
                inputChannels: channels)
        }
    }

    public static func device(withUID uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    /// The system default input as a catalog entry (nil when there is no input device).
    public static func defaultInputDevice() -> AudioInputDevice? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
            id != 0 else { return nil }
        return inputDevices().first { $0.id == id }
    }

    // MARK: - Per-device watch on the ACTIVE capture device (2026-08-12)

    /// A registered per-device property listener. Held by AudioRecorder so the listeners
    /// can be torn down when the engine rebinds — `AudioObjectRemovePropertyListenerBlock`
    /// matches on the block identity, so the block must survive as long as the listener.
    public struct DeviceListenerToken {
        let deviceID: AudioDeviceID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
    }

    /// What to watch on the device we are actually capturing from. `DeviceHasChanged` is
    /// the documented catch-all ("configuration changed in ways that cannot otherwise be
    /// conveyed"); `IsAlive` catches a device about to vanish; `StreamConfiguration` and
    /// `NominalSampleRate` catch the format moving under an installed tap.
    static let captureDeviceWatchProperties:
        [(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceHasChanged, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        ]

    /// Watch the capture device itself. `handler` runs on `queue` (never main, never the
    /// HAL's own thread doing anything blocking) and is told which selector fired.
    public static func addCaptureDeviceListeners(
        deviceID: AudioDeviceID, queue: DispatchQueue,
        handler: @escaping (AudioObjectPropertySelector) -> Void
    ) -> [DeviceListenerToken] {
        captureDeviceWatchProperties.compactMap { property in
            var addr = address(property.selector, scope: property.scope)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler(property.selector) }
            guard AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block) == noErr else {
                return nil
            }
            return DeviceListenerToken(
                deviceID: deviceID, address: addr, queue: queue, block: block)
        }
    }

    /// Removal matches on the block, so the token carries the exact block AND the queue it
    /// was registered with — reconstructing either would silently leave the listener live,
    /// and a listener outliving its engine is how a retired binding gets rebuilt.
    public static func removeCaptureDeviceListeners(_ tokens: [DeviceListenerToken]) {
        for token in tokens {
            var addr = token.address
            AudioObjectRemovePropertyListenerBlock(
                token.deviceID, &addr, token.queue, token.block)
        }
    }

    /// Live `kAudioDevicePropertyDeviceIsAlive`; nil when unreadable (which is itself a
    /// signal the device is going away). Never call from main — it blocks on coreaudiod.
    public static func deviceIsAlive(_ id: AudioDeviceID) -> Bool? {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    // MARK: - CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// `kAudioDevicePropertyNominalSampleRate` — the hardware's own idea of its rate,
    /// used only to sanity-check the engine's reported input format. 0 when unreadable.
    /// (A nominal rate is a LABEL, not proof of capture quality — see LESSONS 2026-08-12.)
    private static func nominalSampleRate(of id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        var value: Float64 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return Double(value)
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
