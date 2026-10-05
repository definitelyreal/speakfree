// ai-suggestion:unverified · Claude · 2026-09-25 · feat/fast-clipboard
//
// The clipboard canary (DESIGN.md approach A). At most once a day, while the screen is locked
// or the Mac has been idle, and never while speakfree is capturing, transcribing or borrowing
// the clipboard: put a harmless item on the clipboard written EXACTLY like a dictation (host-only
// lazy promise, the three nspasteboard.org markers), hold it, and record whether any process
// read it. Nobody can paste while the screen is locked, so a read there is a background reader
// that ignores the markers. Then put the user's clipboard back exactly (every item, every type),
// unless something else wrote to the clipboard in the meantime, which is left alone.
//
// While the canary is out, the paste-watch tap (UserPasteRestore.swift) holds the user's saved
// clipboard: if the user comes back and presses Cmd+V, their own clipboard goes back inside that
// keystroke, so the canary text is never what they paste.
//
// What the user may notice: the restore is a clipboard change, so a clipboard manager records
// the user's CURRENT item again as newest, once a day. A manager that ignores the markers also
// records the canary text itself, which says what it is.

import AppKit
import Foundation

final class ClipboardCanary {
    /// Self-describing and short, in case a manager that ignores the markers records it.
    static let canaryText = "speakfree clipboard check (safe to delete)"

    /// Lock mode: nobody can paste, so a long hold costs nothing, and it outlasts a manager whose
    /// polling timer the system slows down while the screen is locked (App Nap coalescing).
    static let lockHold: TimeInterval = 20
    /// Idle mode: the user can come back at any moment, so keep it short.
    static let idleHold: TimeInterval = 2
    /// At most one attempt per this interval (attempts count even when inconclusive, so a
    /// crash mid-run cannot turn into repeated runs).
    static let minimumInterval: TimeInterval = 24 * 60 * 60
    /// Idle mode: how long the Mac must have had no input.
    static let idleThreshold: TimeInterval = 10 * 60
    /// Idle mode: how often input is checked during the hold, so the user's return (a key,
    /// a click, even pressing Command) ends the run and gives the clipboard back first.
    static let inputPollInterval: TimeInterval = 0.05

