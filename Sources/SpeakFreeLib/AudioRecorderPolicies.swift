// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-processed:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
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

    /// Recovery artifacts share the recording stem, leases, deletion and retention policy.
    static func recoveryArtifactURLs(for url: URL) -> [URL] {
        ["archive-damaged", "archive-repair", "archive-invalid"].map { url.deletingPathExtension().appendingPathExtension($0) }
    }

    static func discardRecoveryArtifacts(for url: URL) {
        defer { RecordingStore.invalidateCachedCount() }
        for artifact in recoveryArtifactURLs(for: url) {
            do {
                if artifact.pathExtension == "archive-invalid", FileManager.default.fileExists(atPath: url.path) {
                    continue // a failed audio deletion must never make the damaged WAV eligible again
                }
                if FileManager.default.fileExists(atPath: artifact.path) {
                    try FileManager.default.removeItem(at: artifact)
                }
            } catch {
                DiagnosticLogger.shared.log("AudioRecorder: recovery artifact cleanup failed: \(error.localizedDescription)")
            }
        }
        if !FileManager.default.fileExists(atPath: url.path),
           recoveryArtifactURLs(for: url).allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
            AudioArchiveIntegrity.forget(url)
        }
    }

    enum ArchiveIOOperation { case markInvalid, preserve, withdraw }

    /// Full archive transaction. The old bytes stay preserved, and only a completely
    /// finalized, byte-checked WAV can replace the original. Failed candidates are kept
    /// for the normal recording retention policy, never handed to a recognizer.
    static func finalizeArchive(
        url: URL, samples: [Float], writeFailed: Bool,
        writerFactory: (URL) throws -> WavWriter = { try WavWriter(url: $0) },
        install: (URL, URL) throws -> Void = { try WavWriter.installReplacement($0, at: $1) },
        beforeIO: (ArchiveIOOperation) throws -> Void = { _ in }
    ) throws {
        if !writeFailed, !AudioArchiveIntegrity.isInvalid(url),
           (try? WavWriter.matchesHeader(url, sampleCount: samples.count)) == true { return }
        defer { RecordingStore.invalidateCachedCount() }
        do { try AudioArchiveIntegrity.markInvalid(url, beforeWrite: { try beforeIO(.markInvalid) }) }
        catch {
            // No persistence is possible if all filesystem writes fail. The process-local
            // block still prevents file recognition until this process exits.
            DiagnosticLogger.shared.log("AudioRecorder: invalid-archive marker could not be saved; recognition blocked for this process: \(error.localizedDescription)")
        }
        let artifacts = recoveryArtifactURLs(for: url)
        let damaged = artifacts[0], replacement = artifacts[1]
        let fm = FileManager.default
        let sourceExists = fm.fileExists(atPath: url.path)
        DiagnosticLogger.shared.log("AudioRecorder: \(sourceExists ? "inconsistent" : "missing") archive; repairing from memory")
        var published = false
        do {
            // Never overwrite recovery evidence from an earlier attempt at the same path.
            guard !fm.fileExists(atPath: damaged.path), !fm.fileExists(atPath: replacement.path) else {
                throw NSError(domain: "AudioRecorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Archive recovery evidence already exists"])
            }
            if sourceExists {
                try beforeIO(.preserve)
                try fm.linkItem(at: url, to: damaged)
            }
            let writer = try writerFactory(replacement)
            do { try writer.append(samples); try writer.finish(synchronize: true) }
            catch { writer.close(); throw error }
            guard try WavWriter.matches(replacement, samples: samples) else {
                throw NSError(domain: "AudioRecorder", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Recovered WAV did not match captured audio"])
            }
            try install(replacement, url)
            published = true
            try AudioArchiveIntegrity.clear(url)
            DiagnosticLogger.shared.log("AudioRecorder: archive rewritten from memory (\(samples.count) samples); prior file \(sourceExists ? "preserved" : "absent")")
        } catch {
            // Once a duplicate of the damaged bytes exists, withdraw the stale WAV
            // from future orphan/file recognition as well as the current take.
            if !published, fm.fileExists(atPath: url.path) {
                do {
                    try beforeIO(.withdraw)
                    if fm.fileExists(atPath: damaged.path) {
                        // An occupied evidence name may contain different bytes. Only
                        // unlink the canonical entry when both names identify the same file.
                        guard try sameArchiveFile(url, damaged) else {
                            throw NSError(domain: "AudioRecorder", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Distinct archive evidence occupies recovery path"])
                        }
                        try fm.removeItem(at: url)
                    } else {
                        try RecordingRemoval.moveWithoutReplacing(url, damaged)
                    }
                } catch {
                    DiagnosticLogger.shared.log("AudioRecorder: could not withdraw damaged WAV; invalid marker remains: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    private static func sameArchiveFile(_ first: URL, _ second: URL) throws -> Bool {
        let left = try FileManager.default.attributesOfItem(atPath: first.path)
        let right = try FileManager.default.attributesOfItem(atPath: second.path)
        guard let device = left[.systemNumber] as? NSNumber,
              let inode = left[.systemFileNumber] as? NSNumber else { return false }
        return device == right[.systemNumber] as? NSNumber && inode == right[.systemFileNumber] as? NSNumber
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

/// Known-invalid archives are blocked across current-process callers and, when the disk
/// accepts the marker, across launches. Contains paths only; no samples or transcript text.
enum AudioArchiveIntegrity {
    private static let lock = NSLock()
    private static var invalidPaths: Set<String> = []
    static func marker(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("archive-invalid") }
    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    static func isInvalid(_ url: URL) -> Bool {
        let path = key(url)
        lock.lock(); let invalid = invalidPaths.contains(path); lock.unlock()
        // Read the target's durable marker through file aliases as well as directory
        // aliases. Keep the input-path check for markers written beside older aliases;
        // marker writes and cleanup still belong to the original recording path.
        return invalid || FileManager.default.fileExists(atPath: marker(for: URL(fileURLWithPath: path)).path)
            || FileManager.default.fileExists(atPath: marker(for: url).path)
    }
    static func markInvalid(_ url: URL, beforeWrite: () throws -> Void = {}) throws {
        let path = key(url)
        lock.lock(); invalidPaths.insert(path); lock.unlock()
        try beforeWrite()
        let marker = marker(for: url)
        if FileManager.default.fileExists(atPath: marker.path) { return }
        guard FileManager.default.createFile(atPath: marker.path,
            contents: Data("ai-processed:unverified\nAudio archive unavailable; requires repair before file recognition.\n".utf8),
            attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "AudioRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot persist invalid audio archive marker"])
        }
    }
    static func clear(_ url: URL) throws {
        let marker = marker(for: url)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        forget(url)
    }
    /// Called while a removal still owns its groups, after moving/deleting their files.
    static func forgetMissingArchives(in directory: URL) {
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock(); let paths = invalidPaths; lock.unlock()
        for path in paths where URL(fileURLWithPath: path).deletingLastPathComponent().path == parent {
            if !FileManager.default.fileExists(atPath: path) { forget(URL(fileURLWithPath: path)) }
        }
    }
    /// Explicit deletion/retention may forget an unavailable recording; never makes a file valid.
    static func forget(_ url: URL) {
        let path = key(url)
        lock.lock(); invalidPaths.remove(path); lock.unlock()
    }
}
