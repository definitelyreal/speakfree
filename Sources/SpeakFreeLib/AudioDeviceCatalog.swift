// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import CoreAudio
import Foundation

/// A capture-capable audio device as shown in the menu-bar microphone selector.
public struct AudioInputDevice: Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool
}

/// CoreAudio input-device enumeration for the microphone selector and (future)
/// dual-capture pinning. Read-only; setting the app's capture device happens in
/// AudioRecorder via the input unit's current-device property.
public enum AudioDeviceCatalog {

    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name,
                                    isBuiltIn: transportType(of: id) == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    public static func device(withUID uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    /// The first built-in input device (the MacBook mic), if this Mac has one.
    public static func builtInInputDevice() -> AudioInputDevice? {
        inputDevices().first { $0.isBuiltIn }
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

    /// True when the system default INPUT is a Bluetooth device (the contention-prone
    /// case — built-in and wired mics don't fight across devices).
    public static func defaultInputIsBluetooth() -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
            id != 0 else { return false }
        let transport = transportType(of: id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
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
