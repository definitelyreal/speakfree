// ai-suggestion:unverified · 2026-09-24
import CoreAudio
import Foundation

/// Connected headsets as the menu needs them, derived from the device cache only
/// (never a live HAL read, so it is safe on the main thread).
public struct ConnectedHeadset: Equatable, Sendable {
    public let uid: String
    public let name: String
    /// nil when macOS is connected to the headset for audio but not offering its mic.
    public let input: AudioInputDevice?
    public var hasMic: Bool { input != nil }
}

public enum HeadsetInventory {
    /// "XX-XX:input" and "XX-XX:output" are two halves of one headset.
    public static func baseUID(_ uid: String) -> String {
        for suffix in [":input", ":output", "-input", "-output"] where uid.lowercased().hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }

    static func sameHeadset(_ output: AudioOutputDevice, _ input: AudioInputDevice) -> Bool {
        if output.uid == input.uid || baseUID(output.uid) == baseUID(input.uid) { return true }
        // Names match only when neither UID says which half it is; two headsets can share a name.
        let halvesKnown = baseUID(output.uid) != output.uid || baseUID(input.uid) != input.uid
        return !halvesKnown && output.name == input.name
    }

    /// Every Bluetooth headset: each Bluetooth input, then each Bluetooth output with no
    /// matching input (connected, no mic offered).
    public static func headsets(inputs: [AudioInputDevice], bluetoothOutputs: [AudioOutputDevice]) -> [ConnectedHeadset] {
        let mics = inputs.filter { $0.isBluetooth }
        var result = mics.map { ConnectedHeadset(uid: $0.uid, name: $0.name, input: $0) }
        var seen = Set<String>()
        for out in bluetoothOutputs where !mics.contains(where: { sameHeadset(out, $0) }) {
            guard seen.insert(baseUID(out.uid)).inserted else { continue }
            result.append(ConnectedHeadset(uid: out.uid, name: out.name, input: nil))
        }
        return result
    }

    /// Device IDs that belong to the headset whose mic is `input` (its input half and any
    /// matching output half), for checking what plays on it.
    public static func deviceIDs(for input: AudioInputDevice, bluetoothOutputs: [AudioOutputDevice]) -> Set<AudioDeviceID> {
        var ids: Set<AudioDeviceID> = [input.id]
        for out in bluetoothOutputs where sameHeadset(out, input) { ids.insert(out.id) }
        return ids
    }

    public static var cached: [ConnectedHeadset] {
        headsets(inputs: AudioDeviceCatalog.cachedInputDevices, bluetoothOutputs: AudioDeviceCatalog.cachedBluetoothOutputs)
    }
}

/// Reads which apps are using the audio system and on which devices (CoreAudio process
/// objects, macOS 14 and later). Metadata reads only: nothing here opens a microphone
/// or needs a permission. Blocks on coreaudiod, so never call it on the main thread.
public enum HeadsetActivityProbe {
    private static let queue = DispatchQueue(label: "com.speakfree.headsetactivity", qos: .utility)

    /// Classify what is playing on `headset`, off the main thread; `completion` on main.
    public static func playback(on headset: AudioInputDevice, completion: @escaping (HeadsetPlayback) -> Void) {
        let outputs = AudioDeviceCatalog.cachedBluetoothOutputs
        queue.async {
            let ids = HeadsetInventory.deviceIDs(for: headset, bluetoothOutputs: outputs)
            let result = classify(headsetIDs: ids, ownBundleID: Bundle.main.bundleIdentifier)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A failed HAL read is unknown, not an empty/idle audio system. Incomplete evidence
    /// must never automatically acquire Bluetooth input and lower the user's media quality.
    struct Readers {
        var processes: () -> [AudioObjectID]?
        var runningInput: (AudioObjectID) -> Bool?
        var runningOutput: (AudioObjectID) -> Bool?
        var bundleID: (AudioObjectID) -> String?
        var inputDevices: (AudioObjectID) -> [AudioDeviceID]?
        var outputDevices: (AudioObjectID) -> [AudioDeviceID]?

        static var live: Readers {
            Readers(processes: processObjects,
                    runningInput: { uint32($0, kAudioProcessPropertyIsRunningInput).map { $0 != 0 } },
                    runningOutput: { uint32($0, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 } },
                    bundleID: { string($0, kAudioProcessPropertyBundleID) },
                    inputDevices: { devices($0, scope: kAudioObjectPropertyScopeInput) },
                    outputDevices: { devices($0, scope: kAudioObjectPropertyScopeOutput) })
        }
    }

    static func classify(headsetIDs: Set<AudioDeviceID>, ownBundleID: String?,
                         readers: Readers = .live) -> HeadsetPlayback {
        guard let uses = uses(headsetIDs: headsetIDs, readers: readers) else { return .unknown }
        return HeadsetPlaybackClassifier.classify(uses, ownBundleID: ownBundleID)
    }

    static func uses(headsetIDs: Set<AudioDeviceID>, readers: Readers = .live) -> [AudioProcessUse]? {
        guard let processes = readers.processes() else { return nil }
        var result: [AudioProcessUse] = []
        for obj in processes {
            guard let runningIn = readers.runningInput(obj),
                  let runningOut = readers.runningOutput(obj) else { return nil }
            guard runningIn || runningOut else { continue }
            guard let bundle = readers.bundleID(obj), !bundle.isEmpty else { return nil }
            // An inactive direction has no route to inspect; requiring it could turn a
            // fully observed output-only music player into an unnecessary unknown result.
            guard let inDevices = runningIn ? readers.inputDevices(obj) : [],
                  let outDevices = runningOut ? readers.outputDevices(obj) : [] else { return nil }
            result.append(AudioProcessUse(
                bundleID: bundle,
                inputOnHeadset: runningIn && !Set(inDevices).isDisjoint(with: headsetIDs),
                outputOnHeadset: runningOut && !Set(outDevices).isDisjoint(with: headsetIDs),
                inputAnywhere: runningIn))
        }
        return result
    }

    private static func addr(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectList(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID]? {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        guard Int(size) % MemoryLayout<AudioObjectID>.size == 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr,
              Int(size) % MemoryLayout<AudioObjectID>.size == 0,
              Int(size) <= ids.count * MemoryLayout<AudioObjectID>.size else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func processObjects() -> [AudioObjectID]? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return objectList(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyProcessObjectList))
    }

    private static func devices(_ obj: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioDeviceID]? {
        objectList(obj, addr(kAudioProcessPropertyDevices, scope: scope))
    }

    private static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = addr(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = addr(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