    /// System inputs, all injectable so tests never touch the real clipboard or clocks.
    struct Environment {
        var pasteboard: NSPasteboard
        var pasteboardWriter = PasteboardWriter()
        var store: ClipboardTrustStore
        var now: () -> Date = Date.init
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Seconds since the last key, click, scroll or mouse move in this login session.
        var secondsSinceUserInput: () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                    eventType: CGEventType(rawValue: ~0)!)
        }
        /// Bundle IDs of running apps (for the known-reader list stored with each result).
        var runningBundleIDs: () -> [String?] = { NSWorkspace.shared.runningApplications.map(\.bundleIdentifier) }
        /// True while a take is being captured or transcribed, or a clipboard borrow is pending.
        var isBusy: () -> Bool = { false }
        /// Tests shorten the hold; nil uses `lockHold` / `idleHold`.
        var holdOverride: TimeInterval?
        var inputPollInterval: TimeInterval = ClipboardCanary.inputPollInterval
        /// The clipboard must have been unchanged for this long (observed by `noteClipboard`), so
        /// a run never lands between another app's write and its own changeCount-based follow-up
        /// (a password manager's clear timer, speakfree's Secure-Input auto-clear).
        var quietClipboardInterval: TimeInterval = 60
        /// Clipboard writes go through this (production: the paste-watch gate's exclusion).
        var writeGate: (() -> Void) -> Void = { UserPasteRestoreGate.shared.writeOutsideBorrow($0) }
        /// Holds the saved clipboard for the user's own Cmd+V during a run (nil: none).
        var pasteGate: UserPasteRestoreGate? = .shared
        /// The keyboard layout's "v" key code for the gate (ANSI V is always recognized too).
        var layoutVKeyCode: () -> Int64? = { nil }
        /// Whether the login session reports the screen locked right now (lock mode requires it,
        /// so a missed unlock notification can never start a lock run while the user works).
        var isScreenLocked: () -> Bool = {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
            return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
    }

    /// Lock mode: no input for at least this long before a run.
    static let lockQuietInput: TimeInterval = 5

    enum StartResult: Equatable {
        case started
        case skipped(String)
    }

    var env: Environment
    private var run: Run?
    /// Called on main with each finished result (tests; production only logs).
    var onFinish: ((ClipboardCanaryResult) -> Void)?

    private final class Run {
        let mode: ClipboardCanaryResult.Mode
        let provider: DictationPasteProvider
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
        let writtenChangeCount: Int
        let startedAt: TimeInterval
        let hold: TimeInterval
        let readers: [String]
        var readAt: TimeInterval?
        var gateToken: Int?
        var holdWork: DispatchWorkItem?
        var pollTimer: Timer?
        init(mode: ClipboardCanaryResult.Mode, provider: DictationPasteProvider,
             savedItems: [[(NSPasteboard.PasteboardType, Data)]], writtenChangeCount: Int,
             startedAt: TimeInterval, hold: TimeInterval, readers: [String]) {
            self.mode = mode
            self.provider = provider
            self.savedItems = savedItems
            self.writtenChangeCount = writtenChangeCount
            self.startedAt = startedAt
            self.hold = hold
            self.readers = readers
        }
    }

    init(environment: Environment) {
        self.env = environment
    }

    var isRunning: Bool { run != nil }

    /// Last observed clipboard generation and when it was first seen (uptime).
    private var observedChangeCount: Int?
    private var observedSince: TimeInterval = 0
    /// A clipboard generation already found unsuitable (lossy, too large, changed mid-copy):
    /// never copied again, so an idle Mac does not re-copy a big clipboard every minute.
    private var unsuitableChangeCount: Int?

    /// Main thread. Record the clipboard generation (each scheduler tick, on lock, and before
    /// each start). A changeCount read only, never content.
    func noteClipboard() {
        guard run == nil else { return }
        let count = env.pasteboard.changeCount
        if count != observedChangeCount {
            observedChangeCount = count
            observedSince = env.uptime()
        }
    }

    /// Types that mark a clipboard as sensitive or short-lived (nspasteboard.org's, the legacy
    /// Butler/TextExpander one, and 1Password's). A run never touches such a clipboard: its owner
    /// may clear it on a timer keyed to changeCount, which a restore would defeat.
    static let sensitiveTypes: Set<String> = Set(DictationPasteProvider.markerTypes.map(\.rawValue))
        .union(["com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType"])

    /// Main thread. Whether a run is allowed now (once a day, not busy, nothing running, the
    /// clipboard quiet, not marked sensitive, and not already found unsuitable).
    func skipReason(mode: ClipboardCanaryResult.Mode) -> String? {
        if run != nil { return "running" }
        if env.isBusy() { return "busy" }
        if let last = env.store.state.lastAttemptAt,
           env.now().timeIntervalSince(last) < Self.minimumInterval, env.now() >= last {
            return "ran-today"
        }
        if mode == .idle, env.secondsSinceUserInput() < Self.idleThreshold { return "not-idle" }
        if mode == .lock {
            if !env.isScreenLocked() { return "not-locked" }
            if env.secondsSinceUserInput() < Self.lockQuietInput { return "recent-input" }
        }
        noteClipboard()
        if observedChangeCount == nil || env.uptime() - observedSince < env.quietClipboardInterval {
            return "clipboard-recent"
        }
        if env.pasteboard.changeCount == unsuitableChangeCount { return "unsuitable-clipboard" }
        let types = (env.pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        if types.contains(where: Self.sensitiveTypes.contains) { return "marked-clipboard" }
        return nil
    }

    private func skipUnsuitable(_ changeCount: Int, reason: String) -> StartResult {
        unsuitableChangeCount = changeCount
        return .skipped(reason)
    }

    /// Main thread. Start a run if one is allowed.
    @discardableResult
    func startIfDue(mode: ClipboardCanaryResult.Mode) -> StartResult {
        dispatchPrecondition(condition: .onQueue(.main))
        if let reason = skipReason(mode: mode) { return .skipped(reason) }
        let pasteboard = env.pasteboard
        let beforeCopy = pasteboard.changeCount
        let saved: PasteboardAccess.Snapshot
        do {
            saved = try PasteboardAccess.snapshot(pasteboard,
                maximumBytes: TextInserter.maxRestorableClipboardBytes)
        } catch {
            if error as? PasteboardAccess.Failure == .changed {
                DiagnosticLogger.shared.log("Clipboard trust: canary skipped, clipboard changed while being copied")
                return .skipped("changed-during-copy")
            }
            let reason: String
            switch error as? PasteboardAccess.Failure {
            case .tooLarge: reason = "large-clipboard"
            case .denied: reason = "denied-clipboard"
            default: reason = "lossy-clipboard"
            }
            DiagnosticLogger.shared.log("Clipboard trust: canary skipped, snapshot failed reason=\(reason)")
            return skipUnsuitable(beforeCopy, reason: reason)
        }
        guard pasteboard.changeCount == beforeCopy else {
            // Something wrote while the clipboard was being copied: the copy may be stale. The
            // new clipboard is simply recent now; a later tick may try it.
            DiagnosticLogger.shared.log("Clipboard trust: canary skipped, clipboard changed while being copied")
            return .skipped("changed-during-copy")
        }
        // The marked-item check in skipReason predates the snapshot. Check the actual
        // saved generation too, so a new short-lived/password copy never gets borrowed.
        guard !saved.flatMap({ $0.map { $0.0.rawValue } }).contains(where: Self.sensitiveTypes.contains) else {
            return .skipped("marked-clipboard")
        }
        let readers = ClipboardReaderCatalog.running(in: env.runningBundleIDs()).map { $0.bundleID.lowercased() }
        let provider = DictationPasteProvider(text: Self.canaryText)
        var publication: PasteboardWriter.Result?
        env.writeGate {
            let result = TextInserter.writeLazyDictation(provider: provider, to: pasteboard,
                writer: env.pasteboardWriter, expectedGeneration: beforeCopy)
            publication = result
            if result.generation == nil {
                _ = env.pasteboardWriter.recover(saved, after: result, on: pasteboard)
            }
        }
        guard let written = publication?.generation else {
            if publication?.failure == .changed { return .skipped("changed-during-copy") }
            // A failed probe is never evidence that clipboard reads are safe. Do not
            // repeatedly clear this same generation while macOS refuses publication.
            return skipUnsuitable(pasteboard.changeCount, reason: "publication-failed")
        }
        let hold = env.holdOverride ?? (mode == .lock ? Self.lockHold : Self.idleHold)
        let current = Run(mode: mode, provider: provider, savedItems: saved, writtenChangeCount: written,
                          startedAt: env.uptime(), hold: hold, readers: readers)
        provider.onRead = { [weak self, weak current] in
            guard let self, let current, self.run === current, current.readAt == nil else { return }
            current.readAt = self.env.uptime()
        }
        run = current
        // A read served before `onRead` was set (none is expected: AppKit calls the provider on
        // main, and this runs in one main-thread turn) still counts. Errs toward "read".
        if provider.provideCount > 0 { current.readAt = env.uptime() }
        env.store.update { $0.lastAttemptAt = env.now() }

        // The user's own Cmd+V during the run puts their clipboard back first (tap thread).
        if let gate = env.pasteGate {
            let token = gate.arm(
                pasteboard: pasteboard, savedItems: saved, writtenChangeCount: written,
                layoutVKeyCode: env.layoutVKeyCode(),
                restore: { [writer = env.pasteboardWriter] pb, items in
                    writer.restore(items, on: pb, expectedGeneration: written).generation != nil
                },
                onOutcome: { [weak self, weak current] outcome in
                    guard let self, let current else { return }
                    self.handleGateOutcome(outcome, run: current)
                })
            gate.markTrustedRead(token: token)
            current.gateToken = token
        }

        let holdWork = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, self.run === current else { return }
            self.finish(note: nil)
        }
        current.holdWork = holdWork
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: holdWork)
        if mode == .idle {
            let timer = Timer(timeInterval: env.inputPollInterval, repeats: true) { [weak self, weak current] _ in
                guard let self, let current, self.run === current else { return }
                if self.env.secondsSinceUserInput() < self.env.uptime() - current.startedAt {
                    self.finish(note: "user-returned")
                }
            }
            current.pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return .started
    }

    /// Main thread: the paste-watch tap acted on the user's Cmd+V during a run.
    private func handleGateOutcome(_ outcome: UserPasteRestoreGate.Outcome, run current: Run) {
        let token: Int
        let note: String
        switch outcome {
        case .restored(let value): token = value; note = "user-paste"
        case .restoreFailed(let value): token = value; note = "restore-failed"
        default: return
        }
        guard token == current.gateToken else { return }
        guard run === current else {
            env.pasteGate?.claim(token: token)  // clears the tap's "already restored" mark
            return
        }
        finish(note: note)
    }

    /// Main thread. The screen unlocked: the user is back, so end a lock-mode run now. A read
    /// that happened before the unlock still counts; the run is otherwise inconclusive.
    func screenUnlocked() {
        guard let current = run, current.mode == .lock else { return }
        finish(note: "unlocked")
    }

    /// Main thread. End any run now and give the clipboard back (a clipboard borrow or write is
    /// about to happen, a take started (AppDelegate), or speakfree is quitting).
    func abort(reason: String) {
        guard run != nil else { return }
        finish(note: reason)
    }

    /// Pure outcome rule (unit-tested). `endedEarlyNote` is set when the hold did not complete.
    static func outcome(readAt: TimeInterval?, startedAt: TimeInterval, clipboardChanged: Bool,
                        endedEarlyNote: String?) -> (ClipboardCanaryResult.Outcome, String?) {
        // A read before the run was cut short still proves an eager reader: the user could not
        // have pasted (lock mode: before the unlock; idle mode: before any input).
        if readAt != nil { return (.read, endedEarlyNote) }
        if let endedEarlyNote { return (.inconclusive, endedEarlyNote) }
        if clipboardChanged { return (.inconclusive, "clipboard-changed") }
        return (.clean, nil)
    }

    private func finish(note: String?) {
        guard let current = run else { return }
        run = nil
        current.holdWork?.cancel()
        current.pollTimer?.invalidate()
        let pasteboard = env.pasteboard
        // Take the saved clipboard back from the paste-watch tap. false = the tap already wrote
        // it back inside the user's Cmd+V; writing again could clobber a newer copy.
        var tapRestored = false
        if let token = current.gateToken, let gate = env.pasteGate {
            tapRestored = !gate.claim(token: token)
        }
        // Otherwise put the user's clipboard back only if the canary is still what is on it.
        var restored = tapRestored
        if !tapRestored {
            env.writeGate {
                restored = env.pasteboardWriter.restore(current.savedItems, on: pasteboard,
                    expectedGeneration: current.writtenChangeCount).generation != nil
            }
        }
        // In idle mode a read AFTER the user came back may be their own paste: only reads
        // before the last observed input count, and a run the user interrupted is never clean.
        // (The poll usually ends the run within 50 ms of input; this covers the hold ending first.)
        var readAt = current.readAt
        var endNote = tapRestored ? (note ?? "user-paste") : note
        if current.mode == .idle {
            let inputAt = env.uptime() - env.secondsSinceUserInput()
            if inputAt > current.startedAt {
                if let read = readAt, read >= inputAt { readAt = nil }
                endNote = endNote ?? "user-returned"
            }
        }
        let (outcome, outcomeNote) = Self.outcome(readAt: readAt, startedAt: current.startedAt,
                                                  clipboardChanged: !restored, endedEarlyNote: endNote)
        let result = ClipboardCanaryResult(
            date: env.now(), mode: current.mode, outcome: outcome,
            readAfterMs: readAt.map { Int((($0 - current.startedAt) * 1000).rounded()) },
            restored: restored, readers: current.readers, note: outcomeNote,
            holdMs: Int((current.hold * 1000).rounded()))
        env.store.update { $0.append(result) }
        DiagnosticLogger.shared.log(
            "Clipboard trust: canary mode=\(result.mode.rawValue) outcome=\(result.outcome.rawValue) "
            + "readAfter=\(result.readAfterMs.map { "\($0)ms" } ?? "none") restored=\(restored) "
            + "readers=\(current.readers.isEmpty ? "none" : current.readers.joined(separator: ","))"
            + (outcomeNote.map { " note=\($0)" } ?? ""))
        onFinish?(result)
    }
}

