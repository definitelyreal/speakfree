// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit

/// Clipboard safety shared by dictation and optional consumers. No history dependency.
enum PasteboardAccess {
    static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    enum Failure: Error, Equatable { case denied, unreadable, changed, tooLarge, cancelled }

    static func isDenied(_ pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysDeny }
        return false
    }

    /// A partial snapshot is never permission to replace the user's clipboard.
    /// A provider may still allocate its data before we can measure it; the byte cap
    /// bounds retained data, not memory used by a third-party provider.
    static func snapshot(_ pasteboard: NSPasteboard, maximumBytes: Int,
                         denied: Bool? = nil, cancelled: () -> Bool = { false },
                         read: (NSPasteboardItem, NSPasteboard.PasteboardType) -> Data? = { $0.data(forType: $1) }) throws -> Snapshot {
        guard !cancelled() else { throw Failure.cancelled }
        guard !(denied ?? isDenied(pasteboard)) else { throw Failure.denied }
        let generation = pasteboard.changeCount
        let advertisedTypes = pasteboard.types ?? []
        guard let items = pasteboard.pasteboardItems else {
            guard advertisedTypes.isEmpty else { throw Failure.unreadable }
            guard pasteboard.changeCount == generation else { throw Failure.changed }
            return []
        }
        guard !items.isEmpty || advertisedTypes.isEmpty else { throw Failure.unreadable }
        var size = 0
        var result: Snapshot = []
        for item in items {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard !cancelled() else { throw Failure.cancelled }
                guard pasteboard.changeCount == generation else { throw Failure.changed }
                let data = read(item, type)
                // A replacement can invalidate this item's promises. Report the changed
                // generation first so callers can retry, without reading later formats.
                guard !cancelled() else { throw Failure.cancelled }
                guard pasteboard.changeCount == generation else { throw Failure.changed }
                guard let data else { throw Failure.unreadable }
                guard data.count <= maximumBytes - size else { throw Failure.tooLarge }
                size += data.count
                representations.append((type, data))
            }
            guard !representations.isEmpty else { throw Failure.unreadable }
            result.append(representations)
        }
        guard !cancelled() else { throw Failure.cancelled }
        guard pasteboard.changeCount == generation else { throw Failure.changed }
        return result
    }
}

/// One bounded, best-effort rollback reader for explicit clipboard replacement.
/// A slow, inaccessible or oversized previous item cannot block a user's Copy/Paste
/// choice. In that case replacement proceeds without rollback, as for a remote offer.
/// A hung provider retains its worker slot; later choices do not spawn more readers.
final class PasteboardPreparation {
    static let shared = PasteboardPreparation()
    enum Failure: Error, Equatable { case busy, cancelled }

