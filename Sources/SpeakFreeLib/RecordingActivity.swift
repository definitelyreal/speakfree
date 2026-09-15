// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import Foundation

/// Coordinates live recording groups with maintenance. This lock protects only
/// in-memory admission: no filesystem, model, dispatch wait, or callback runs inside it.
/// Callers acquire before creating/opening/scheduling work and release after all file use.
/// Coordinates this process only; external CLI readers and manual filesystem changes
/// require separate coordination. It does not override owner-requested opt-out deletion.
final class RecordingActivity: @unchecked Sendable {
    static let shared = RecordingActivity()

    struct Group: Hashable, Sendable {
        let directory: String
        let stem: String
    }

    enum ActivityError: LocalizedError {
        case beingRemoved
        var errorDescription: String? { "This recording is being moved or removed. Please try again afterward." }
    }

    final class Lease: @unchecked Sendable {
        let generation: UInt64
        let audioURL: URL
        private let owner: RecordingActivity
        private let id: UUID
        fileprivate init(owner: RecordingActivity, id: UUID, generation: UInt64, audioURL: URL) {
            self.owner = owner; self.id = id; self.generation = generation; self.audioURL = audioURL
        }
        /// Idempotent; an old lease can never release a newer acquisition.
        func release() { owner.release(id) }
        deinit { release() }
    }

    final class Removal: @unchecked Sendable {
        private let owner: RecordingActivity
        private let id: UUID
        private let sourceDirectory: String
        private let canonicalDirectory: String
        fileprivate init(owner: RecordingActivity, id: UUID, sourceDirectory: String, canonicalDirectory: String) {
            self.owner = owner; self.id = id
            self.sourceDirectory = sourceDirectory; self.canonicalDirectory = canonicalDirectory
        }
        /// Claims the whole group atomically against reader/writer admission. A
        /// rejected group stays protected for this removal even if its lease ends.
        func claim(_ url: URL) -> Bool {
            let normalized = url.standardizedFileURL
            // The directory was canonicalized once before enumeration. Avoid a
            // symlink-resolution filesystem walk for every one of 70,000 artifacts.
            let group = normalized.deletingLastPathComponent().path == sourceDirectory
                ? Group(directory: canonicalDirectory, stem: RecordingActivity.stem(for: normalized))
                : RecordingActivity.group(for: normalized)
            return owner.claim(group, removal: id)
        }
        func finish() { owner.finish(id) }
        func protectedGroups() -> Set<Group> { owner.protectedGroups(id) }
        deinit { finish() }
    }

    private struct ActiveGroup { var count: Int; let generation: UInt64 }
    private final class RemovalState {
        let directory: String
        var protected: Set<Group>
        var claimed: Set<Group> = []
        init(directory: String, protected: Set<Group>) {
            self.directory = directory; self.protected = protected
        }
    }
    private let lock = NSLock()
    private var groups: [Group: ActiveGroup] = [:]
    private var leases: [UUID: Group] = [:]
    private var removals: [UUID: RemovalState] = [:]
    private var claims: [Group: UUID] = [:]
    private var nextGeneration: UInt64 = 1

    /// Resolve the existing parent before admission, outside the registry lock.
    /// The WAV itself may not exist yet. Directory symlink aliases must share leases.
    static func group(for url: URL) -> Group {
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent().resolvingSymlinksInPath()
        return Group(directory: parent.path, stem: stem(for: normalized))
    }

    static func stem(for url: URL) -> String {
        let name = url.lastPathComponent
        let suffixes = [".builtin.raw.txt", ".bt.raw.txt", ".parakeet.txt", ".whisper.txt",
                        ".raw.txt", ".meta.json", ".bt.wav", ".wav", ".txt"]
        let suffix = suffixes.first { name.hasSuffix($0) }
        return suffix.map { String(name.dropLast($0.count)) } ?? name
    }

    func acquire(_ url: URL) throws -> Lease {
        let group = Self.group(for: url), id = UUID()
        lock.lock(); defer { lock.unlock() }
        guard claims[group] == nil else { throw ActivityError.beingRemoved }
        let generation = groups[group]?.generation ?? nextGeneration
        if groups[group] == nil { nextGeneration &+= 1 }
        groups[group] = ActiveGroup(count: (groups[group]?.count ?? 0) + 1, generation: generation)
        leases[id] = group
        // Capture a stable deletion epoch: even an acquisition that completes
        // during slow enumeration remains excluded from that operation.
        for removalID in removals.keys {
            guard removals[removalID]?.directory == group.directory else { continue }
            removals[removalID]?.protected.insert(group)
        }
        return Lease(owner: self, id: id, generation: generation, audioURL: url)
    }

    /// Existing-file readers may enter through an individual file symlink as well
    /// as a directory alias. Resolve before admission, never inside the registry lock.
    func acquireReading(_ url: URL) throws -> Lease { try acquire(url.resolvingSymlinksInPath()) }

    func beginRemoval(in directory: URL) -> Removal {
        let source = directory.standardizedFileURL.path
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path, id = UUID()
        lock.lock(); defer { lock.unlock() }
        removals[id] = RemovalState(directory: path,
            protected: Set(groups.keys.filter { $0.directory == path }))
        return Removal(owner: self, id: id, sourceDirectory: source, canonicalDirectory: path)
    }

    private func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let group = leases.removeValue(forKey: id), var active = groups[group] else { return }
        active.count -= 1
        if active.count == 0 { groups.removeValue(forKey: group) }
        else { groups[group] = active }
    }

    private func claim(_ group: Group, removal id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state = removals[id], state.directory == group.directory else { return false }
        if let owner = claims[group] { return owner == id }
        guard groups[group] == nil, !state.protected.contains(group) else {
            state.protected.insert(group)
            return false
        }
        claims[group] = id
        state.claimed.insert(group)
        return true
    }

    private func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let state = removals.removeValue(forKey: id) else { return }
        for group in state.claimed where claims[group] == id { claims.removeValue(forKey: group) }
    }

    private func protectedGroups(_ id: UUID) -> Set<Group> {
        lock.lock(); defer { lock.unlock() }
        return removals[id]?.protected ?? []
    }
}
