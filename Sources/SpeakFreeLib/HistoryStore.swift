// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core · 2026-10-01
import AppKit
import Darwin
import Foundation

/// A main-thread model with serial off-main disk I/O. The application owns its policy;
/// this file does not read global preferences or the user's clipboard.
final class HistoryStore {
    enum PersistenceError: LocalizedError {
        case unreadableArchive
        var errorDescription: String? {
            "Saved history could not be read. Clear history to reset its storage before trying again."
        }
    }
    struct Policy: Equatable {
        var captureDictations = true
        var captureClipboard = false
        var persistent = false
        var maximumEntries = 200
        var maximumAge: TimeInterval = 7 * 24 * 60 * 60
        var maximumBytes = 128 * 1024 * 1024
        var maximumEntryBytes = 32 * 1024 * 1024
    }

    private struct Archive: Codable {
        let version: Int
        let entries: [HistoryEntry]
    }

    private(set) var entries: [HistoryEntry] = []
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    private(set) var isLoading = false
    private(set) var policy: Policy
    var onChange: (() -> Void)?

    private let fileURL: URL?
    private let now: () -> Date
    private let ioQueue = DispatchQueue(label: "com.definitelyreal.speakfree.history-storage", qos: .utility)
    private var loadGeneration: UInt64 = 0
    private var removedWhileLoading = Set<UUID>()
    private var archivesRemovedWhileLoading = Set<String>()
    private var persistenceBlocked = false
    private var pendingSave: DispatchWorkItem?
    private var diskOperation: UInt64 = 0
    private var lastPersistenceResult: Result<Void, Error> = .success(())

    init(fileURL: URL? = nil, policy: Policy = .init(), now: @escaping () -> Date = Date.init) {
        precondition(Thread.isMainThread)
        self.fileURL = fileURL
        self.policy = Self.bounded(policy)
        self.now = now
        if policy.persistent { load() }
        else {
            // Session/off can be selected while this process is not running, or a prior
            // removal can have failed. Honor that policy on startup without loading bytes.
            schedulePersistence(immediate: true)
        }
    }

    func configure(_ value: Policy) {
        precondition(Thread.isMainThread)
        let next = Self.bounded(value)
        guard next != policy else { return }
        let wasPersistent = policy.persistent
        let previousIDs = entries.map(\.id)
        policy = next
        prune()
        changed()
        if !wasPersistent && policy.persistent {
            // Session mode has already chosen removal of any prior saved copy. Enabling
            // persistence saves this session; it must not cancel a queued removal then
            // resurrect the old archive by loading it. Only persistent startup reads disk.
            loadGeneration &+= 1
            isLoading = false
            persistenceBlocked = false
            schedulePersistence(immediate: true)
        }
        else if wasPersistent && !policy.persistent {
            loadGeneration &+= 1
            isLoading = false
            persistenceBlocked = false
            schedulePersistence(immediate: true)
        } else if previousIDs != entries.map(\.id) { schedulePersistence() }
    }