    final class Request {
        private let lock = NSLock()
        private var cancelled = false
        private var readingStopped = false
        fileprivate var completion: ((Result<Prepared, Error>) -> Void)?
        fileprivate var timeout: DispatchWorkItem?
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock(); cancelled = true; readingStopped = true; lock.unlock()
        }
        fileprivate var shouldStopReading: Bool {
            lock.lock(); defer { lock.unlock() }
            return readingStopped
        }
        fileprivate func stopReading() {
            lock.lock(); readingStopped = true; lock.unlock()
        }
    }

    struct Prepared {
        let pasteboardName: NSPasteboard.Name
        let generation: Int
        // nil when the previous offer cannot be read promptly within the byte limit.
        // Explicit replacement still works, but failed publication cannot restore it.
        let snapshot: PasteboardAccess.Snapshot?
        fileprivate let request: Request
        var isValid: Bool { !request.isCancelled }
    }

    typealias Reader = (NSPasteboard, Int, @escaping () -> Bool) throws -> PasteboardAccess.Snapshot
    private let executeRead: (@escaping () -> Void) -> Void
    private let scheduleTimeout: (DispatchWorkItem) -> Void
    private let read: Reader
    private let offeredTypes: (NSPasteboard) -> [[NSPasteboard.PasteboardType]]
    private var inFlight: Request?

    init(executeRead: ((@escaping () -> Void) -> Void)? = nil,
         scheduleTimeout: ((DispatchWorkItem) -> Void)? = nil,
         offeredTypes: @escaping (NSPasteboard) -> [[NSPasteboard.PasteboardType]] = {
             [$0.types ?? []] + ($0.pasteboardItems ?? []).map(\.types)
         },
         read: @escaping Reader = { board, limit, cancelled in
             try PasteboardAccess.snapshot(board, maximumBytes: limit, cancelled: cancelled)
         }) {
        let queue = DispatchQueue(label: "com.definitelyreal.speakfree.clipboard-preparation", qos: .userInitiated)
        self.executeRead = executeRead ?? { queue.async(execute: $0) }
        self.scheduleTimeout = scheduleTimeout ?? { DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: $0) }
        self.read = read
        self.offeredTypes = offeredTypes
    }

    @discardableResult
    func prepare(_ pasteboard: NSPasteboard, maximumBytes: Int,
                 completion: @escaping (Result<Prepared, Error>) -> Void) -> Request? {
        dispatchPrecondition(condition: .onQueue(.main))
        let request = Request()
        request.completion = completion
        let generation = pasteboard.changeCount
        let name = pasteboard.name
        guard inFlight == nil else {
            // The existing provider is stuck. The user still explicitly requested
            // replacement; keep the generation check and avoid another provider read.
            finish(request, result: .success(Prepared(pasteboardName: name, generation: generation,
                                                     snapshot: nil, request: request)))
            return request
        }
        inFlight = request
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.inFlight === request else { return }
            request.stopReading()
            let result: Result<Prepared, Error>
            if request.isCancelled { result = .failure(Failure.cancelled) }
            else if pasteboard.changeCount != generation { result = .failure(PasteboardAccess.Failure.changed) }
            else { result = .success(Prepared(pasteboardName: name, generation: generation,
                                             snapshot: nil, request: request)) }
            self.finish(request, result: result)
            // Keep inFlight: releasing it here would queue unbounded hung reads.
        }
        request.timeout = timeout
        scheduleTimeout(timeout)
        let reader = read
        executeRead { [self] in
            let result: Result<Prepared, Error>
            do {
                guard !request.shouldStopReading else { throw Failure.cancelled }
                guard pasteboard.changeCount == generation else { throw PasteboardAccess.Failure.changed }
                // Inspect offered type names only: requesting any payload could initiate
                // Universal Clipboard transfer and display a Continuity progress dialog.
                // Preflight every item's metadata before reading even the first local
                // payload: the root type list need not describe later remote items.
                let remote = offeredTypes(pasteboard).contains { $0.contains(PasteboardAccess.remoteClipboardType) }
                guard !request.shouldStopReading else { throw Failure.cancelled }
                guard pasteboard.changeCount == generation else { throw PasteboardAccess.Failure.changed }
                let snapshot: PasteboardAccess.Snapshot?
                if remote { snapshot = nil }
                else {
                    do { snapshot = try reader(pasteboard, maximumBytes, { request.shouldStopReading }) }
                    catch PasteboardAccess.Failure.tooLarge { snapshot = nil }
                    catch PasteboardAccess.Failure.unreadable { snapshot = nil }
                    catch PasteboardAccess.Failure.denied { snapshot = nil }
                }
                guard !request.shouldStopReading else { throw Failure.cancelled }
                guard pasteboard.changeCount == generation else { throw PasteboardAccess.Failure.changed }
                result = .success(Prepared(pasteboardName: name, generation: generation,
                                           snapshot: snapshot, request: request))
            } catch { result = .failure(error) }
            let deliver = {
                guard self.inFlight === request else { return }
                request.timeout?.cancel()
                request.timeout = nil
                self.inFlight = nil
                self.finish(request, result: request.isCancelled ? .failure(Failure.cancelled) : result)
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        return request
    }

    private func finish(_ request: Request, result: Result<Prepared, Error>) {
        let completion = request.completion
        request.completion = nil
        completion?(result)
    }
}

