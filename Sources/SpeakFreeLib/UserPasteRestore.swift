// ai-suggestion:unverified · Claude · 2026-09-24 · feat/fast-clipboard (Cmd+V during the restore window)
import AppKit
import CoreGraphics

// The maintainer, 2026-09-24: "my usual dictate and paste pattern. Still pastes the dictation, so I see
// it twice. There's no way to tell if someone's hitting Command V?"
//
// His habit: copy something, dictate, then press Cmd+V for what he copied. While speakfree still
// holds his clipboard (the window between the target app reading the dictation and the restore),
// that Cmd+V pasted the dictation a second time. Fix: a keyDown event tap, enabled only while a
// clipboard borrow is pending, sees his Cmd+V before any app does and puts his clipboard back
// synchronously inside the tap callback. The keystroke then continues unchanged and pastes his
// own content.
//
// When the tap does NOT restore (each is logged once per borrow as
// `Clipboard restore: trigger=user-paste skipped reason=...`):
//   - before-read: the target app has not read the dictation yet. speakfree's own Cmd+V sits
//     ahead of his in the event stream, so the target's pending read is for the dictation; the
//     lazy promise is the only proof a read happened (AppKit calls the provider on the FIRST read
//     only, then the pasteboard server serves its cached copy). Restoring now would hand the
//     target his clipboard in place of the dictation: the dictation is lost and his content,
//     possibly sensitive, lands where he did not ask for it (the 08-14 reviews' worse-than-a-drop
//     case). In practice he presses Cmd+V after he sees the text, which is after the read.
//   - early-off(...): the read did not count as the target's receipt (a clipboard-syncing VM,
//     KVM or unmeasured remote viewer is running, or the read happened while another app was
//     frontmost). That read may not have been the target's, so the same argument applies.
//   - no-lazy-write: the remote-desktop route writes eagerly and never arms this gate; a Cmd+V
//     into a remote viewer pastes on the remote machine, whose clipboard a local restore would
//     not reach in time anyway.
//   - busy: the gate's lock is held by speakfree's main thread at that instant. The tap never
//     waits for main (it would stall every keystroke system-wide), so it lets this one go.
//   - Secure input (a password field) hides keystrokes from event taps entirely; the normal
//     after-read restore still runs.
//
// Threading: `handleKeyDown` runs on the tap's dedicated thread and never blocks on main; it only
// `tryLock`s. Main-thread callers take the lock for short, bounded sections, and the tap thread
// holds it across its check-and-write so a new dictation's clipboard write can never interleave
// with a restore. The pasteboard write itself is a few ms (16 MB, the save ceiling, measured at
// about 6 ms from a background thread on the dev Mac).

/// Marks every event speakfree synthesizes, so its own Cmd+V is never mistaken for the user's.
enum SyntheticEventMarker {
    /// ASCII "SFPASTE1". Written to `.eventSourceUserData` on every event speakfree posts.
    static let userData: Int64 = 0x5346_5041_5354_4531

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }
}

/// Pure keystroke classification for the paste-watch tap (unit-tested with synthetic events).
enum PasteKeystroke {
    enum Kind: Equatable { case other, ownSynthetic, userPaste }

    /// kVK_ANSI_V. Accepted alongside the layout's own "v" key: "Dvorak - QWERTY Command" style
    /// layouts send Command shortcuts by QWERTY position.
    static let ansiVKeyCode: Int64 = 9

    /// Modifiers that make it a different shortcut (Cmd+Shift+V "paste and match style",
    /// Cmd+Option+V "move", and so on). Caps Lock is a state, not a chord, and is allowed.
    static let disqualifyingFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    static func classify(type: CGEventType, keyCode: Int64, flags: CGEventFlags, userData: Int64,
                         sourcePID: Int64, isAutorepeat: Bool, layoutVKeyCode: Int64?,
                         ownPID: Int64 = Int64(getpid())) -> Kind {
        guard type == .keyDown else { return .other }
        guard keyCode == ansiVKeyCode || (layoutVKeyCode.map { keyCode == $0 } ?? false) else { return .other }
        guard flags.contains(.maskCommand), flags.intersection(disqualifyingFlags).isEmpty else { return .other }
        if userData == SyntheticEventMarker.userData || sourcePID == ownPID { return .ownSynthetic }
        guard !isAutorepeat else { return .other }
        return .userPaste
    }