    @discardableResult
    func addDictation(_ text: String, sourceAppBundleID: String? = nil, linkedArchiveID: String? = nil) -> HistoryEntry? {
        precondition(Thread.isMainThread)
        guard policy.captureDictations, !text.isEmpty else { return nil }
        let entry = HistoryEntry(createdAt: now(), source: .dictation,
                                 sourceAppBundleID: sourceAppBundleID, linkedArchiveID: linkedArchiveID,
                                 items: [.init(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue,
                                                                      data: Data(text.utf8))])])
        return add(entry)
    }

    @discardableResult
    func addClipboard(items: [HistoryPasteboardItem], sourceAppBundleID: String? = nil) -> HistoryEntry? {
        precondition(Thread.isMainThread)
        guard policy.captureClipboard else { return nil }
        return add(.init(createdAt: now(), source: .clipboard, sourceAppBundleID: sourceAppBundleID, items: items))
    }

    /// An explicit, bounded archive import. Historical dates/IDs are preserved, and an
    /// already linked recording is never re-imported simply because its text changed.
    @discardableResult
    func importDictations(_ candidates: [HistoryEntry]) -> Int {
        precondition(Thread.isMainThread)
        guard policy.captureDictations else { return 0 }
        guard !isLoading else {
            lastError = "Saved history is still loading. Try importing again in a moment."
            changed()
            return 0
        }
        var knownIDs = Set(entries.map(\.id))
        var knownArchives = Set(entries.compactMap(\.linkedArchiveID))
        var addedIDs = Set<UUID>()
        for entry in candidates {
            guard entry.source == .dictation,
                  Self.isValid(entry, maximumEntryBytes: policy.maximumEntryBytes),
                  !knownIDs.contains(entry.id),
                  entry.linkedArchiveID.map({ !knownArchives.contains($0) }) ?? true else { continue }
            knownIDs.insert(entry.id)
            if let linked = entry.linkedArchiveID { knownArchives.insert(linked) }
            addedIDs.insert(entry.id)
            entries.append(entry)
        }
        guard !addedIDs.isEmpty else { return 0 }
        prune()
        changed()
        schedulePersistence()
        return entries.filter { addedIDs.contains($0.id) }.count
    }

    func remove(id: UUID) {
        precondition(Thread.isMainThread)
        if isLoading { removedWhileLoading.insert(id) }
        entries.removeAll { $0.id == id }
        changed()
        schedulePersistence(immediate: true)
    }

    func removeLinkedArchive(id: String) {
        precondition(Thread.isMainThread)
        if isLoading { archivesRemovedWhileLoading.insert(id) }
        entries.removeAll { $0.linkedArchiveID == id }
        changed()
        schedulePersistence(immediate: true)
    }

    /// Clears history storage, not recording/transcript archives managed by the app.
    /// Filesystem deletion is not a promise of forensic erasure or removal from backups.
    func clear() {
        precondition(Thread.isMainThread)
        entries.removeAll()
        loadGeneration &+= 1
        isLoading = false
        persistenceBlocked = false
        lastError = nil
        changed()
        schedulePersistence(immediate: true)
    }

    func filtered(source: HistoryEntry.Source? = nil, query: String = "") -> [HistoryEntry] {
        precondition(Thread.isMainThread)
        return entries.filter { (source == nil || $0.source == source) && $0.matches(query) }
    }

    /// Apply age limits even when no new copies occur, e.g. before opening the picker.
    func pruneExpired() {
        precondition(Thread.isMainThread)
        let count = entries.count
        prune()
        if entries.count != count { changed(); schedulePersistence() }
    }

    /// Drains the current load, its main-thread merge, and the latest pending write/deletion.
    /// The caller must stop new capture first for a termination flush. No waits block main;
    /// a caller's bounded termination gate can cancel quitting if the disk never responds.
    func flushPendingPersistence(completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        ioQueue.async { [self] in
            DispatchQueue.main.async {
                if self.isLoading {
                    self.flushPendingPersistence(completion: completion)
                    return
                }
                guard !self.persistenceBlocked else {
                    completion(.failure(PersistenceError.unreadableArchive))
                    return
                }
                // Do not rewrite a clean archive merely because the app is quitting.
                let failedPreviously: Bool
                if case .failure = self.lastPersistenceResult { failedPreviously = true } else { failedPreviously = false }
                if self.pendingSave != nil || failedPreviously { self.schedulePersistence(immediate: true) }
                let operation = self.diskOperation
                self.ioQueue.async {
                    DispatchQueue.main.async {
                        if self.diskOperation != operation {
                            self.flushPendingPersistence(completion: completion)
                        } else { completion(self.lastPersistenceResult) }
                    }
                }
            }
        }
    }

    func flushForTesting(completion: @escaping () -> Void) {
        flushPendingPersistence { _ in completion() }
    }

    private func add(_ entry: HistoryEntry) -> HistoryEntry? {
        guard Self.isValid(entry, maximumEntryBytes: policy.maximumEntryBytes), entry.byteCount <= policy.maximumBytes else {
            lastError = "This clipboard item was not saved because it is too large or contains unsupported data."
            changed()
            return nil
        }
        // Identical later external copies remain distinct events. Source/time are not deduped.
        entries.insert(entry, at: 0)
        prune()
        changed()
        schedulePersistence()
        return entry
    }

    private func changed() {
        revision &+= 1
        onChange?()
    }

    private static func bounded(_ policy: Policy) -> Policy {
        var result = policy
        result.maximumEntries = min(10_000, max(1, result.maximumEntries))
        result.maximumAge = policy.maximumAge.isFinite ? max(1, policy.maximumAge) : 7 * 24 * 60 * 60
        result.maximumBytes = min(512 * 1024 * 1024, max(1, result.maximumBytes))
        result.maximumEntryBytes = min(result.maximumBytes, max(1, result.maximumEntryBytes))
        return result
    }

    private static func isValid(_ entry: HistoryEntry, maximumEntryBytes: Int) -> Bool {
        guard !entry.items.isEmpty, entry.items.count <= 512,
              entry.createdAt.timeIntervalSince1970.isFinite else { return false }
        var bytes = 0
        for item in entry.items {
            guard !item.representations.isEmpty, item.representations.count <= 64 else { return false }
            guard item.omittedRepresentationTypes.count <= 2,
                  item.omittedRepresentationTypes.allSatisfy({ ["public.tiff", "NSTIFFPboardType"].contains($0) }),
                  item.omittedRepresentationTypes.isEmpty || item.data(forType: .png) != nil else { return false }
            var types = Set<String>()
            for representation in item.representations {
                guard supported(representation.type), types.insert(representation.type).inserted,
                      representation.data.count <= maximumEntryBytes - bytes else { return false }
                bytes += representation.data.count
            }
        }
        return bytes <= maximumEntryBytes
    }

    private static func supported(_ type: String) -> Bool { HistoryEntry.supportedTypes.contains(type) }

    private func prune() {
        let cutoff = now().addingTimeInterval(-policy.maximumAge)
        var bytes = 0
        var seen = Set<UUID>()
        entries = entries.sorted { $0.createdAt > $1.createdAt }.filter { entry in
            guard entry.createdAt >= cutoff, seen.count < policy.maximumEntries,
                  Self.isValid(entry, maximumEntryBytes: policy.maximumEntryBytes),
                  entry.byteCount <= policy.maximumBytes - bytes, seen.insert(entry.id).inserted else { return false }
            bytes += entry.byteCount
            return true
        }
    }

    private func load() {
        guard let fileURL else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let byteLimit = policy.maximumBytes
        isLoading = true
        removedWhileLoading.removeAll()
        archivesRemovedWhileLoading.removeAll()
        pendingSave?.cancel()
        pendingSave = nil
        ioQueue.async { [weak self] in
            let result: Result<[HistoryEntry], Error>
            do {
                if !FileManager.default.fileExists(atPath: fileURL.path) { result = .success([]) }
                else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let diskSize = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
                    // Binary plist overhead is bounded; reject an unexpectedly large file before allocation.
                    guard diskSize <= byteLimit + 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    let archive = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                    guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                    result = .success(archive.entries)
                }
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.policy.persistent else { return }
                self.isLoading = false
                switch result {
                case .success(let loaded):
                    let hadSessionEntries = !self.entries.isEmpty
                    self.entries += loaded.filter {
                        !self.removedWhileLoading.contains($0.id)
                            && !self.archivesRemovedWhileLoading.contains($0.linkedArchiveID ?? "")
                    }
                    self.prune()
                    self.persistenceBlocked = false
                    self.lastPersistenceResult = .success(())
                    self.changed()
                    if hadSessionEntries || self.entries.map(\.id) != loaded.map(\.id) {
                        self.schedulePersistence()
                    }
                case .failure:
                    self.persistenceBlocked = true
                    self.lastPersistenceResult = .failure(PersistenceError.unreadableArchive)
                    self.lastError = "Saved history could not be read. New items stay in this session. Clear history to reset its saved storage."
                    self.changed()
                }
                self.removedWhileLoading.removeAll()
                self.archivesRemovedWhileLoading.removeAll()
            }
        }
    }

    private func schedulePersistence(immediate: Bool = false) {
        guard let fileURL, !isLoading, !persistenceBlocked else { return }
        pendingSave?.cancel()
        diskOperation &+= 1
        let operation = diskOperation
        let snapshot = entries
        let shouldPersist = policy.persistent && !snapshot.isEmpty
        let work = DispatchWorkItem { [weak self] in
            let result: Result<Void, Error>
            do {
                if shouldPersist {
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    let data = try encoder.encode(Archive(version: 1, entries: snapshot))
                    try Self.atomicWrite(data, to: fileURL)
                } else {
                    do { try FileManager.default.removeItem(at: fileURL) }
                    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                        // Missing is already the requested state. Unlike fileExists, this
                        // does not silently treat an inaccessible parent folder as success.
                    }
                }
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self, self.diskOperation == operation else { return }
                self.pendingSave = nil
                self.lastPersistenceResult = result
                switch result {
                case .success: self.lastError = nil
                case .failure:
                    self.lastError = shouldPersist
                        ? "History could not be saved to disk. It remains available in this session; check storage space and folder permissions."
                        : "Saved history could not be removed from disk. Check folder permissions and clear history again."
                }
                self.changed()
            }
        }
        pendingSave = work
        // One write for a burst of changes; encoding and writing never run on the UI thread.
        if immediate { ioQueue.async(execute: work) }
        else { ioQueue.asyncAfter(deadline: .now() + 0.25, execute: work) }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