/// Exact generations, rather than time windows, let observers ignore our restores
/// without hiding a genuine copy made immediately afterward. May be posted by a tap.
enum PasteboardWriteReceipt {
    static let notification = Notification.Name("SpeakFreePasteboardWrite")
    static func post(_ pasteboard: NSPasteboard, generation: Int? = nil) {
        let info: [String: Any] = ["name": pasteboard.name.rawValue, "changeCount": generation ?? pasteboard.changeCount]
        let send = { NotificationCenter.default.post(name: notification, object: nil, userInfo: info) }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }
}

/// Checked publication shared by dictation, restores, and explicit copies. The clear's
/// returned generation is the only generation we may recover after a failed write.
/// NSPasteboard has no cross-process compare-and-swap: checks bound, but cannot remove,
/// the race between checking an external generation and asking the server to clear it.
struct PasteboardWriter {
    enum Failure: Equatable { case changed, clear, write }
    enum Recovery: Equatable { case restored, changed, unavailable, failed }
    struct Result {
        let generation: Int?
        let failure: Failure?
        let recoveryGeneration: Int?
    }
    var clear: (NSPasteboard, Bool) -> Int = { pb, hostOnly in
        hostOnly ? pb.prepareForNewContents(with: .currentHostOnly) : pb.clearContents()
    }
    var write: (NSPasteboard, [NSPasteboardItem]) -> Bool = { $0.writeObjects($1) }

    func replace(_ items: [NSPasteboardItem], on pasteboard: NSPasteboard,
                 expectedGeneration: Int? = nil, hostOnly: Bool = true) -> Result {
        let before = pasteboard.changeCount
        guard expectedGeneration == nil || expectedGeneration == before else {
            return Result(generation: nil, failure: .changed, recoveryGeneration: nil)
        }
        let cleared = clear(pasteboard, hostOnly)
        // A stale/failed clear never authorizes writing into the previous owner's board.
        guard cleared >= 0, cleared != before else {
            return Result(generation: nil, failure: .clear, recoveryGeneration: nil)
        }
        guard pasteboard.changeCount == cleared else {
            return Result(generation: nil, failure: .changed, recoveryGeneration: nil)
        }
        let written = items.isEmpty || write(pasteboard, items)
        guard pasteboard.changeCount == cleared else {
            return Result(generation: nil, failure: .changed, recoveryGeneration: nil)
        }
        guard written else {
            return Result(generation: nil, failure: .write, recoveryGeneration: cleared)
        }
        PasteboardWriteReceipt.post(pasteboard, generation: cleared)
        return Result(generation: cleared, failure: nil, recoveryGeneration: nil)
    }

    func restore(_ snapshot: PasteboardAccess.Snapshot, on pasteboard: NSPasteboard,
                 expectedGeneration: Int? = nil, hostOnly: Bool = true) -> Result {
        let items = snapshot.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        return replace(items, on: pasteboard, expectedGeneration: expectedGeneration, hostOnly: hostOnly)
    }

    /// At most one recovery attempt, and only while our failed publication still owns
    /// the clipboard. A later user copy always wins over the saved snapshot.
    func recover(_ snapshot: PasteboardAccess.Snapshot, after result: Result,
                 on pasteboard: NSPasteboard, hostOnly: Bool = true) -> Recovery {
        guard let owned = result.recoveryGeneration else { return .unavailable }
        let restoration = restore(snapshot, on: pasteboard, expectedGeneration: owned, hostOnly: hostOnly)
        if restoration.generation != nil { return .restored }
        return restoration.failure == .changed ? .changed : .failed
    }
}