    static func classify(_ event: CGEvent, type: CGEventType, layoutVKeyCode: Int64?) -> Kind {
        classify(type: type,
                 keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                 flags: event.flags,
                 userData: event.getIntegerValueField(.eventSourceUserData),
                 sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                 isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                 layoutVKeyCode: layoutVKeyCode)
    }
}

/// The one pending clipboard borrow the paste-watch tap may act on. Thread-safe.
final class UserPasteRestoreGate {
    typealias SavedItems = [[(NSPasteboard.PasteboardType, Data)]]

    static let shared = UserPasteRestoreGate()

    enum Outcome: Equatable {
        case notPaste
        case ownSynthetic
        /// Nothing pending (or already handled).
        case idle
        /// The user's clipboard was written back before the keystroke went on.
        case restored(token: Int)
        /// macOS refused the restore; no successful restoration is claimed.
        case restoreFailed(token: Int)
        /// Left alone; `reason` is logged.
        case skipped(token: Int, reason: String)
        /// Something else wrote to the clipboard since speakfree did; their content is left alone.
        case clipboardChanged(token: Int)
    }

    private struct Borrow {
        let token: Int
        let pasteboard: NSPasteboard
        let savedItems: SavedItems
        let writtenChangeCount: Int
        let layoutVKeyCode: Int64?
        var trustedRead = false
        var untrustedReason: String?
        var loggedSkip = false
        let restore: (NSPasteboard, SavedItems) -> Bool
        let onOutcome: (Outcome) -> Void
    }

    private let lock = NSLock()
    private var borrow: Borrow?
    private var nextToken = 1
    /// Tokens the tap restored whose owner has not yet claimed them (normally zero or one).
    private var restoredByTap: Set<Int> = []
    /// Tells the tap owner (HotkeyManager) whether to keep the paste-watch tap enabled.
    /// Always called on main. Set by the live HotkeyManager.
    var onWatchingChanged: ((Bool) -> Void)?

