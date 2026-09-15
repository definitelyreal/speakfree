// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import Foundation
import Darwin
import CryptoKit

enum RecordingRemoval {
    private static let folderPrefix = "SpeakFree Recordings "
    private static let markerName = ".speakfree-recording-removal.json"
    private static let restoreLock = NSRecursiveLock()

    private enum Failure: Error { case sourceChanged, trashDidNotMove }

    /// Read-only startup/UI affordance. Only our marked, non-symlink folders for
    /// this exact recordings directory qualify; never restore or delete on lookup.
    static func pendingRecoveryDirectory(in directory: URL) -> URL? {
        try? recoveryDirectories(in: directory).first
    }

    private static func recoveryDirectories(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else { return [] }
        return try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).filter { folder in
            guard folder.lastPathComponent.hasPrefix(folderPrefix),
                  let type = try? fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType,
                  type == .typeDirectory else { return false }
            return recoveryMarker(in: folder, sourceDirectory: directory) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func recoveryMarker(in folder: URL, sourceDirectory: URL) -> [String: Any]? {
        let fm = FileManager.default
        guard let folderType = try? fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType,
              folderType == .typeDirectory else { return nil }
        let marker = folder.appendingPathComponent(markerName)
        guard let markerType = try? fm.attributesOfItem(atPath: marker.path)[.type] as? FileAttributeType,
              markerType == .typeRegular,
              let data = try? Data(contentsOf: marker),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schemaVersion"] as? Int == 1,
              value["sourceDirectory"] as? String == sourceDirectory.standardizedFileURL.path else { return nil }
        return value
    }

    private static func writeRecoveryMarker(_ value: [String: Any], in folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: folder.appendingPathComponent(markerName), options: .atomic)
    }