/// Starts canary runs on screen lock and after long idle. Main thread.
final class ClipboardCanaryScheduler {
    let canary: ClipboardCanary
    /// Delay after the lock notification (let the lock screen settle).
    var lockDelay: TimeInterval = 5
    /// How often idle is checked and the clipboard generation observed. While the screen stays
    /// locked, each tick also retries a lock-mode run (once a day at most, as always).
    var idleCheckInterval: TimeInterval = 60
    private(set) var screenLocked = false
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private var pendingLockRun: DispatchWorkItem?

    init(canary: ClipboardCanary) {
        self.canary = canary
    }

    func start(center: DistributedNotificationCenter = .default()) {
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.screenDidLock() })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.screenDidUnlock() })
        let timer = Timer(timeInterval: idleCheckInterval, repeats: true) { [weak self] _ in self?.idleTick() }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// True once the post-lock settle delay has passed; ticks never start a lock run before it.
    private var lockSettled = false

    func screenDidLock() {
        screenLocked = true
        lockSettled = false
        canary.noteClipboard()
        pendingLockRun?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.screenLocked else { return }
            self.lockSettled = true
            self.canary.startIfDue(mode: .lock)
        }
        pendingLockRun = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lockDelay, execute: work)
    }

    func screenDidUnlock() {
        screenLocked = false
        lockSettled = false
        pendingLockRun?.cancel()
        pendingLockRun = nil
        canary.screenUnlocked()
    }

    func idleTick() {
        canary.noteClipboard()
        if screenLocked {
            guard lockSettled else { return }
            if canary.startIfDue(mode: .lock) == .skipped("not-locked") {
                // The unlock notification was missed: the session is not locked. Treat the
                // screen as unlocked so the daily check falls back to idle mode.
                screenLocked = false
                lockSettled = false
                canary.startIfDue(mode: .idle)
            }
        } else {
            canary.startIfDue(mode: .idle)
        }
    }
}
