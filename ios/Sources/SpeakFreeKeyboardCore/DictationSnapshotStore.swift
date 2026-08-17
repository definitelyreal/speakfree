// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

public enum DictationSnapshotStoreError: Error, Equatable, Sendable {
    case staleRevision(existing: UInt64, proposed: UInt64)
    case conflictingRevision(UInt64)
    case activeSessionConflict(existing: UUID, proposed: UUID)
    case terminalSessionMutation
    case finalizedHistoryChanged
}

/// Atomic JSON transport for a snapshot URL inside an App Group container.
///
/// The containing app resolves its App Group container and is the sole writer. Atomic replacement
/// prevents the extension from observing partial JSON. Session/revision checks reject a delayed
/// write from the current speech session.
public struct DictationSnapshotStore: Sendable {
    public static let defaultFilename = "speakfree-dictation-v1.json"

    public let snapshotURL: URL

    public var terminalDirectoryURL: URL {
        snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("speakfree-dictation-terminal-v1", isDirectory: true)
    }

    public init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
    }

    public init(
        appGroupContainerURL: URL,
        filename: String = DictationSnapshotStore.defaultFilename
    ) {
        self.snapshotURL = appGroupContainerURL.appendingPathComponent(filename, isDirectory: false)
    }

    public func read() throws -> DictationSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        let data = try Data(contentsOf: snapshotURL)
        let snapshot = try Self.decoder.decode(DictationSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    public func write(_ snapshot: DictationSnapshot) throws {
        try snapshot.validate()

        if let existing = try read() {
            if existing.sessionID == snapshot.sessionID {
                guard snapshot.revision >= existing.revision else {
                    throw DictationSnapshotStoreError.staleRevision(
                        existing: existing.revision,
                        proposed: snapshot.revision
                    )
                }
                if snapshot.revision == existing.revision {
                    guard snapshot == existing else {
                        throw DictationSnapshotStoreError.conflictingRevision(snapshot.revision)
                    }
                    return
                }
                guard existing.phase == .active else {
                    throw DictationSnapshotStoreError.terminalSessionMutation
                }
                guard snapshot.finalizedSegments.count >= existing.finalizedSegments.count,
                      Array(snapshot.finalizedSegments.prefix(existing.finalizedSegments.count))
                        == existing.finalizedSegments else {
                    throw DictationSnapshotStoreError.finalizedHistoryChanged
                }
            } else {
                // A delayed callback from an older recognizer must never overwrite the currently
                // active session. The writer must terminalize or explicitly remove it first.
                guard existing.phase != .active else {
                    throw DictationSnapshotStoreError.activeSessionConflict(
                        existing: existing.sessionID,
                        proposed: snapshot.sessionID
                    )
                }
            }
        }

        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
        try protect(snapshotURL)
        if snapshot.phase != .active {
            try FileManager.default.createDirectory(
                at: terminalDirectoryURL,
                withIntermediateDirectories: true
            )
            let terminalURL = terminalSnapshotURL(for: snapshot.sessionID)
            try data.write(to: terminalURL, options: .atomic)
            try protect(terminalURL)
        }
    }

    /// Terminal snapshots are retained independently of the single live-session slot. This lets
    /// a keyboard that was hidden during Stop/Cancel reconcile its already-inserted volatile tail
    /// even if the user starts another session before returning to that document.
    public func readTerminal(sessionID: UUID) throws -> DictationSnapshot? {
        let url = terminalSnapshotURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try Self.decoder.decode(DictationSnapshot.self, from: Data(contentsOf: url))
        try snapshot.validate()
        guard snapshot.sessionID == sessionID, snapshot.phase != .active else { return nil }
        return snapshot
    }

    public func removeTerminalSnapshots(olderThan maximumAge: TimeInterval, now: Date = Date()) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: terminalDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: snapshotURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private func terminalSnapshotURL(for sessionID: UUID) -> URL {
        terminalDirectoryURL.appendingPathComponent(sessionID.uuidString + ".json", isDirectory: false)
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
