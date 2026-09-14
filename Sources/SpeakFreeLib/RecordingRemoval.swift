// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import Foundation
import Darwin

enum RecordingRemoval {
    private static let folderPrefix = "SpeakFree Recordings "
    private static let markerName = ".speakfree-recording-removal.json"

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
            let marker = folder.appendingPathComponent(markerName)
            guard let markerType = try? fm.attributesOfItem(atPath: marker.path)[.type] as? FileAttributeType,
                  markerType == .typeRegular,
                  let data = try? Data(contentsOf: marker),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return value["schemaVersion"] as? Int == 1
                && value["sourceDirectory"] as? String == directory.standardizedFileURL.path
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
        let enumerationFailed: Bool
        let recoveryDirectory: URL?
        let trashDirectory: URL?
        let elapsedSeconds: Double
        var succeeded: Bool { failedFiles == 0 && !enumerationFailed && recoveryDirectory == nil }
    }

    /// The caller owns RecordingStore's mutation lock. Tests inject a private Trash
    /// directory; they never send fixtures or customer data to the system Trash.
    static func run(directory: URL,
                    progress: @Sendable (Progress) -> Void = { _ in },
                    trash: (URL) throws -> URL? = systemTrash,
                    move: (URL, URL) throws -> Void = moveWithoutReplacing) -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        let fm = FileManager.default
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }
        func finish(_ removed: Int, _ failed: Int, enumeration: Bool = false,
                    recovery: URL? = nil, trashed: URL? = nil) -> Result {
            let seconds = elapsed()
            DiagnosticLogger.shared.log("Recordings removal: mode=trash removed=\(removed) failed=\(failed) enumerationFailed=\(enumeration) recoveryRequired=\(recovery != nil) elapsedSeconds=\(String(format: "%.3f", seconds))")
            return Result(removedFiles: removed, failedFiles: failed, enumerationFailed: enumeration,
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

    private static func systemTrash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
}