    /// Whether a borrow is pending (the tap should be enabled).
    var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return borrow != nil
    }

    /// TAP THREAD variant of `isWatching` that never waits: when main holds the lock it answers
    /// true (keeping the tap on a little longer is harmless; the next claim turns it off).
    func isWatchingWithoutWaiting() -> Bool {
        guard lock.try() else { return true }
        defer { lock.unlock() }
        return borrow != nil
    }

    /// Main thread. Start watching a new borrow (replacing any older one). `restore` writes the
    /// saved items back; it runs on the TAP thread and must not touch main-only state.
    /// `onOutcome` is delivered on main.
    @discardableResult
    func arm(pasteboard: NSPasteboard, savedItems: SavedItems, writtenChangeCount: Int,
             layoutVKeyCode: Int64?,
             restore: @escaping (NSPasteboard, SavedItems) -> Bool,
             onOutcome: @escaping (Outcome) -> Void) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        let token = nextToken
        nextToken += 1
        borrow = Borrow(token: token, pasteboard: pasteboard, savedItems: savedItems,
                        writtenChangeCount: writtenChangeCount, layoutVKeyCode: layoutVKeyCode,
                        restore: restore, onOutcome: onOutcome)
        lock.unlock()
        onWatchingChanged?(true)
        return token
    }

    /// Main thread. The target app's read receipt arrived: a Cmd+V from now on may restore.
    func markTrustedRead(token: Int) {
        lock.lock(); defer { lock.unlock() }
        guard borrow?.token == token else { return }
        borrow?.trustedRead = true
    }

    /// Main thread. A read arrived that does not prove the target read the dictation.
    func markUntrustedRead(token: Int, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard borrow?.token == token else { return }
        borrow?.untrustedReason = reason
    }

    /// Main thread. Stop watching (a new dictation is about to write, or speakfree's own restore
    /// is about to run). Returns false only when the tap already restored `token`, in which case
    /// the caller must not restore again. Waits at most for one in-flight tap restore (a few ms).
    @discardableResult
    func claim(token: Int?) -> Bool {
        lock.lock()
        let wasWatching = borrow != nil
        var mayRestore = true
        if let token {
            if restoredByTap.remove(token) != nil { mayRestore = false }
            if borrow?.token == token { borrow = nil }
        } else {
            borrow = nil
        }
        let nowWatching = borrow != nil
        lock.unlock()
        if wasWatching != nowWatching { onWatchingChanged?(nowWatching) }
        return mayRestore
    }

    /// Main thread. Run `body` (speakfree reading the clipboard itself) so it never overlaps a
    /// tap-thread restore on the shared NSPasteboard object.
    func excludingTapRestore<T>(_ body: () -> T) -> T {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Any thread. For speakfree's OTHER clipboard writes (copy-last, recovery, fallbacks, the
    /// compatibility and problem reports, Edit Mode copies): the borrow is over once something
    /// else is on the clipboard, and the write must never land between a tap restore's check
    /// and its write. The tap-off signal is always delivered on main.
    func writeOutsideBorrow(_ body: () -> Void) {
        lock.lock()
        let wasWatching = borrow != nil
        borrow = nil
        body()
        lock.unlock()
        guard wasWatching else { return }
        if Thread.isMainThread {
            onWatchingChanged?(false)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isWatching else { return }
                self.onWatchingChanged?(false)
            }
        }
    }

    /// TAP THREAD. Classify a keyDown and, for the user's Cmd+V with a trusted receipt, restore
    /// the saved clipboard synchronously before returning. Never waits for main.
    func handleKeyDown(type: CGEventType, keyCode: Int64, flags: CGEventFlags, userData: Int64,
                       sourcePID: Int64, isAutorepeat: Bool) -> Outcome {
        guard lock.try() else {
            // Main holds the lock for a short section. Classify without the layout key (ANSI V
            // only) just to decide whether this is worth a log line.
            let kind = PasteKeystroke.classify(type: type, keyCode: keyCode, flags: flags,
                                               userData: userData, sourcePID: sourcePID,
                                               isAutorepeat: isAutorepeat, layoutVKeyCode: nil)
            if kind == .userPaste {
                DispatchQueue.main.async {
                    DiagnosticLogger.shared.log("Clipboard restore: trigger=user-paste skipped reason=busy")
                }
            }
            return kind == .ownSynthetic ? .ownSynthetic : .notPaste
        }
        guard var current = borrow else {
            lock.unlock()
            return .idle
        }
        let kind = PasteKeystroke.classify(type: type, keyCode: keyCode, flags: flags,
                                           userData: userData, sourcePID: sourcePID,
                                           isAutorepeat: isAutorepeat,
                                           layoutVKeyCode: current.layoutVKeyCode)
        switch kind {
        case .other:
            lock.unlock()
            return .notPaste
        case .ownSynthetic:
            lock.unlock()
            return .ownSynthetic
        case .userPaste:
            break
        }

        let outcome: Outcome
        if !current.trustedRead {
            let reason = current.untrustedReason.map { "early-off(\($0))" } ?? "before-read"
            outcome = .skipped(token: current.token, reason: reason)
            let firstSkip = !current.loggedSkip
            current.loggedSkip = true
            borrow = current
            lock.unlock()
            if firstSkip { deliver(outcome, to: current.onOutcome) }
            return outcome
        }
        if current.pasteboard.changeCount != current.writtenChangeCount {
            outcome = .clipboardChanged(token: current.token)
            borrow = nil
        } else {
            if current.restore(current.pasteboard, current.savedItems) {
                outcome = .restored(token: current.token)
                restoredByTap.insert(current.token)
            } else {
                outcome = .restoreFailed(token: current.token)
            }
            borrow = nil
        }
        lock.unlock()
        deliver(outcome, to: current.onOutcome)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isWatching else { return }
            self.onWatchingChanged?(false)
        }
        return outcome
    }

    func handleKeyDown(_ event: CGEvent, type: CGEventType) -> Outcome {
        handleKeyDown(type: type,
                      keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                      flags: event.flags,
                      userData: event.getIntegerValueField(.eventSourceUserData),
                      sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                      isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    }

    private func deliver(_ outcome: Outcome, to onOutcome: @escaping (Outcome) -> Void) {
        DispatchQueue.main.async { onOutcome(outcome) }
    }
}
