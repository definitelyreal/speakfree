// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import CoreAudio
import Foundation

/// A capture-capable audio device as shown in the menu-bar microphone selector.
public struct AudioInputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool
    public let isBluetooth: Bool
}

/// CoreAudio input-device enumeration for the microphone selector and (future)
/// dual-capture pinning. Read-only; setting the app's capture device happens in
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

    /// Prefer the system default when it is Bluetooth, but do not require Bluetooth
    /// to be the default. Dual capture deliberately leaves the default on the built-in
    /// mic so AirPods remain in stereo playback mode while speakfree is idle.
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

    /// Live HAL read + cache swap. Runs ONLY on refreshQueue.
    private static func refreshCacheNow() {
        let devices = inputDevices()
        let def = defaultInputDevice()
        cacheLock.lock()
        _cachedDevices = devices
        _cachedDefault = def
        cacheLock.unlock()
        DispatchQueue.main.async { onCacheRefreshed?() }
    }

    // MARK: - Live enumeration (background/refresh use only — blocks on coreaudiod)

    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            let transport = transportType(of: id)
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE)
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

    private static func transportType(of id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
