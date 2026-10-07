// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import Foundation
import CoreGraphics

/// A short-lived keyboard-recording lease. Dictation's tap reads the locked snapshot while
/// History observes transitions on main and unregisters its Carbon shortcut. Keeping the lease
/// until the captured key is released prevents a held key's repeat from reopening History.
final class ShortcutRecordingGate {
    static let shared = ShortcutRecordingGate()
    static let changed = Notification.Name("SpeakFreeShortcutRecordingChanged")

    struct Snapshot: Equatable { let isActive: Bool; let generation: UInt64 }
    private let lock = NSLock()
    private var tokens = Set<UUID>()
    private var generation: UInt64 = 0
    let notificationCenter: NotificationCenter
    private let keyIsDown: (UInt16) -> Bool
    private let scheduleReleaseCheck: (@escaping () -> Void) -> Void

    init(notificationCenter: NotificationCenter = .default,
         keyIsDown: @escaping (UInt16) -> Bool = { CGEventSource.keyState(.hidSystemState, key: $0) },
         scheduleReleaseCheck: @escaping (@escaping () -> Void) -> Void = { check in
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: check)
         }) {
        self.notificationCenter = notificationCenter
        self.keyIsDown = keyIsDown
        self.scheduleReleaseCheck = scheduleReleaseCheck
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(isActive: !tokens.isEmpty, generation: generation)
    }

    func permitsDelivery(from snapshot: Snapshot) -> Bool {
        let current = self.snapshot
        return !snapshot.isActive && !current.isActive && current.generation == snapshot.generation
    }

    @discardableResult
    func begin() -> UUID {
        let token = UUID()
        lock.lock()
        let changed = tokens.isEmpty
        tokens.insert(token)
        if changed { generation &+= 1 }
        lock.unlock()
        if changed { notificationCenter.post(name: Self.changed, object: self) }
        return token
    }

    func finish(_ token: UUID, afterKeyRelease key: UInt16? = nil) {
        lock.lock()
        let known = tokens.contains(token)
        lock.unlock()
        guard known else { return }
        if let key, keyIsDown(key) {
            scheduleReleaseCheck { [weak self] in self?.finish(token, afterKeyRelease: key) }
            return
        }
        lock.lock()
        let removed = tokens.remove(token) != nil
        let changed = removed && tokens.isEmpty
        if changed { generation &+= 1 }
        lock.unlock()
        if changed { notificationCenter.post(name: Self.changed, object: self) }
    }
}
