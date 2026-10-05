// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit

/// Clipboard safety shared by dictation and optional consumers. No history dependency.
enum PasteboardAccess {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    enum Failure: Error, Equatable { case denied, unreadable, changed, tooLarge }

    static func isDenied(_ pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysDeny }
        return false
    }

    /// A partial snapshot is never permission to replace the user's clipboard.
    /// A provider may still allocate its data before we can measure it; the byte cap
    /// bounds retained data, not memory used by a third-party provider.
    static func snapshot(_ pasteboard: NSPasteboard, maximumBytes: Int,
                         denied: Bool? = nil,
                         read: (NSPasteboardItem, NSPasteboard.PasteboardType) -> Data? = { $0.data(forType: $1) }) throws -> Snapshot {
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
                guard pasteboard.changeCount == generation else { throw Failure.changed }
                let data = read(item, type)
                // A replacement can invalidate this item's promises. Report the changed
                // generation first so callers can retry, without reading later formats.
                guard pasteboard.changeCount == generation else { throw Failure.changed }
                guard let data else { throw Failure.unreadable }
                guard data.count <= maximumBytes - size else { throw Failure.tooLarge }
                size += data.count
                representations.append((type, data))
            }
            guard !representations.isEmpty else { throw Failure.unreadable }
            result.append(representations)
        }
        guard pasteboard.changeCount == generation else { throw Failure.changed }
        return result
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
                 expectedGeneration: Int? = nil, hostOnly: Bool = false) -> Result {
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
                 expectedGeneration: Int? = nil) -> Result {
        let items = snapshot.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        return replace(items, on: pasteboard, expectedGeneration: expectedGeneration)
    }

    /// At most one recovery attempt, and only while our failed publication still owns
    /// the clipboard. A later user copy always wins over the saved snapshot.
    func recover(_ snapshot: PasteboardAccess.Snapshot, after result: Result,
                 on pasteboard: NSPasteboard) -> Recovery {
        guard let owned = result.recoveryGeneration else { return .unavailable }
        let restoration = restore(snapshot, on: pasteboard, expectedGeneration: owned)
        if restoration.generation != nil { return .restored }
        return restoration.failure == .changed ? .changed : .failed
    }
}