    private static func contentSHA256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                digest.update(data: chunk)
            }
        } catch { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Staging and rollback are same-volume renames. RENAME_EXCL atomically
    /// rejects every occupied destination, including dangling symlinks.
    static func moveWithoutReplacing(_ source: URL, _ destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
            }
        }
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    struct Progress: Sendable {
        enum Phase: String, Sendable { case preparing, moving, finishing }
        let phase: Phase
        let completed: Int
        let total: Int
        let elapsedSeconds: Double
    }

    struct Result: Sendable {
        let removedFiles: Int
        let failedFiles: Int
        var retainedRecordings: Int = 0
        let enumerationFailed: Bool
        let recoveryDirectory: URL?
        let trashDirectory: URL?
        let elapsedSeconds: Double
        var succeeded: Bool { failedFiles == 0 && !enumerationFailed && recoveryDirectory == nil }
    }

    struct RestoreResult: Sendable, Equatable {
        let restoredFiles: Int
        let retainedFiles: Int
        let recoveryDirectory: URL?
        var succeeded: Bool { retainedFiles == 0 && recoveryDirectory == nil }
    }

    /// Restore one validated batch directly to the recordings folder. Groups are
    /// claimed and preflighted as a unit so an archived transcript can never be
    /// paired with newer audio (or vice versa). Failed and conflicting groups stay
    /// inside the marked batch for an explicit retry; no destination is overwritten.
    static func restoreBatch(_ recovery: URL, to directory: URL,
                             move: (URL, URL) throws -> Void = moveWithoutReplacing) -> RestoreResult {
        restoreLock.lock()
        defer { restoreLock.unlock() }
        let fm = FileManager.default
        guard let destinationType = try? fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType,
              destinationType == .typeDirectory,
              var marker = recoveryMarker(in: recovery, sourceDirectory: directory) else {
            return RestoreResult(restoredFiles: 0, retainedFiles: 1, recoveryDirectory: recovery)
        }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: recovery,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            return RestoreResult(restoredFiles: 0, retainedFiles: 1, recoveryDirectory: recovery)
        }
        var groups: [String: [URL]] = [:]
        var retained = 0
        for source in entries where source.lastPathComponent != markerName {
            guard RecordingStore.isRecordingArtifact(source.lastPathComponent),
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                retained += 1; continue
            }
            groups[RecordingActivity.stem(for: source), default: []].append(source)
        }
        // A crash after the last file of a group moved but before its transaction
        // record cleared leaves no source entry. Reinsert that stem so retry can
        // verify the recorded destination identities and finish cleanup.
        let pendingTransaction = marker["restoreTransaction"] as? [String: Any]
        if let transaction = pendingTransaction {
            guard let stem = transaction["stem"] as? String, !stem.isEmpty,
                  let records = transaction["files"] as? [[String: Any]], !records.isEmpty else {
                return RestoreResult(restoredFiles: 0, retainedFiles: 1, recoveryDirectory: recovery)
            }
            let names = records.compactMap { $0["name"] as? String }
            guard names.count == records.count, Set(names).count == names.count,
                  records.allSatisfy({ record in
                      guard let name = record["name"] as? String,
                            URL(fileURLWithPath: name).lastPathComponent == name,
                            RecordingStore.isRecordingArtifact(name),
                            RecordingActivity.stem(for: URL(fileURLWithPath: name)) == stem,
                            let device = record["device"] as? String, UInt64(device) != nil,
                            let inode = record["inode"] as? String, UInt64(inode) != nil,
                            let hash = record["sha256"] as? String, hash.count == 64,
                            hash.allSatisfy({ $0.isHexDigit }) else { return false }
                      return true
                  }) else {
                return RestoreResult(restoredFiles: 0, retainedFiles: 1, recoveryDirectory: recovery)
            }
        }
        let pendingStem = pendingTransaction?["stem"] as? String
        if let stem = pendingStem, groups[stem] == nil {
            groups[stem] = []
        }
        // Open the destination maintenance epoch before the collision snapshot so
        // a writer cannot finish in the gap and evade both the snapshot and claims.
        let removal = RecordingActivity.shared.beginRemoval(in: directory)
        defer { removal.finish() }
        let destinationNames: [String]
        do { destinationNames = try fm.contentsOfDirectory(atPath: directory.path) }
        catch { return RestoreResult(restoredFiles: 0, retainedFiles: max(1, entries.count - 1), recoveryDirectory: recovery) }
        let destinationNamesByStem = Dictionary(grouping: destinationNames.filter {
            RecordingStore.isRecordingArtifact($0)
        }) { RecordingActivity.stem(for: URL(fileURLWithPath: $0)) }
        var restored = 0
        // Finish a durable in-flight group before beginning another one. Otherwise
        // a retry could overwrite the only transaction record for a partially moved
        // group while dictionary iteration happens to visit a different stem first.
        let orderedStems = groups.keys.sorted {
            if $0 == pendingStem { return true }
            if $1 == pendingStem { return false }
            return $0 < $1
        }
        for stem in orderedStems {
            let sources = groups[stem] ?? []
            let representative = directory.appendingPathComponent(stem + ".wav")
            guard removal.claim(representative) else {
                let pendingCount = ((pendingTransaction?["stem"] as? String) == stem)
                    ? ((pendingTransaction?["files"] as? [[String: Any]])?.count ?? 1) : sources.count
                retained += max(1, pendingCount)
                if stem == pendingStem { break }
                continue
            }
            var expected: [[String: Any]]
            if let transaction = marker["restoreTransaction"] as? [String: Any],
               transaction["stem"] as? String == stem,
               let recorded = transaction["files"] as? [[String: Any]] {
                expected = recorded
            } else {
                guard destinationNamesByStem[stem]?.isEmpty != false else {
                    retained += sources.count; continue
                }
                expected = sources.compactMap { source in
                    guard let attrs = try? fm.attributesOfItem(atPath: source.path),
                          let device = attrs[.systemNumber] as? NSNumber,
                          let inode = attrs[.systemFileNumber] as? NSNumber,
                          let hash = contentSHA256(source) else { return nil }
                    return ["name": source.lastPathComponent,
                            "device": device.stringValue, "inode": inode.stringValue,
                            "sha256": hash]
                }
                guard expected.count == sources.count else { retained += sources.count; continue }
                marker["restoreTransaction"] = ["stem": stem, "files": expected]
                do { try writeRecoveryMarker(marker, in: recovery) }
                catch { retained += sources.count; continue }
            }

            func matches(_ url: URL, _ record: [String: Any]) -> Bool {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let device = attrs[.systemNumber] as? NSNumber,
                      let inode = attrs[.systemFileNumber] as? NSNumber else { return false }
                return device.stringValue == record["device"] as? String
                    && inode.stringValue == record["inode"] as? String
                    && contentSHA256(url) == record["sha256"] as? String
            }
            // A retry may proceed only when every recorded file is still either at
            // its original recovery identity or its restored destination identity.
            // Also reject any new companion in the destination. This prevents an
            // old transcript from being paired with audio replaced after a crash.
            let expectedNames = Set(expected.compactMap { $0["name"] as? String })
            let unexpectedCompanion = (destinationNamesByStem[stem] ?? []).contains {
                !expectedNames.contains($0)
            }
            let identitiesIntact = expected.allSatisfy { record in
                guard let name = record["name"] as? String else { return false }
                let sourceMatches = matches(recovery.appendingPathComponent(name), record)
                let destination = directory.appendingPathComponent(name)
                let destinationMatches = matches(destination, record)
                let destinationIsAbsent = (try? fm.attributesOfItem(atPath: destination.path)) == nil
                return (sourceMatches || destinationMatches) && (destinationIsAbsent || destinationMatches)
            }
            guard !unexpectedCompanion, identitiesIntact else {
                retained += max(1, expected.count)
                break
            }
            var groupFailed = false
            for record in expected {
                guard let name = record["name"] as? String else { groupFailed = true; continue }
                let source = recovery.appendingPathComponent(name)
                let destination = directory.appendingPathComponent(name)
                if matches(destination, record) { continue } // safely resumed after interruption
                guard matches(source, record) else { groupFailed = true; continue }
                do {
                    try move(source, destination)
                    restored += 1
                }
                catch { groupFailed = true }
            }
            let complete = expected.allSatisfy { record in
                guard let name = record["name"] as? String else { return false }
                return matches(directory.appendingPathComponent(name), record)
            }
            if complete {
                marker.removeValue(forKey: "restoreTransaction")
                do { try writeRecoveryMarker(marker, in: recovery) }
                catch {
                    // The files are restored, but retain the marked folder so a
                    // retry can verify their identities and safely finish cleanup.
                    marker["restoreTransaction"] = ["stem": stem, "files": expected]
                    retained += 1
                    break
                }
            } else {
                retained += expected.filter { record in
                    guard let name = record["name"] as? String else { return true }
                    return !matches(directory.appendingPathComponent(name), record)
                }.count
                if groupFailed && retained == 0 { retained = 1 }
                // Preserve this transaction as the only durable identity record.
                // No later group may replace it until a retry completes it.
                break
            }
        }
        if retained == 0 {
            try? fm.removeItem(at: recovery.appendingPathComponent(markerName))
            if rmdir(recovery.path) == 0 {
                return RestoreResult(restoredFiles: restored, retainedFiles: 0, recoveryDirectory: nil)
            }
            // A file may have arrived after enumeration. Restore the marker so this
            // remains a recognized recovery folder and never becomes hidden debris.
            if let marker = try? JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "sourceDirectory": directory.standardizedFileURL.path,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ], options: [.sortedKeys]) {
                try? marker.write(to: recovery.appendingPathComponent(markerName), options: .atomic)
            }
            retained = 1
        }
        return RestoreResult(restoredFiles: restored, retainedFiles: retained,
                             recoveryDirectory: recovery)
    }

    static func restorePendingRecordings(in directory: URL) -> RestoreResult {
        guard let recovery = try? recoveryDirectories(in: directory).first else {
            return RestoreResult(restoredFiles: 0, retainedFiles: 0, recoveryDirectory: nil)
        }
        return restoreBatch(recovery, to: directory)
    }

    /// Undo a successful batch move. Move the container out of Trash to its marked
    /// recovery location, then use the same group-safe restore path as Finder Put Back.
    static func restoreTrashedBatch(_ trashed: URL, to directory: URL) -> RestoreResult {
        restoreLock.lock()
        defer { restoreLock.unlock() }
        guard let type = try? FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType,
              type == .typeDirectory,
              recoveryMarker(in: trashed, sourceDirectory: directory) != nil else {
            return RestoreResult(restoredFiles: 0, retainedFiles: 1, recoveryDirectory: trashed)
        }
        let recovery = directory.deletingLastPathComponent().appendingPathComponent(trashed.lastPathComponent)
        do { try moveWithoutReplacing(trashed, recovery) }
        catch { return RestoreResult(restoredFiles: 0, retainedFiles: 1, recoveryDirectory: trashed) }
        return restoreBatch(recovery, to: directory)
    }

    /// Group claims exclude live users without holding a mutex across filesystem work.
    /// Tests inject a private Trash directory, never the system Trash.
    static func run(directory: URL,
                    activity: RecordingActivity.Removal? = nil,
                    progress: @Sendable (Progress) -> Void = { _ in },
                    trash: (URL) throws -> URL? = systemTrash,
                    move: (URL, URL) throws -> Void = moveWithoutReplacing) -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        let fm = FileManager.default
        let removal = activity ?? RecordingActivity.shared.beginRemoval(in: directory)
        defer { if activity == nil { removal.finish() } }
        var retainedGroups = Set<RecordingActivity.Group>()
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }
        func finish(_ removed: Int, _ failed: Int, enumeration: Bool = false,
                    recovery: URL? = nil, trashed: URL? = nil) -> Result {
            // New takes can arrive after target enumeration. Count only protected
            // groups with an actual primary WAV, not failed-start/phantom read leases.
            for group in removal.protectedGroups() {
                let name = group.stem + ".wav"
                guard RecordingStore.isRecordingArtifact(name) else { continue }
                let path = URL(fileURLWithPath: group.directory).appendingPathComponent(name).path
                if fm.fileExists(atPath: path) { retainedGroups.insert(group) }
            }
            let seconds = elapsed()
            DiagnosticLogger.shared.log("Recordings removal: mode=trash removed=\(removed) failed=\(failed) retainedRecordings=\(retainedGroups.count) enumerationFailed=\(enumeration) recoveryRequired=\(recovery != nil) elapsedSeconds=\(String(format: "%.3f", seconds))")
            return Result(removedFiles: removed, failedFiles: failed, retainedRecordings: retainedGroups.count,
                          enumerationFailed: enumeration,
                          recoveryDirectory: recovery, trashDirectory: trashed, elapsedSeconds: seconds)
        }
        DiagnosticLogger.shared.log("Recordings removal: started mode=trash")
        progress(Progress(phase: .preparing, completed: 0, total: 0, elapsedSeconds: elapsed()))
        let targets: [URL]
        do {
            if let pending = try recoveryDirectories(in: directory).first {
                return finish(0, 0, recovery: pending)
            }
            let type = try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { return finish(0, 0, enumeration: true) }
            targets = try fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter {
                guard RecordingStore.isRecordingArtifact($0.lastPathComponent) else { return false }
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
        } catch {
            let failure = error as NSError
            let absent = failure.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code)
            return finish(0, 0, enumeration: !absent)
        }
        guard !targets.isEmpty else { return finish(0, 0) }

        let staging: URL
        let marker: Data
        do {
            // One recoverable folder in Finder Trash, not tens of thousands of loose files.
            // Same-volume staging makes each move atomic. A crash leaves an identifiable
            // folder beside recordings; neither prune nor permanent delete traverses it.
            let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let folder = directory.deletingLastPathComponent().appendingPathComponent(
                "\(folderPrefix)\(date) \(UUID().uuidString)", isDirectory: true)
            marker = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "sourceDirectory": directory.standardizedFileURL.path,
                "createdAt": date,
            ], options: [.sortedKeys])
            try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            staging = folder
            do { try marker.write(to: folder.appendingPathComponent(markerName), options: .atomic) }
            catch {
                _ = rmdir(folder.path) // Only succeeds if still empty.
                return finish(0, targets.count)
            }
        } catch { return finish(0, targets.count) }

        func removeEmptyStaging() -> Bool {
            guard let entries = try? fm.contentsOfDirectory(atPath: staging.path),
                  entries.allSatisfy({ $0 == markerName }) else { return false }
            try? fm.removeItem(at: staging.appendingPathComponent(markerName))
            if rmdir(staging.path) == 0 { return true } // Never recursively delete a new arrival.
            try? marker.write(to: staging.appendingPathComponent(markerName), options: .atomic)
            return false
        }

        var moved: [URL] = []
        var failed = 0
        var lastUpdate = -Double.infinity
        for (index, url) in targets.enumerated() {
            guard removal.claim(url) else {
                retainedGroups.insert(RecordingActivity.group(for: url))
                continue
            }
            do {
                guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw Failure.sourceChanged
                }
                try move(url, staging.appendingPathComponent(url.lastPathComponent))
                moved.append(url)
            } catch { failed += 1 }
            let seconds = elapsed()
            if seconds - lastUpdate >= 0.05 || index + 1 == targets.count {
                progress(Progress(phase: .moving,
                                  completed: index + 1, total: targets.count, elapsedSeconds: seconds))
                lastUpdate = seconds
            }
        }
        guard !moved.isEmpty else {
            return finish(0, failed, recovery: removeEmptyStaging() ? nil : staging)
        }
        progress(Progress(phase: .finishing, completed: targets.count,
                          total: targets.count, elapsedSeconds: elapsed()))
        do {
            let destination = try trash(staging)
            guard !fm.fileExists(atPath: staging.path) else { throw Failure.trashDidNotMove }
            return finish(moved.count, failed, trashed: destination)
        } catch {
            // A failed Trash operation must not silently hide recordings. Return
            // moved files to their exact paths without overwriting new arrivals.
            var stranded = 0
            for original in moved {
                do {
                    // Keep this explicit even for injected movers; the production
                    // rename additionally enforces no replacement atomically.
                    if (try? fm.attributesOfItem(atPath: original.path)) != nil { throw Failure.sourceChanged }
                    try move(staging.appendingPathComponent(original.lastPathComponent), original)
                }
                catch { stranded += 1 }
                let seconds = elapsed()
                if seconds - lastUpdate >= 0.05 {
                    progress(Progress(phase: .finishing, completed: targets.count,
                                      total: targets.count, elapsedSeconds: seconds))
                    lastUpdate = seconds
                }
            }
            let cleaned = stranded == 0 && removeEmptyStaging()
            let recovery = !cleaned && fm.fileExists(atPath: staging.path) ? staging : nil
            return finish(0, targets.count, recovery: recovery)
        }
    }

    static func systemTrash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
}
