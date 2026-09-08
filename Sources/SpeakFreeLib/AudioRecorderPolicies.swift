// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import AppKit
import AVFoundation
import CoreAudio

// Routing/format policy seams and archive recovery shared with regression tests.
extension AudioRecorder {
    static func effectivePin(explicitPin: String?, builtInUID: String?) -> String? {
        explicitPin ?? builtInUID
    }

    static func deviceListRebuildReason(
        boundUID: String?, boundID: AudioDeviceID?,
        effectivePinTarget: String? = nil, engineExists: Bool = false,
        bindRetryExhausted: Bool = false,
        devices: [AudioInputDevice]
    ) -> String? {
        guard let uid = boundUID else {
            // Cold-start heal (adversarial VERIFY 2026-08-12, blocker 2): the first engine
            // build can beat the catalog's async first scan, in which case an unpinned
            // user's engine binds NOTHING and follows the system default (AirPods!) while
            // `currentCaptureDeviceName` reports the built-in mic into every sidecar. The
            // default-input listener won't repair it (its guard asks what SHOULD happen,
            // not what did), so this branch closes the disagreement: a live engine with no
            // binding, when the pin target is now enumerable, is an orphan — rebuild it.
            if engineExists, let target = effectivePinTarget,
               devices.contains(where: { $0.uid == target }) {
                return "engine is unbound but pin target \(target) is now present (cold-start heal)"
            }
            return nil
        }
        let match = devices.first { $0.uid == uid }
        switch (boundID, match) {
        case (nil, nil):
            return nil
        case (nil, .some(let device)):
            // Retry budget (finding 2): this state is EITHER a device that was absent and
            // returned (retry immediately, always) OR a bind that keeps failing while the
            // device sits present (retry only until the cap, or every device event storms
            // a rebuild that fails the same way).
            guard !bindRetryExhausted else { return nil }
            return "pinned device \(device.name) is present again"
        case (.some, nil):
            return "bound capture device \(uid) departed"
        case (.some(let old), .some(let device)):
            guard old != device.id else { return nil }
            return "bound capture device \(device.name) was renumbered (\(old) → \(device.id))"
        }
    }

    static func shouldRebuildForDeviceAlert(
        selector: AudioObjectPropertySelector,
        isAlive: Bool?,
        presentInDeviceList: Bool,
        secondsSinceEngineBuilt: TimeInterval
    ) -> Bool {
        if !presentInDeviceList { return true }
        if secondsSinceEngineBuilt < selfInducedConfigWindowSeconds { return false }
        if selector == kAudioDevicePropertyDeviceIsAlive { return isAlive == false }
        // HasChanged / StreamConfiguration / NominalSampleRate: the format under the
        // installed tap may have moved, and a tap on a stale format receives nothing.
        return true
    }

    static func resumeAction(preBufferEnabled: Bool, engineExists: Bool) -> ResumeAction {
        if engineExists { return .rebuild }
        return preBufferEnabled ? .startEngine : .none
    }

    static func isCaptureFormatUsable(
        engineRate: Double, engineChannels: UInt32, deviceRate: Double?, deviceChannels: Int?,
        deviceIsBluetooth: Bool = false
    ) -> Bool {
        guard engineRate > 0, engineChannels > 0 else { return false }
        if let deviceRate = deviceRate, deviceRate > 0 {
            if deviceIsBluetooth {
                if engineRate > deviceRate + 1.0 { return false }
            } else if abs(engineRate - deviceRate) > 1.0 {
                return false
            }
        }
        if let deviceChannels = deviceChannels, deviceChannels > 0,
           Int(engineChannels) > deviceChannels {
            return false
        }
        return true
    }

    static func shouldSkipUnusableFormat(retriesSoFar: Int, maxRetries: Int = 3) -> Bool {
        retriesSoFar < maxRetries
    }

    static func observeEngineConfigurationChanges(
        center: NotificationCenter = .default,
        onChange: @escaping (ObjectIdentifier) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let engine = notification.object as? AVAudioEngine else { return }
            let identity = ObjectIdentifier(engine)
            // NotificationCenter's queue:.main delivery is synchronous: the audio engine
            // can hold its internal lock while waiting for main, which in turn waits for
            // that lock during start/dealloc. Never make its notification wait for UI work.
            DispatchQueue.main.async {
                onChange(identity)
            }
        }
    }

    static func selectorLabel(_ selector: AudioObjectPropertySelector) -> String {
        switch selector {
        case kAudioDevicePropertyDeviceHasChanged: return "DeviceHasChanged"
        case kAudioDevicePropertyDeviceIsAlive: return "DeviceIsAlive"
        case kAudioDevicePropertyStreamConfiguration: return "StreamConfiguration"
        case kAudioDevicePropertyNominalSampleRate: return "NominalSampleRate"
        default: return "selector \(selector)"
        }
    }

    static func trailingSlice(_ samples: [Float], after index: Int) -> [Float] {
        return samples.count > index ? Array(samples[index...]) : []
    }

    static func shouldRecoverMissingFirstBuffer(
        isRecording: Bool,
        scheduledGeneration: Int,
        currentGeneration: Int,
        firstBufferArrived: Bool
    ) -> Bool {
        isRecording && scheduledGeneration == currentGeneration && !firstBufferArrived
    }

    static func recoverArchiveIfHeaderOnly(url: URL, samples: [Float]) {
        guard samples.count >= archiveRecoveryMinSamples else { return }
        let byteSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteSize <= archiveHeaderOnlyMaxBytes else { return }
        DiagnosticLogger.shared.log(
            "AudioRecorder: archive wav is header-only (\(byteSize)B) for \(samples.count) samples "
            + "— rewriting from memory")
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).recover-\(UUID().uuidString).tmp")
        do {
            let writer = try WavWriter(url: tmp)
            try writer.append(samples)
            writer.close()
            // Atomic replace: the original is only removed once the temp is fully written.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            DiagnosticLogger.shared.log("AudioRecorder: archive rewrite OK (\(samples.count) samples)")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            DiagnosticLogger.shared.log(
                "AudioRecorder: archive rewrite FAILED — \(error.localizedDescription)")
        }
    }

    static let firstBufferGuardSeconds: TimeInterval = 1.0

    static let bindRetryCap = 3

    static let bindRetryDelaySeconds: TimeInterval = 2.0

    enum ResumeAction: Equatable { case none, startEngine, rebuild }

    static let selfInducedConfigWindowSeconds: TimeInterval = 2.0

    static let reinstallDebounceSeconds: TimeInterval = 0.7

    static let archiveRecoveryMinSamples = 16_000            // 1.0s

    static let archiveHeaderOnlyMaxBytes = 64               // a real wav has ≥1 buffer of PCM
}
