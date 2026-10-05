// Trace output experiment: ai-suggestion:unverified · session:unknown · 2026-10-04
// ai-suggestion:unverified · session:01a0a336-fe39-7870-bdab-33c820f98955 · 2026-09-16
import AppKit
import Foundation
import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import IOKit

class TextInserter {
    // Cache the 'v' key code — only changes if keyboard layout changes
    private var cachedVKeyCode: CGKeyCode?
    private var cachedInputSourceID: String?

    /// Seam for Secure Input detection. Defaults to the real Carbon API so production
    /// behaviour is unchanged. Tests can inject `{ false }` or `{ true }` to simulate a
    /// password field without needing a real secure-input context.
    var isSecureInputActive: () -> Bool = { IsSecureEventInputEnabled() }

    /// Seam for the AX refocus operation. Defaults to the real AX call so production
    /// behaviour is unchanged. Tests inject `{ _ in true }` to reach the async
    /// focus-settle closure, which is otherwise unreachable headless (a real refocus
    /// never succeeds in a test runner).
    var refocusElement: (AXUIElement) -> Bool = { element in
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Seam for the production text-insertion mechanism — the synthetic CGEvent keystrokes,
    /// AX SelectedText writes, and clipboard paste performed by `pasteText`. Production leaves
    /// this nil so the real `pasteText` runs. Tests inject a no-op (optionally recording the
    /// text) so the suite can NEVER post real keyboard events or paste into whatever window is
    /// frontmost on the developer's machine — the "ghost typing" failure mode where a unit test
    /// types its own fixture text into the foreground app (see SecureInputTests).
    var performInsertion: ((String) -> Void)?

    /// Routing seams let regression tests exercise the production remote/local decision
    /// without querying another app or posting input into the user's foreground window.
    var frontmostBundleIDProvider: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    var performRemoteInsertion: ((String) -> Void)?
    var performLocalInsertion: ((String) -> Void)?
    var setSelectedText: (AXUIElement, String) -> AXError = { element, text in
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }
    var frontmostPIDProvider: () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    /// AX ownership is separate from the foreground app for non-activating panels.
    var elementPIDProvider: (AXUIElement) -> pid_t? = { element in
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }
    var executeAppleScript: (String) -> NSDictionary? = { source in
        guard let script = NSAppleScript(source: source) else {
            return ["NSAppleScriptErrorNumber": -2740]
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error
    }
    var performUnicodeInsertion: ((String) -> Bool)?
    var onRemoteInsertionFailure: ((String, String) -> Void)?

    // MARK: - App compatibility (2026-09-24)

    /// Per-app insertion overrides from config (Settings → Advanced). Set by AppDelegate on
    /// every config load; case-insensitive on bundle ID.
    var insertionOverrides: [String: InsertionMethod] = [:]

    /// Where insertion outcomes go when the user has opted in. Off by default; tests inject a
    /// fresh instance.
    var compatibilityReport: CompatibilityReport = .shared

    /// Bundle URL of the frontmost app, used only to probe its Info.plist and Frameworks
    /// folder. The probe ignores a bundle whose Info.plist names a different bundle ID, so a
    /// test that fakes the bundle ID can never be reclassified by the real frontmost app.
    var frontmostBundleURLProvider: () -> URL? = {
        NSWorkspace.shared.frontmostApplication?.bundleURL
    }

    /// Seam for the local clipboard paste on the routed path, so routing tests can observe a
    /// paste without posting ⌘V or touching a pasteboard. Production leaves it nil.
    var performPaste: ((String) -> Void)?

    /// Everything routing needs to know about the frontmost app.
    struct FrontmostProfile {
        let bundleID: String?
        let bundleURL: URL?
        let classification: AppClassification
        let override: InsertionMethod

        var appClass: AppClass { classification.appClass }

        /// Typing a line break here could reach a terminal as Return.
        var typedLineBreaksUnsafe: Bool {
            AppCompatibility.typedLineBreaksUnsafe(appClass: appClass, bundleID: bundleID,
                                                   hasTerminalPane: classification.hasTerminalPane)
        }

        func route(for text: String) -> InsertionRoute {
            AppCompatibility.route(for: appClass, override: override,
                                   textHasLineBreak: AppCompatibility.hasLineBreak(text),
                                   lineBreaksUnsafe: typedLineBreaksUnsafe)
        }
    }

    func frontmostProfile() -> FrontmostProfile {
        let bundleID = frontmostBundleIDProvider()
        let bundleURL = frontmostBundleURLProvider()
        return FrontmostProfile(
            bundleID: bundleID,
            bundleURL: bundleURL,
            classification: AppCompatibility.classify(bundleID: bundleID, bundleURL: bundleURL),
            override: AppCompatibility.override(for: bundleID, in: insertionOverrides))
    }

    /// The route this text would take into the frontmost app right now.
    func currentRoute(for text: String) -> InsertionRoute {
        frontmostProfile().route(for: text)
    }

    // MARK: Outcome tracking for the compatibility report
    //
    // One routed insertion produces one report row. Lower layers adjust it synchronously
    // (`outcomeAdjustment`: a paste that fell back to typing, a delivery that failed), or take
    // ownership of it (`outcomeDeferred`: the remote paste, which only knows its result 0.4 s
    // later and records it itself with the profile captured when it was sent).
    private var outcomeAdjustment: InsertionOutcome?
    private var outcomeDeferred = false

    /// One call's result and destination survive its asynchronous refocus/remote work.
    /// Completion runs after the insertion stack unwinds, so recovery can safely copy
    /// without seeing this call's deferred-insertion guard still raised.
    enum DestinationConstraint { case current, recorded(pid_t?) }

    private final class InsertionAttempt {
        let fieldOwnerPID: pid_t?
        let expectedForegroundPID: pid_t?
        let field: AXUIElement?
        let handlesRecovery: Bool
        let requiresKnownPID: Bool
        let recoveryText: String?
        var deferred = false
        private(set) var outcome: InsertionOutcome?
        private var completion: ((InsertionOutcome) -> Void)?

        init(foregroundPID: pid_t?, fieldOwnerPID: pid_t?, field: AXUIElement?, handlesRecovery: Bool,
             destination: DestinationConstraint, recoveryText: String?,
             completion: ((InsertionOutcome) -> Void)?) {
            self.fieldOwnerPID = fieldOwnerPID
            self.recoveryText = recoveryText
            switch destination {
            case .current:
                self.expectedForegroundPID = fieldOwnerPID ?? foregroundPID
                self.requiresKnownPID = false
            case .recorded(let pid):
                self.expectedForegroundPID = pid
                self.requiresKnownPID = true
            }
            self.field = field
            self.handlesRecovery = handlesRecovery
            self.completion = completion
        }

        func finish(_ result: InsertionOutcome) {
            guard outcome == nil else { return }
            outcome = result
            if let completion {
                self.completion = nil
                DispatchQueue.main.async { completion(result) }
            }
        }

        func finishIfReady() {
            if !deferred { finish(.pasted) }
        }
    }

    private var activeInsertionAttempt: InsertionAttempt?

    /// Submission is not proof of what an inaccessible app ultimately displayed.
    /// Known failure/copy-only outcomes must never close an Edit draft as inserted.
    static func deliveryWasSubmitted(_ outcome: InsertionOutcome) -> Bool {
        switch outcome {
        case .axVerified, .axUnverifiable, .axDroppedThenPasted, .typed, .pasted, .remoteTyped, .remotePasted:
            return true
        case .axTimeoutCopied, .copiedFocusLost, .deliveryFailed, .secureInput:
            return false
        }
    }

    private func beginOutcomeTracking() {
        outcomeAdjustment = nil
        outcomeDeferred = false
    }

    private func recordOutcome(_ outcome: InsertionOutcome, text: String,
                               profile: FrontmostProfile? = nil) {
        let deferred = outcomeDeferred
        let final = outcomeAdjustment ?? outcome
        beginOutcomeTracking()
        guard !deferred else { return }
        activeInsertionAttempt?.finish(final)
        recordDirect(final, multiLine: AppCompatibility.hasLineBreak(text),
                     profile: profile ?? frontmostProfile())
    }

    /// Record a row now, bypassing per-insertion adjustments (used by late completions).
    private func recordDirect(_ outcome: InsertionOutcome, multiLine: Bool, profile: FrontmostProfile) {
        let report = compatibilityReport
        guard report.wantsEvents else { return }
        let info = profile.bundleURL.flatMap { AppCompatibility.infoDictionary(at: $0) }
        let sameApp = (info?["CFBundleIdentifier"] as? String)
            .map { $0.caseInsensitiveCompare(profile.bundleID ?? "") == .orderedSame } ?? false
        report.record(CompatibilityEvent(
            date: Date(),
            bundleID: profile.bundleID ?? "unknown",
            appName: sameApp ? (info?["CFBundleName"] as? String) : nil,
            appVersion: sameApp ? (info?["CFBundleShortVersionString"] as? String) : nil,
            appClass: profile.classification.appClass,
            reason: profile.classification.reason,
            override: profile.override,
            outcome: outcome,
            multiLine: multiLine))
    }

    /// Seam for the pasteboard all clipboard paths write to (`pasteViaClipboard`,
    /// `copyToClipboard`, `secureInputClipboardFallback`). Production stays on
    /// `.general`; tests inject a named pasteboard so the suite never touches the
    /// developer's real clipboard (test-host-safety rule, PLAN.md P-1).
    var pasteboard: NSPasteboard = .general
    var pasteboardWriter = PasteboardWriter()

    /// Snapshot seam for permission/provider failures without reading the general clipboard.
    var captureClipboardSnapshot: (NSPasteboard, Int) throws -> PasteboardAccess.Snapshot = {
        try PasteboardAccess.snapshot($0, maximumBytes: $1)
    }

    /// Seam for the focused-element AX lookup (`AXUIElementCopyAttributeValue` on the
    /// system-wide element). That call is a synchronous WindowServer IPC that can block
    /// FOREVER in a session without a window server — it hung the CI unit-tests job for
    /// 17 silent minutes (test-host-safety, PLAN.md P-1). Production default = the real
    /// query; tests inject `{ nil }` or a fixture element so no AX IPC ever leaves the
    /// test process.
    var focusedElementProvider: () -> AXUIElement? = { TextInserter.queryFocusedElement() }

    /// Seam for the async refocus closure's direct AX SelectedText write to the refocused element.
    /// Production leaves it nil (real `AXUIElementIsAttributeSettable` + set). Tests inject
    /// `{ _, _ in false }` to force the post-AX fallback branch WITHOUT performing real AX IPC
    /// (which can block a headless runner), so the focus-moved guard (AX-C) is reachable in the suite.
    var directAXInsert: ((AXUIElement, String) -> Bool)?

    // MARK: - Clipboard restore after a dictation paste (2026-08-14)
    //
    // A dictation paste borrows the clipboard: write the text, Cmd+V, then hand the user's
    // clipboard back. The old fixed 0.3s restore was too short for a busy Electron app (Codex
    // mid-agent-run) to read the pasteboard first, dropping ~1-4% of pastes. This uses a per-app
    // backstop timer instead: long (3s) on Electron/remote where consumption can lag, short (0.3s)
    // on native where Cmd+V is synchronous.
    //
    // Design note: an earlier version added a "restore on the user's next Command press" trigger to
    // make the backstop feel instant. Three independent adversarial reviews (2026-08-14) killed it:
    // a Command press (Cmd+Tab, Cmd+C, not just Cmd+V) between the paste and the app's actual read
    // restores the clipboard out from under the still-unconsumed paste, causing the app to paste the
    // user's PRIOR clipboard (possibly sensitive) into the target — worse than a drop. There is no
    // way to know the app has consumed, so early restore is never safe. Backstop only.
    //
    // Fast restore (2026-09-24, feat/fast-clipboard): there now IS a way to know. On the local
    // routes the dictated text goes on the clipboard as a LAZY promise (NSPasteboardItemDataProvider),
    // so AppKit calls us at the moment a process actually reads the text. That first read is the
    // "read receipt": restore `afterRead` seconds later instead of waiting out the backstop.
    // Probed on a development Mac (internal clipboard research): the pasteboard server caches the text
    // after that first read, so later reads (a second read by the target) are served without us
    // and keep working until the restore. The risk the 08-14 reviews named is a DIFFERENT process
    // reading first: then the receipt is not the target's. Mitigations, all measured or explicit:
    //   - the write is `.currentHostOnly`, which stopped the one eager reader measured on the dev
    //     Mac (Universal Clipboard: 9 of 17 plain writes read within 0.6 s, 0 of 13 host-only);
    //   - Transient/Concealed/AutoGenerated markers, which Maccy-style managers check (types only,
    //     no data read) before reading;
    //   - known eager clipboard syncers (VMs, software KVMs) running → no early restore, backstop;
    //   - speakfree's own in-process read of the clipboard never counts as a receipt;
    //   - the remote route never restores early (remote viewers sync the clipboard eagerly).
    // A target that is never going to read still gets the backstop, as before.

    /// What to hand back and the guard that says it is still safe to. `savedItems` is the user's
    /// clipboard from BEFORE the first un-restored dictation paste (never re-snapshotted while a
    /// restore is pending AND the clipboard is still our text, or a rapid second dictation would
    /// save dictation-1's text as the "original"). `writtenChangeCount` tracks the LATEST write.
    struct PendingClipboardRestore {
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
        var writtenChangeCount: Int
        /// The lazy provider for the LATEST write (nil on the remote route, which writes eagerly).
        /// Identity-checked so a stale provider can never schedule this restore.
        var provider: DictationPasteProvider?
        var route: PasteRoute = .native
        /// Uptime when Cmd+V was sent, for the paste-to-restore log line.
        var pastedAt: TimeInterval = 0
        /// Uptime of the first read receipt, if any.
        var firstReadAt: TimeInterval?
        /// Seconds after the first read receipt to restore; nil = backstop only.
        var restoreAfterRead: TimeInterval?
        /// Why early restore is off, for the log ("route", "syncer:<bundle id>").
        var earlyOffReason: String?
        /// Frontmost app when Cmd+V was sent. A read while another app is frontmost may be the
        /// user's own paste over there, so it is not a receipt for the dictation target.
        var targetPID: pid_t?
        /// The backstop already granted its one grace period for a late run.
        var backstopGraceUsed = false
        /// This borrow's token in `userPasteGate` (nil on the remote route, which never arms it).
        var gateToken: Int?
        /// The Accessibility outcome check for this paste, if one runs.
        var pasteCheck: PasteOutcomeCheck?
        /// Its verdict so far, for the log ("pending" while it runs, nil when none runs).
        var pasteVerdict: String?
    }

    /// Which restore policy the frontmost app gets.
    enum PasteRoute: String { case remote, electron, native }

    /// When to hand the user's clipboard back on one route.
    struct ClipboardRestoreTiming: Equatable {
        /// Ceiling when nobody reads the dictated text.
        let backstop: TimeInterval
        /// Delay after the first read receipt; nil means never restore early on this route.
        let afterRead: TimeInterval?
    }

    /// Seams for the restore timing, the monotonic clock, and the running-syncer check, so the
    /// fast-restore tests run in milliseconds without real timers of seconds or a real process
    /// list. Production uses the static policy, system uptime, and NSWorkspace.
    var restoreTiming: (PasteRoute) -> ClipboardRestoreTiming = { TextInserter.restoreTiming(route: $0) }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Why the first read must not be trusted right now (an eager syncer, a clipboard manager
    /// that ignores or may ignore the markers, or a canary that was read), or nil. Production
    /// checks the running apps against `ClipboardReaderCatalog` and the canary verdict
    /// (ClipboardTrust.swift); the canary's result overrides the table.
    var clipboardTrustReason: () -> String? = { ClipboardTrustStore.shared.currentUntrustedReason() }

    /// Accessibility outcome check (PasteOutcomeCheck.swift). nil turns it off (tests that do
    /// not exercise it). All reads run on `pasteCheckQueue`, never on main.
    var pasteFieldReader: PasteFieldReading? = AXPasteFieldReader()
    var pasteCheckDelays: [TimeInterval] = PasteOutcome.defaultDelays
    let pasteCheckQueue = DispatchQueue(label: "speakfree.paste-outcome-check", qos: .userInitiated)

    /// The clipboard canary, ended (clipboard given back) before any clipboard borrow starts.
    var clipboardCanary: ClipboardCanary?

    /// Uptime when the last clipboard borrow ended (restored or handed back). Main only.
    private var lastBorrowEndedAt: TimeInterval?
    /// No Accessibility check for a paste starting within this long after the previous borrow
    /// ended: that earlier paste may still be landing, and with the same text it would look
    /// like this one.
    static let pasteCheckQuietAfterBorrow: TimeInterval = 1.5

    /// Seam for the local synthetic Cmd+V. Production leaves it nil (real CGEvents). Tests inject
    /// a closure that plays the target app (reads the pasteboard now, later, twice, or never)
    /// so the whole write → paste → receipt → restore path runs with no real keystroke.
    var postPasteShortcut: (() -> Void)?

    /// Where the paste-watch tap learns about the pending borrow so the user's own Cmd+V can
    /// restore his clipboard first (UserPasteRestore.swift). Tests inject a private gate.
    var userPasteGate: UserPasteRestoreGate = .shared

    /// Seam for the layout's "v" key code handed to the gate (tests pin it; production asks TIS).
    var layoutVKeyCodeProvider: (() -> CGKeyCode?)?

    private var pendingRestore: PendingClipboardRestore?
    private var pendingBackstop: DispatchWorkItem?
    /// Main-thread count, rather than a flag: overlapping focus-settle callbacks each own
    /// one deferred insertion until every exit path in their closure has completed.
    private var deferredInsertionCount = 0
    var hasDeferredInsertion: Bool { deferredInsertionCount > 0 }

    /// Pure check: should a space be prepended given the text ALREADY captured before
    /// the cursor at record-start?
    ///
    /// This is the zero-latency path: `AppDelegate` captures cursor context off the main
    /// thread at record-start (inside `captureFocusedElement`) and stores it in
    /// `recordingContextText`. By the time `finalizeRecording` runs, the answer is already
    /// available — no AX query, no semaphore, no main-thread stall.
    ///
    /// Returns true when the last non-empty character of `contextBefore` is a non-whitespace,
    /// non-newline character — i.e. the cursor immediately follows printable text.
    ///
    /// Tradeoff: the value reflects the focused element AT RECORD-START, which is also the
    /// element we refocus before inserting. If the user switches focus mid-dictation the
    /// answer may be stale, but we are refocusing the original element anyway — so the
    /// element and the precomputed context agree.
    static func shouldPrependSpace(contextBefore text: String?) -> Bool {
        guard let text = text, !text.isEmpty else { return false }
        let lastChar = text.last!
        if lastChar.isWhitespace || lastChar.isNewline { return false }
        // A boundary that legitimately carries no space (open brackets, quotes, hyphen/slash
        // compounds, @#$ etc.) must NOT get a space prepended — otherwise dictating right after
        // "(" or a hyphen produced "( word" / "word- next". This mirrors `spacingDiagnosis`'s
        // `noSpaceExpectedAfter` so the DECISION and the DIAGNOSIS share one definition of
        // "no space belongs here" (2026-08-18: the two disagreed — every punct-preceded seam in
        // the corpus logs got a space prepended, then diagnosed `ok`, hiding the defect).
        if noSpaceExpectedAfter.contains(lastChar) { return false }
        return true
    }

    /// What actually happened at the seam between the text already in the field and the text
    /// being inserted.
    ///
    /// 2026-07-29, the maintainer: "additional spaces should be tracked so that you are able to see
    /// them." Spacing damage is invisible in the recordings corpus — the `.txt` sidecar holds
    /// only the dictation, while the defect lives in the JOIN, which exists solely in the target
    /// app. Nothing downstream could count these, so a run of spurious leading spaces was only
    /// ever visible to the maintainer. This is the missing observation.
    enum SpacingDiagnosis: String {
        /// Exactly one space, or a deliberate no-space boundary. Nothing to see.
        case ok
        /// The field already ended in whitespace AND a space was prepended → "word  next".
        case extraSpace = "EXTRA-SPACE"
        /// Printable character butted straight against printable text → "wordnext".
        case missingSpace = "MISSING-SPACE"
        /// No cursor context was captured, so the seam is unknowable. Counting these matters:
        /// a high blind rate is itself the finding (75-91% of dictations on 2026-07-29).
        case blind
    }

    /// Characters after which no space belongs, so an immediately-following word is correct
    /// rather than a defect. Open brackets and curly OPEN quotes attach to what follows; a hyphen
    /// or slash is a compound join. Straight `"` and `'` are deliberately EXCLUDED: one character
    /// serves as both open and close, and closers cluster right after sentence-final punctuation
    /// (`."`, `dogs'`) where the next dictation is a new sentence that needs the space — so we
    /// keep the space there rather than join `."Then` / `dogs'bones` (VERIFY 2026-08-18).
    private static let noSpaceExpectedAfter: Set<Character> = [
        "(", "[", "{", "<", "“", "‘", "-", "–", "—", "/", "\\", "@", "#", "$", "*", "_", "~", "`",
    ]

    /// Pure seam verdict. `insertText` is the FINAL string handed to the inserter, i.e. the
    /// prepended space (if any) is already applied — so this reports what the field will really
    /// contain, not what was intended.
    static func spacingDiagnosis(contextBefore: String?, insertText: String) -> SpacingDiagnosis {
        guard let context = contextBefore, !context.isEmpty else { return .blind }
        guard let prev = context.last, let first = insertText.first else { return .blind }

        let prevIsSpace = prev.isWhitespace || prev.isNewline
        let firstIsSpace = first.isWhitespace || first.isNewline

        if prevIsSpace && firstIsSpace { return .extraSpace }
        if !prevIsSpace && !firstIsSpace {
            // A boundary that legitimately carries no space is not a defect.
            if noSpaceExpectedAfter.contains(prev) { return .ok }
            return .missingSpace
        }
        return .ok
    }

    /// Coarse character class for the diagnostic log. Deliberately NOT the character itself:
    /// the diagnostic log carries no message content today and this feature must not change
    /// that. A class is enough to count seams and spot the pattern.
    static func charClass(_ ch: Character?) -> String {
        guard let ch else { return "none" }
        if ch.isNewline { return "newline" }
        if ch.isWhitespace { return "space" }
        if ch.isLetter { return "letter" }
        if ch.isNumber { return "digit" }
        if ch.isPunctuation || ch.isSymbol { return "punct" }
        return "other"
    }

    /// Slice `fullText` at a cursor position expressed as a UTF-16 offset, returning the text
    /// before the cursor. AX's `kAXSelectedTextRangeAttribute` CFRange.location is ALWAYS a
    /// UTF-16 offset, so it must be converted through the utf16 view — indexing a String directly
    /// with it mis-slices any text containing multi-UTF-16-unit characters (emoji, some CJK).
    /// Rounds safely: if the offset lands inside a surrogate pair it walks back to the nearest
    /// Character boundary. Returns "" for offset 0 and nil if the offset is out of range (AX-E).
    static func textBeforeUTF16Offset(_ fullText: String, _ offset: Int) -> String? {
        guard offset > 0 else { return "" }
        let utf16 = fullText.utf16
        guard offset <= utf16.count,
              let rawIndex = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex) else {
            return nil
        }
        var boundary = rawIndex
        while String.Index(boundary, within: fullText) == nil, boundary > utf16.startIndex {
            boundary = utf16.index(before: boundary)
        }
        guard let stringIndex = String.Index(boundary, within: fullText) else { return nil }
        return String(fullText[..<stringIndex])
    }

    /// Check if a space should be prepended before inserting text.
    /// Returns true if the character before the cursor is a non-whitespace character.
    ///
    /// NOTE: This method blocks the calling thread on an AX semaphore (up to 300 ms).
    /// It is kept for legacy/fallback purposes. In the normal insert path,
    /// `shouldPrependSpace(contextBefore:)` is used instead — computed at record-start
    /// off the main thread, so the main thread never waits here.
    ///
    /// Seam: `axWaitWillBlock` is called immediately before `semaphore.wait` so tests can
    /// record WHICH thread reaches the wait. Production leaves it nil.
    var axWaitWillBlock: (() -> Void)?

    /// Set at record-start when the target app is Electron-class (2026-07-26,
    /// fourth phantom-space report): the live AX prepend probe runs whenever the
    /// precomputed decision is unavailable (streaming reuse et al) and carried
    /// none of the capture-side gates — VS Code's terminal-document tail always
    /// reads non-space. Decided at record-start (main, deterministic) rather than
    /// probed at call time (racy, untestable).
    var livePrependProbeSuppressed = false

    func shouldPrependSpace(before element: AXUIElement?) -> Bool {
        if livePrependProbeSuppressed {
            DiagnosticLogger.shared.log("TextInserter: prepend probe skipped (Electron-class target)")
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result = false

        DispatchQueue.global(qos: .userInteractive).async {
            guard let el = element ?? self.currentFocusedElement() else { semaphore.signal(); return }

            var rangeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                  let rangeValue = rangeRef,
                  CFGetTypeID(rangeValue) == AXValueGetTypeID() else { semaphore.signal(); return }

            var range = CFRange()
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)

            guard range.location > 0 else { semaphore.signal(); return }

            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
                  let fullText = valueRef as? String, !fullText.isEmpty else { semaphore.signal(); return }

            // range.location is a UTF-16 offset — convert via the utf16 view (AX-E).
            guard let before = TextInserter.textBeforeUTF16Offset(fullText, range.location),
                  let charBefore = before.last else { semaphore.signal(); return }
            // Same no-space-boundary rule as the precomputed `shouldPrependSpace(contextBefore:)`
            // path, so the live-AX fallback and the off-main precompute agree (2026-08-18).
            result = !charBefore.isWhitespace && !charBefore.isNewline
                && !TextInserter.noSpaceExpectedAfter.contains(charBefore)
            semaphore.signal()
        }

        axWaitWillBlock?()
        let timeout = semaphore.wait(timeout: .now() + 0.3)
        if timeout == .timedOut {
            DiagnosticLogger.shared.log("shouldPrependSpace: AX query timed out")
        }
        return result
    }

    // Paste text, optionally refocusing the element that was active when recording started.
    // Returns false for a known synchronous failure; true can mean work was scheduled.
    // `completion` receives this call's final submission/copy/failure outcome exactly once.
    //
    // Secure Input guard — covers ALL insertion paths (AX, keystroke, clipboard, refocus).
    // When a password field (or any app with Secure Event Input) is active, we must not
    // inject keystrokes or paste. The text is dictated-into-a-password-field — the most
    // sensitive case — so the fallback uses the CONCEALED clipboard path (audit AR-1):
    // org.nspasteboard.ConcealedType/TransientType markers + auto-clear, so clipboard-history
    // tools skip it and the plaintext doesn't linger. The caller is notified via onFocusLost.
    @discardableResult
    func insert(text original: String, refocusing element: AXUIElement? = nil,
                onFocusLost: (() -> Void)? = nil) -> Bool {
        insert(text: original, refocusing: element, onFocusLost: onFocusLost,
               handlesRecovery: false, completion: nil)
    }

    @discardableResult
    func insert(text original: String, refocusing element: AXUIElement? = nil,
                onFocusLost: (() -> Void)? = nil, handlesRecovery: Bool = false,
                destination: DestinationConstraint = .current,
                recoveryText: String? = nil,
                completion: ((InsertionOutcome) -> Void)?) -> Bool {
        let foregroundPID = frontmostPIDProvider()
        let fieldOwnerPID = element.flatMap { elementPIDProvider($0) }
        let attempt = InsertionAttempt(foregroundPID: foregroundPID, fieldOwnerPID: fieldOwnerPID,
                                       field: element, handlesRecovery: handlesRecovery,
                                       destination: destination,
                                       recoveryText: recoveryText.map {
                                           Self.withoutTrace(AppCompatibility.trimmingTrailingLineBreaks($0))
                                       }, completion: completion)
        let previous = activeInsertionAttempt
        activeInsertionAttempt = attempt
        defer { activeInsertionAttempt = previous }
        let accepted = insertIntoTarget(text: original, refocusing: element, onFocusLost: onFocusLost)
        attempt.finishIfReady()
        return accepted && attempt.outcome.map(Self.deliveryWasSubmitted) != false
    }

    private func insertIntoTarget(text original: String, refocusing element: AXUIElement?,
                                  onFocusLost: (() -> Void)?) -> Bool {
        // A dictation never ends in a line break, in any app (the maintainer, 2026-09-24: "drop it
        // everywhere"). A trailing spoken "new line" / "new paragraph" is dropped here, at the
        // one entry point every insertion path shares; line breaks in the middle are kept. In a
        // terminal whose program has no bracketed paste (bash 3.2, many REPLs) that break
        // would also run the line.
        let text = AppCompatibility.trimmingTrailingLineBreaks(original)
        if text != original {
            DiagnosticLogger.shared.log("TextInserter: dropped a trailing line break")
        }
        if text.isEmpty { return true }
        // A late failure from the previous insertion (the delayed remote paste) must not
        // suppress this insertion's report row.
        beginOutcomeTracking()
        if isSecureInputActive() {
            DiagnosticLogger.shared.log("TextInserter: Secure Input is active — concealed clipboard fallback instead of inserting")
            let copied = secureInputClipboardFallback(text)
            recordOutcome(copied ? .secureInput : .deliveryFailed, text: text)
            if copied {
                notifySecureInputFallback(text, reason: .secureInput)
                onFocusLost?()
            }
            return false
        }

        if let element = element {
            let currentElement = currentFocusedElement()
            let sameElement = currentElement.map { CFEqual($0, element) } ?? false

            if !sameElement {
                // The focus query itself may have blocked while the user moved apps
                // or enabled Secure Input. Validate before changing AX focus too.
                guard refocusDestinationIsCurrent(element) else {
                    let secure = isSecureInputActive()
                    let copied = secureInputClipboardFallback(text)
                    recordOutcome(copied ? (secure ? .secureInput : .copiedFocusLost) : .deliveryFailed, text: text)
                    if copied {
                        if secure { notifySecureInputFallback(text, reason: .secureInput) }
                        onFocusLost?()
                    }
                    return false
                }
                let refocused = refocusElement(element)
                if refocused {
                    // Use non-blocking delay for focus to settle, then insert.
                    // Re-check secure input inside the closure: the system could enable it
                    // during the 150ms focus-settle window (e.g. user tabs into a password field).
                    let attempt = activeInsertionAttempt
                    attempt?.deferred = true
                    deferredInsertionCount += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self else { attempt?.finish(.deliveryFailed); return }
                        let previous = self.activeInsertionAttempt
                        self.activeInsertionAttempt = attempt
                        attempt?.deferred = false
                        self.beginOutcomeTracking()
                        defer {
                            self.deferredInsertionCount -= 1
                            attempt?.finishIfReady()
                            self.activeInsertionAttempt = previous
                        }
                        if self.isSecureInputActive() {
                            DiagnosticLogger.shared.log("TextInserter: Secure Input became active during focus-settle — concealed clipboard fallback")
                            let copied = self.secureInputClipboardFallback(text)
                            self.recordOutcome(copied ? .secureInput : .deliveryFailed, text: text)
                            if copied {
                                self.notifySecureInputFallback(text, reason: .secureInput)
                                onFocusLost?()
                            }
                            return
                        }
                        guard self.insertionDestinationIsCurrent() else {
                            let copied = self.secureInputClipboardFallback(text)
                            self.recordOutcome(copied ? .copiedFocusLost : .deliveryFailed, text: text)
                            if copied { onFocusLost?() }
                            return
                        }
                        // App-compat (2026-09-24): only apps routed to the Accessibility chain get
                        // the direct AX write here. Paste-routed apps (Electron, browsers,
                        // terminals) accept an AX write, report success and show nothing, and
                        // this refocus path has no read-back check, so trying AX first silently
                        // dropped their dictation whenever focus had to be restored.
                        let route = self.currentRoute(for: text)
                        // Try direct AX insertion on the refocused element first. This targets
                        // `element` specifically, so it is safe even if focus moved.
                        let axInserted: Bool
                        if route != .accessibilityChain {
                            axInserted = false
                        } else if let directAXInsert = self.directAXInsert {
                            guard self.axDestinationIsCurrent(element) else {
                                self.remoteInsertionFailed(text, message: "The original text field changed.")
                                return
                            }
                            axInserted = directAXInsert(element, text)
                        } else {
                            var settable: DarwinBoolean = false
                            let isSettable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
                                && settable.boolValue
                            if isSettable {
                                // L4: no per-element 2s messaging timeout (it stalled main up to 2s).
                                // Keep the process-wide 0.5s cap and react three-way to the result: a
                                // `.cannotComplete` under that cap may have COMMITTED, so conceal-copy
                                // + notify rather than fall through and duplicate via paste/keystrokes.
                                guard let setResult = self.writeSelectedText(text, to: element) else {
                                    self.remoteInsertionFailed(text, message: "The original text field changed.")
                                    return
                                }
                                switch Self.axSetOutcome(setResult) {
                                case .inserted:
                                    axInserted = true
                                case .concealClipboard:
                                    DiagnosticLogger.shared.log("TextInserter: refocus AX set timed out (may have committed) — concealed clipboard fallback instead of blind paste")
                                    let copied = self.secureInputClipboardFallback(text)
                                    self.recordOutcome(copied ? .axTimeoutCopied : .deliveryFailed, text: text)
                                    if copied { onFocusLost?() }
                                    return
                                case .fallbackToKeystrokes, .retryViaPaste, .destinationChanged:
                                    // `axSetOutcome` never yields `.retryViaPaste` (that comes only
                                    // from the read-back verifier in `insertViaAccessibility`), but
                                    // the switch must stay exhaustive; both mean "not inserted",
                                    // which falls through to the focus-checked clipboard paste below.
                                    axInserted = false
                                }
                            } else {
                                axInserted = false
                            }
                        }
                        if axInserted {
                            self.recordOutcome(.axUnverifiable, text: text)
                            return
                        }

                        // AX insertion into the intended element failed. Before blind-pasting Cmd+V
                        // into whatever is frontmost, re-verify focus is STILL the element we
                        // refocused: focus can move during the 150ms settle (TOCTOU), and a paste
                        // would then land in the wrong app. If it moved, conceal-copy the text and
                        // notify instead of pasting (AX-C).
                        //
                        // Unknown focus is not permission to paste into a different control.
                        if !self.insertionDestinationIsCurrent() {
                            DiagnosticLogger.shared.log("TextInserter: target focus could not be confirmed — concealed clipboard fallback instead of blind paste")
                            let copied = self.secureInputClipboardFallback(text)
                            self.recordOutcome(copied ? .copiedFocusLost : .deliveryFailed, text: text)
                            if copied { onFocusLost?() }
                            return
                        }
                        // Fall back to clipboard paste (through the test seam so a unit test
                        // reaching this closure can never fire a real Cmd+V — PLAN.md P-1).
                        if let performInsertion = self.performInsertion {
                            performInsertion(text)
                        } else if route != .accessibilityChain {
                            // Remote viewers, terminals, paste apps and per-app overrides keep
                            // their own route after refocusing. For remote viewers a blind
                            // clipboard paste requires clipboard sharing and must not replace
                            // the single-line keystroke route.
                            self.pasteText(text)
                        } else if let performLocalInsertion = self.performLocalInsertion {
                            performLocalInsertion(text)
                        } else {
                            // The AX write on the refocused element already failed; paste.
                            self.localPaste(text)
                            self.recordOutcome(.pasted, text: text, profile: self.frontmostProfile())
                        }
                    }
                    return true
                } else {
                    let copied = copyToClipboard(text)
                    recordOutcome(copied ? .copiedFocusLost : .deliveryFailed, text: text)
                    if copied { onFocusLost?() }
                    return false
                }
            } else {
                // A mismatched foreground/field owner may be a non-activating panel OR stale
                // AX focus after an app switch. Without a record-start pairing, do not infer
                // an exception from insertion-time focus; the final destination guard retains.
                (performInsertion ?? pasteText)(text)
                return true
            }
        } else {
            (performInsertion ?? pasteText)(text)
            return true
        }
    }

    private func currentFocusedElement() -> AXUIElement? {
        focusedElementProvider()
    }

    private func insertionDestinationIsCurrent(attempt: InsertionAttempt? = nil) -> Bool {
        guard !isSecureInputActive() else { return false }
        guard let attempt = attempt ?? activeInsertionAttempt else { return true }
        if attempt.requiresKnownPID && attempt.expectedForegroundPID == nil { return false }
        if let pid = attempt.expectedForegroundPID, frontmostPIDProvider() != pid { return false }
        if let field = attempt.field {
            guard attempt.expectedForegroundPID != nil,
                  let owner = attempt.fieldOwnerPID,
                  owner == attempt.expectedForegroundPID,
                  let current = currentFocusedElement(), CFEqual(current, field),
                  elementPIDProvider(current) == owner else { return false }
        }
        return true
    }

    private func notifySecureInputFallback(_ text: String, reason: ConcealedFallbackReason) {
        // Edit handles this call's recovery in its own draft. Leave AppDelegate's
        // normal-dictation callback installed for its next call, without auto-retrying Edit.
        guard activeInsertionAttempt?.handlesRecovery != true else { return }
        onSecureInputFallback?(readableRecoveryText(text), reason)
    }

    private static func queryFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
        guard result == .success, let element = elementRef else { return nil }
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }

    private func pasteText(_ text: String) {
        guard insertionDestinationIsCurrent() else {
            remoteInsertionFailed(text, message: "The original destination is no longer confirmed. Your text is available below.")
            return
        }
        // Note: Secure Input is checked at insert() — the entry point for all paths — so it
        // is guaranteed inactive by the time pasteText() is reached.
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let profile = frontmostProfile()
        beginOutcomeTracking()
        // `insert` already dropped any trailing line break (every app, 2026-09-25).
        let route = profile.route(for: text)
        DiagnosticLogger.shared.log(
            "TextInserter: inserting \(text.count) chars into \(frontApp) "
            + "(\(profile.bundleID ?? "?"): \(profile.classification.appClass.rawValue), "
            + "\(profile.classification.reason); override=\(profile.override.rawValue); route=\(route.rawValue))")

        switch route {
        case .remoteKeystroke:
            // Remote desktop: type via AppleScript keystroke (clipboard sync unreliable).
            // typeViaAppleScript itself pastes multi-line text.
            DiagnosticLogger.shared.log("TextInserter: using AppleScript keystroke (remote desktop)")
            (performRemoteInsertion ?? typeViaAppleScript)(text)
            recordOutcome(AppCompatibility.hasLineBreak(text) ? .remotePasted : .remoteTyped,
                          text: text, profile: profile)
            return
        case .remotePaste:
            DiagnosticLogger.shared.log("TextInserter: using remote clipboard paste (per-app setting)")
            (performRemoteInsertion ?? pasteViaClipboard)(text)
            recordOutcome(.remotePasted, text: text, profile: profile)
            return
        case .paste, .keystrokes, .accessibilityChain:
            break
        }

        if let performLocalInsertion = performLocalInsertion {
            performLocalInsertion(text)
            return
        }

        switch route {
        case .paste:
            // Electron / contenteditable apps, browsers, terminals: clipboard paste. In a
            // terminal this also carries line breaks inside bracketed paste instead of typing
            // them as Return.
            DiagnosticLogger.shared.log("TextInserter: using clipboard paste (\(profile.appClass.rawValue))")
            localPaste(text)
            recordOutcome(.pasted, text: text, profile: profile)
            return
        case .keystrokes:
            // The route table only yields keystrokes for multi-line text when the user chose
            // Type for an app whose typed line breaks are safe.
            if typeViaKeyEvents(text, allowLineBreaks: true) {
                DiagnosticLogger.shared.log("TextInserter: used CGEvent unicode typing (per-app setting)")
                recordOutcome(.typed, text: text, profile: profile)
            } else {
                DiagnosticLogger.shared.log("TextInserter: typing unavailable — clipboard paste")
                localPaste(text)
                recordOutcome(.pasted, text: text, profile: profile)
            }
            return
        case .accessibilityChain, .remoteKeystroke, .remotePaste:
            break
        }

        // Try direct AX text insertion first — no clipboard involvement
        switch insertViaAccessibility(text) {
        case .destinationChanged:
            remoteInsertionFailed(text, message: "The original text field or Secure Input changed.")
            return
        case .inserted:
            DiagnosticLogger.shared.log("TextInserter: used AX insertion")
            recordOutcome(lastAXVerification == .landed ? .axVerified : .axUnverifiable,
                          text: text, profile: profile)
            return
        case .concealClipboard:
            // L4: the AX set timed out under the 0.5s cap — it may have COMMITTED. Retyping via
            // keystrokes (or blind-pasting) would duplicate it, so conceal-copy the text and fire
            // the auto-clear notify instead, mirroring the Secure-Input fallback.
            DiagnosticLogger.shared.log("TextInserter: AX insertion timed out (may have committed) — concealed clipboard fallback instead of retyping")
            let copied = secureInputClipboardFallback(text)
            recordOutcome(copied ? .axTimeoutCopied : .deliveryFailed, text: text, profile: profile)
            if copied { notifySecureInputFallback(text, reason: .axTimeoutMayHaveCommitted) }
            return
        case .retryViaPaste:
            // The AX set reported success but the field verifiably did NOT grow — provable
            // non-insertion (distinct from the timeout above). A real Cmd+V paste inserts the
            // text inline. Concealing without pasting was the Chrome silent-drop bug.
            DiagnosticLogger.shared.log("TextInserter: AX insertion dropped silently (field did not grow) — clipboard paste")
            localPaste(text)
            recordOutcome(.axDroppedThenPasted, text: text, profile: profile)
            return
        case .fallbackToKeystrokes:
            break
        }

        // Try typing via CGEvent unicode — works in most apps. An automatic fallback never
        // types a line break: an app classified native can still be an unknown terminal,
        // where Shift+Return is Return. Multi-line text pastes instead.
        if typeViaKeyEvents(text, allowLineBreaks: false) {
            DiagnosticLogger.shared.log("TextInserter: used CGEvent unicode typing")
            recordOutcome(.typed, text: text, profile: profile)
            return
        }

        // Last resort: clipboard-based paste
        DiagnosticLogger.shared.log("TextInserter: using clipboard paste (fallback)")
        localPaste(text)
        recordOutcome(.pasted, text: text, profile: profile)
    }

    /// Local clipboard paste on the routed path, through the test seam.
    private func localPaste(_ text: String) {
        (performPaste ?? pasteViaClipboard)(text)
    }

    /// The read-back verdict of the most recent successful AX write (for the compatibility
    /// report only). nil when the last AX write did not reach verification.
    private var lastAXVerification: AXVerification?

    /// Type text into the frontmost app via AppleScript keystroke.
    /// Used for remote desktop apps where clipboard sync is unreliable.
    private func typeViaAppleScript(_ text: String) {
        // Multi-line text is slow and lossy as per-line keystrokes on remote desktop.
        // Clipboard insertion requires the remote viewer's clipboard sharing feature.
        if AppCompatibility.hasLineBreak(text) {
            pasteViaClipboard(text)
            return
        }

        guard let pid = frontmostPIDProvider() else {
            remoteInsertionFailed(text, message: "The remote desktop is no longer available.")
            return
        }
        // Escape double quotes and backslashes for AppleScript
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "System Events"
                tell (first process whose unix id is \(pid))
                    keystroke "\(escaped)"
                end tell
            end tell
        """
        guard insertionDestinationIsCurrent(), frontmostPIDProvider() == pid else {
            remoteInsertionFailed(text, message: "The remote destination or Secure Input changed. Your text is available below.")
            return
        }
        if let error = executeAppleScript(source) {
            Self.logAppleEventsDenialHint(error)
            // An error does not prove that no prefix was inserted. Retrying by paste
            // can duplicate it, and an Automation denial blocks both AppleScript tiers.
            DiagnosticLogger.shared.log("TextInserter: remote keystroke failed; offering recovery without retry")
            remoteInsertionFailed(text, message: Self.remoteScriptFailureMessage(error))
        }
    }

    private static func remoteScriptFailureMessage(_ error: NSDictionary) -> String {
        if (error["NSAppleScriptErrorNumber"] as? Int) == -1743 {
            return "Allow SpeakFree to control System Events in System Settings → Privacy & Security → Automation, then try again."
        }
        return "macOS could not confirm delivery to the remote desktop."
    }

    /// Retain text visibly without clobbering the clipboard or automatically retrying.
    /// Copying is an explicit user choice, especially important for large clipboard items.
    private func remoteInsertionFailed(_ tracedText: String, message: String,
                                       title: String = "Check your remote dictation",
                                       lateFor profile: FrontmostProfile? = nil,
                                       attempt: InsertionAttempt? = nil) {
        // The dialog shows and copies the dictation for pasting anywhere: no trace.
        let text = readableRecoveryText(tracedText, attempt: attempt)
        if let profile {
            recordDirect(.deliveryFailed, multiLine: AppCompatibility.hasLineBreak(text), profile: profile)
        } else {
            outcomeAdjustment = .deliveryFailed
        }
        let attempt = attempt ?? activeInsertionAttempt
        attempt?.finish(.deliveryFailed)
        guard attempt?.handlesRecovery != true else { return }
        if let onRemoteInsertionFailure = onRemoteInsertionFailure {
            onRemoteInsertionFailure(text, message)
            return
        }
        presentManualRecovery(text: text, message: message, title: title)
    }

    /// A revoked presentation returns false so its owner can retain the text for later.
    func presentManualRecovery(text: String, message: String,
                               title: String = "Check your dictation",
                               shouldPresent: @escaping () -> Bool = { true },
                               completion: @escaping (Bool) -> Void = { _ in }) {
        // A modal started from a main-dispatch block starves other main-queue
        // work, including clipboard restoration. Enter through the run loop.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, shouldPresent() else { completion(false); return }
            let text = Self.withoutTrace(text)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message + "\n\nYour dictation is below. Check the destination before pasting to avoid duplicates."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Copy Dictation")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
            scroll.hasVerticalScroller = true
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.string = text
            view.font = .systemFont(ofSize: NSFont.systemFontSize)
            view.textContainerInset = NSSize(width: 8, height: 8)
            scroll.documentView = view
            alert.accessoryView = scroll
            let instructions = alert.informativeText
            let handled = Self.runManualRecovery(shouldPresent: shouldPresent, present: { copyFailed in
                alert.informativeText = copyFailed
                    ? "The clipboard could not accept your text. It is still below; try Copy again or close.\n\n" + instructions
                    : instructions
                return alert.runModal() == .alertSecondButtonReturn
            }, copy: { self.copyForManualRecovery(text) })
            completion(handled)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Pure interaction seam: failed publication keeps the selectable text available,
    /// and an owner that expired before presentation never opens a stale recovery dialog.
    @discardableResult static func runManualRecovery(shouldPresent: () -> Bool,
                                                     present: (_ copyFailed: Bool) -> Bool,
                                                     copy: () -> Bool) -> Bool {
        var copyFailed = false
        while shouldPresent() {
            guard present(copyFailed) else { return true }
            guard shouldPresent() else { return false }
            if copy() { return true }
            copyFailed = true
        }
        return false
    }

    /// -1743 = the app has no Automation (Apple Events → System Events) grant. Both remote-
    /// desktop insertion tiers depend on it, so surface the ACTIONABLE cause: without an
    /// NSAppleEventsUsageDescription in Info.plist macOS auto-denies and never prompts
    /// (2026-07-03: Splashtop insertion silently dead on builds whose plist lacked the key).
    static func logAppleEventsDenialHint(_ error: NSDictionary) {
        guard (error["NSAppleScriptErrorNumber"] as? Int) == -1743 else { return }
        DiagnosticLogger.shared.log(
            "TextInserter: Apple Events DENIED (-1743) — remote-desktop insertion cannot work. "
            + "Fix: System Settings → Privacy & Security → Automation → enable System Events for this app. "
            + "If the app never appears there, its Info.plist is missing NSAppleEventsUsageDescription (rebuild).")
    }

    /// L4: how to react to the AXError from a SelectedText SetAttributeValue. Three-way because
    /// the round-2 per-element `AXUIElementSetMessagingTimeout(element, 2.0)` was REMOVED — it
    /// stalled the main thread up to 2s on a slow target. Under the process-wide 0.5s messaging
    /// cap a slow-but-committing set reports `.cannotComplete`; blindly retyping via keystrokes
    /// (or blind-pasting) would then DUPLICATE the text the set may already have written. So:
    ///   - `.success`                       → `.inserted` (done)
    ///   - `.cannotComplete` (0.5s-cap timeout, may have committed) → `.concealClipboard`
    ///     (never re-type — conceal-copy + notify, exactly like the Secure-Input fallback)
    ///   - any other error (a clean rejection — attribute unsupported, invalid element, …)
    ///     → `.fallbackToKeystrokes` (nothing was written; safe to retype)
    /// Pure so the AXError→decision mapping is unit-testable without a real AX round-trip.
    ///
    /// `.retryViaPaste` is a FOURTH outcome that `axSetOutcome` itself never returns — it is
    /// produced only by `insertViaAccessibility` after the read-back verification proves the set
    /// silently dropped (the field verifiably did NOT grow). It is deliberately DISTINCT from
    /// `.concealClipboard`: conceal means "the write MAY have committed, so do not paste (would
    /// duplicate)"; retry-via-paste means "the write provably did NOT commit, so paste it inline".
    /// Collapsing the two is exactly the Chrome silent-drop bug (2026-08-12): a web contenteditable
    /// accepts the AX set, reports success, applies nothing, and the old code concealed to the
    /// clipboard WITHOUT pasting — so the text never appeared on the page.
    enum AXSetOutcome: Equatable { case inserted, fallbackToKeystrokes, concealClipboard, retryViaPaste, destinationChanged }

    static func axSetOutcome(_ error: AXError) -> AXSetOutcome {
        switch error {
        case .success: return .inserted
        case .cannotComplete: return .concealClipboard
        default: return .fallbackToKeystrokes
        }
    }

    /// Did an AX set that REPORTED success actually put the text on screen?
    enum AXVerification: Equatable {
        /// The field grew — the text landed.
        case landed
        /// The field is readable, held no selection, and did not change. Nothing landed.
        case didNotLand
        /// Not answerable: unreadable field, or a selection whose replacement makes the
        /// character-count delta ambiguous. Must be treated as success (never retried).
        case inconclusive
    }

    /// Pure verification verdict, split out from the AX calls so the decision table is testable
    /// without a live text field.
    ///
    /// The conservative bias is deliberate: a false `didNotLand` costs the user a spurious
    /// "may not have landed" notice, while a false `landed` costs them silent data loss — but a
    /// verdict used to RETYPE would risk double insertion, which is why callers route this to the
    /// conceal-clipboard path instead of a retype.
    static func verifyInsertion(charsBefore: Int?,
                                charsAfter: Int?,
                                selectionLengthBefore: Int?,
                                insertedCount: Int) -> AXVerification {
        // Nothing was asked for, so nothing can be missing.
        guard insertedCount > 0 else { return .inconclusive }
        // Blind field (no AXNumberOfCharacters) — this is the honest "can't see" case.
        guard let before = charsBefore, let after = charsAfter else { return .inconclusive }
        // A replaced selection can leave the count unchanged (select 5, insert 5) even though
        // the insertion worked. Only a zero-length selection makes the delta meaningful.
        guard let selectionLength = selectionLengthBefore, selectionLength == 0 else {
            return .inconclusive
        }
        return after == before ? .didNotLand : .landed
    }

    /// Pure map from a read-back verdict to what `insertViaAccessibility` should return. Split out
    /// so the load-bearing decision — "a field that verifiably did NOT grow must PASTE, not conceal"
    /// — is unit-testable without a live text field.
    ///
    ///   - `.landed`       → `.inserted` (the text is on screen; done)
    ///   - `.inconclusive` → `.inserted` (blind/ambiguous field; treat as success, never retry —
    ///                        retrying a field we can't read risks a duplicate)
    ///   - `.didNotLand`   → `.retryViaPaste` (POSITIVE proof of non-insertion; a real clipboard
    ///                        paste puts the text inline). This is NOT `.concealClipboard`: conceal
    ///                        is only for the genuine 0.5s-cap timeout, where the write MAY have
    ///                        committed and a paste would duplicate. Here it provably did not.
    static func outcomeForVerification(_ verdict: AXVerification) -> AXSetOutcome {
        switch verdict {
        case .landed, .inconclusive: return .inserted
        case .didNotLand: return .retryViaPaste
        }
    }

    /// `(characterCount, selectionLength)` for an element, either component nil when unreadable.
    private func textMetrics(of element: AXUIElement) -> (chars: Int?, selectionLength: Int?) {
        var charsRef: CFTypeRef?
        let chars = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString,
                                                  &charsRef) == .success ? charsRef as? Int : nil

        var selectionLength: Int?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                         &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            // swiftlint:disable:next force_cast
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
            selectionLength = range.length
        }
        return (chars, selectionLength)
    }

    /// How long to wait before re-reading a field that looked unchanged. Only the SUSPICIOUS
    /// path pays this — a normal insertion is confirmed on the first read and adds no latency.
    /// Contenteditables commit through a JS event loop, so an immediate read can legitimately
    /// still show the old count. Seam so tests don't sleep.
    var axVerifySettleDelay: TimeInterval = 0.05

    private func axDestinationIsCurrent(_ element: AXUIElement) -> Bool {
        // Compare identities directly: two successive focus reads can observe A
        // then B, which must never authorize writing B for captured field A.
        if let captured = activeInsertionAttempt?.field, !CFEqual(captured, element) { return false }
        guard insertionDestinationIsCurrent(),
              let expectedPID = activeInsertionAttempt?.expectedForegroundPID ?? frontmostPIDProvider(),
              elementPIDProvider(element) == expectedPID,
              let current = currentFocusedElement(), CFEqual(current, element) else { return false }
        // AX queries may have waited for another process. Recheck after them.
        return frontmostPIDProvider() == expectedPID && !isSecureInputActive()
    }

    private func refocusDestinationIsCurrent(_ element: AXUIElement) -> Bool {
        guard let attempt = activeInsertionAttempt,
              let expectedPID = attempt.expectedForegroundPID,
              attempt.fieldOwnerPID == expectedPID,
              elementPIDProvider(element) == expectedPID else { return false }
        return frontmostPIDProvider() == expectedPID && !isSecureInputActive()
    }

    /// All native AX writes use the same final target check, including refocus.
    func writeSelectedText(_ text: String, to element: AXUIElement) -> AXError? {
        guard axDestinationIsCurrent(element) else { return nil }
        return setSelectedText(element, text)
    }

    /// Insert text directly via the Accessibility API. Returns the three-way `AXSetOutcome` so the
    /// caller can distinguish a clean rejection (safe to retype) from a timeout that may have
    /// committed (must NOT retype — conceal instead). See `axSetOutcome`.
    private func insertViaAccessibility(_ text: String) -> AXSetOutcome {
        lastAXVerification = nil
        guard let element = currentFocusedElement() else { return .fallbackToKeystrokes }

        // Check if the element supports setting the SelectedText attribute.
        //
        // 2026-07-28: this gate is NOT evidence the write will work. Claude for Desktop, Signal
        // and VS Code all report `settable == true`, yet all three drop AX writes on the floor —
        // which is why a reported success is now verified below rather than trusted.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return .fallbackToKeystrokes
        }

        let before = textMetrics(of: element)

        // Set the selected text — this replaces current selection or inserts at cursor. No
        // per-element messaging timeout (L4): keep the process-wide 0.5s cap so a stuck target
        // can't hang the main thread; a `.cannotComplete` under that cap routes to conceal, not
        // a duplicating retype.
        guard let result = writeSelectedText(text, to: element) else { return .destinationChanged }
        let outcome = Self.axSetOutcome(result)
        guard outcome == .inserted else { return outcome }

        // The set claimed success. Confirm the field actually grew.
        var verdict = Self.verifyInsertion(charsBefore: before.chars,
                                           charsAfter: textMetrics(of: element).chars,
                                           selectionLengthBefore: before.selectionLength,
                                           insertedCount: text.count)
        if verdict == .didNotLand {
            // Re-read once after a settle beat before accusing the app — a contenteditable that
            // commits asynchronously would otherwise trigger a false alarm on every insertion.
            Thread.sleep(forTimeInterval: axVerifySettleDelay)
            verdict = Self.verifyInsertion(charsBefore: before.chars,
                                           charsAfter: textMetrics(of: element).chars,
                                           selectionLengthBefore: before.selectionLength,
                                           insertedCount: text.count)
        }

        lastAXVerification = verdict
        let verifiedOutcome = Self.outcomeForVerification(verdict)
        if verifiedOutcome == .retryViaPaste {
            // Confirmed silent drop: the set reported success but the field verifiably did not
            // grow, so we KNOW nothing committed (this is NOT the 0.5s-cap timeout that "may have
            // committed" — that path is `.concealClipboard` from `axSetOutcome`, untouched). A real
            // clipboard paste puts the text inline. The old code concealed WITHOUT pasting here, so
            // dictation into Chrome/Safari web fields landed only on the clipboard and never on the
            // page (2026-08-12 Chrome silent-drop bug).
            DiagnosticLogger.shared.log(
                "TextInserter: AX set reported success but field did not grow (\(before.chars.map(String.init) ?? "?") chars, "
                + "inserting \(text.count)) — provable non-insertion, pasting via clipboard")
        }
        return verifiedOutcome
    }

    /// Is the frontmost app a remote desktop / VNC viewer / VM console, as routing sees it?
    /// Uses the full classification (known IDs, keywords, and vnc/rdp-style URL schemes the
    /// app registers). A per-app override changes the route, never this answer, so the remote
    /// safety rules (no Unicode key events, System Events paste) hold under every setting.
    func isRemoteDesktopFrontmost() -> Bool {
        frontmostProfile().appClass == .remoteDesktop
    }

    /// Bundle-ID-only remote check (known IDs and keywords; no filesystem). The lists live in
    /// `AppCompatibility`.
    static func isRemoteDesktop(bundleID: String?) -> Bool {
        AppCompatibility.isRemoteDesktop(bundleID: bundleID)
    }

    /// Large image clipboards are common while dictating into creative/chat apps. A
    /// 512 KB ceiling forced a 4.6 MB clipboard in Codex back to synthetic Unicode
    /// events, the exact path that intermittently dropped the user's insertion. Keep a
    /// finite cap, but allow ordinary images to be saved and restored around Cmd+V.
    static let maxRestorableClipboardBytes = 16 * 1_024 * 1_024

    /// Normal apps consume a synthetic Cmd+V synchronously with the key event. Keep a short
    /// settle beat for Electron/contenteditable event loops, then return the user's prior
    /// clipboard before a follow-up manual paste. The former 1.5 s delay made Cmd+V half a
    /// second after dictation paste the dictated text a second time.
    static let localClipboardRestoreDelay: TimeInterval = 0.3

    /// Remote desktop paste is intentionally slower: `simulatePaste` waits 400 ms before
    /// sending Cmd+V and the remote client still needs time to synchronize the clipboard.
    static let remoteClipboardRestoreDelay: TimeInterval = 3.0

    /// Electron/contenteditable backstop. Long because a busy Electron app (Codex mid-agent-run)
    /// can take far longer than 0.3s to read the pasteboard, and the backstop must not restore
    /// before the app has consumed our paste. Matches the remote path's value for the same race.
    /// (Clipboard SIZE is NOT used to shorten this: the residency exposes only the small dictation
    /// text, peak memory is bounded by `maxRestorableClipboardBytes`, and shortening it for large
    /// clipboards reintroduced the drop for the documented 4.6MB-image-in-Codex case.)
    static let electronClipboardRestoreDelay: TimeInterval = 3.0

    /// Pure backstop-delay policy (unit-tested): the ceiling on how long the dictation text lingers
    /// on the clipboard before the user's own content is returned.
    static func restoreBackstopDelay(route: PasteRoute) -> TimeInterval {
        switch route {
        case .remote: return remoteClipboardRestoreDelay
        case .native: return localClipboardRestoreDelay
        case .electron: return electronClipboardRestoreDelay
        }
    }

    /// Native Cocoa apps read the pasteboard synchronously while handling Cmd+V; the margin only
    /// covers a second read in the same paste.
    static let nativeRestoreAfterRead: TimeInterval = 0.15

    /// Electron/Chromium, browsers and terminals read the text once per paste (types first, which
    /// does not call the provider). A second read in the same paste (a page's paste handler, then
    /// the editor's default paste) is served from the pasteboard cache while the text is still
    /// there; the margin covers one that a slow page script delays, and, if an unknown eager
    /// reader took the receipt first, a target that reads up to this late.
    static let electronRestoreAfterRead: TimeInterval = 0.4

    /// A backstop that runs late (speakfree's main thread was busy) while nothing has read yet
    /// gets one grace period before restoring: a target's read request can be queued behind the
    /// busy main thread, and restoring first would make that paste come up empty.
    static let lateBackstopGrace: TimeInterval = 0.25
    /// Lateness below this is ordinary timer jitter, not a busy main thread.
    static let lateBackstopThreshold: TimeInterval = 0.05

    /// Pure timing policy (unit-tested). Remote viewers sync the clipboard eagerly, so a read
    /// there proves nothing about the remote paste: backstop only.
    static func restoreTiming(route: PasteRoute) -> ClipboardRestoreTiming {
        switch route {
        case .remote: return ClipboardRestoreTiming(backstop: remoteClipboardRestoreDelay, afterRead: nil)
        case .native: return ClipboardRestoreTiming(backstop: localClipboardRestoreDelay,
                                                    afterRead: nativeRestoreAfterRead)
        case .electron: return ClipboardRestoreTiming(backstop: electronClipboardRestoreDelay,
                                                      afterRead: electronRestoreAfterRead)
        }
    }

    /// Pure saved-original decision (unit-tested). Reuse the pending snapshot ONLY while our own
    /// last write is still the live clipboard — then the live clipboard is the dictation text and
    /// re-snapshotting would save THAT as the "original". If anything else wrote since (the user
    /// copied via right-click/pbcopy/a button — no Command press needed), the snapshot is stale:
    /// re-snapshot so the user's fresh copy becomes what we restore, and so the size cap measures it.
    static func shouldReusePendingSnapshot(pendingWrittenChangeCount: Int?,
                                           currentChangeCount: Int) -> Bool {
        guard let pending = pendingWrittenChangeCount else { return false }
        return pending == currentChangeCount
    }

    /// Is this bundle ID on the hand-maintained paste list (Electron apps listed before the
    /// framework probe existed, plus special cases like Superhuman)? List in `AppCompatibility`.
    static func prefersClipboardPaste(bundleID: String) -> Bool {
        AppCompatibility.isListedPaste(bundleID: bundleID)
    }

    /// The AX-unreliable contenteditable class: every known/probed Electron or CEF app, plus
    /// explicit clipboard-routed editors. These apps already cannot use AX insertion reliably;
    /// live focused-element/window reads are optional enrichment and must not contend with the
    /// hotkey path. Native apps and browsers keep context unless separately classified.
    static func shouldAvoidLiveWindowContext(bundleID: String?, bundleURL: URL?) -> Bool {
        guard let bundleID else { return false }
        if prefersClipboardPaste(bundleID: bundleID) { return true }
        if isChromiumEmbedded(bundleID: bundleID, bundleURL: bundleURL) { return true }
        // 2026-09-24: also renamed Chromium builds found by the classifier's marker probe
        // (browsers are classified separately and keep their live context).
        return AppCompatibility.classify(bundleID: bundleID, bundleURL: bundleURL).appClass == .webRuntime
    }

    /// Chromium-embedding frameworks. An app shipping one of these renders its text fields
    /// as web contenteditables, which is what makes both synthetic typing and AX writes
    /// unreliable — the exact class the hand-maintained list above was approximating.
    private static let embeddedChromiumFrameworks = AppCompatibility.webRuntimeFrameworks

    /// Does this app bundle ship an embedded Chromium runtime? Pure over the filesystem so
    /// tests can point it at a synthetic bundle rather than a real installed app.
    static func bundleEmbedsChromium(at bundleURL: URL) -> Bool {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        return embeddedChromiumFrameworks.contains { name in
            FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(name).path)
        }
    }

    /// Bundle-ID-keyed memo for `bundleEmbedsChromium`. The probe is two `fileExists` calls,
    /// but `prefersClipboardPaste` is consulted on the main thread at record-start, so the
    /// result is cached rather than re-stat'd on every dictation.
    private static var chromiumProbeCache: [String: Bool] = [:]
    private static let chromiumProbeLock = NSLock()

    /// Reset hook for tests — the cache is process-global and would otherwise leak between cases.
    static func resetChromiumProbeCache() {
        chromiumProbeLock.lock()
        chromiumProbeCache.removeAll()
        chromiumProbeLock.unlock()
    }

    static func isChromiumEmbedded(bundleID: String, bundleURL: URL?) -> Bool {
        chromiumProbeLock.lock()
        if let cached = chromiumProbeCache[bundleID] {
            chromiumProbeLock.unlock()
            return cached
        }
        chromiumProbeLock.unlock()

        guard let bundleURL else { return false }
        let result = bundleEmbedsChromium(at: bundleURL)

        chromiumProbeLock.lock()
        chromiumProbeCache[bundleID] = result
        chromiumProbeLock.unlock()
        if result {
            DiagnosticLogger.shared.log("TextInserter: detected embedded Chromium in \(bundleID) — routing to clipboard paste")
        }
        return result
    }

    /// The clipboard-paste decision for a live app. Prefers the explicit list (which also
    /// covers non-Chromium special cases like Superhuman), then falls back to probing the
    /// bundle. Added 2026-07-28: Claude for Desktop broke because it was Electron but
    /// unlisted, and every future Electron app would have broken the same silent way.
    static func prefersClipboardPaste(app: NSRunningApplication?) -> Bool {
        guard let app, let bundleID = app.bundleIdentifier else { return false }
        if prefersClipboardPaste(bundleID: bundleID) { return true }
        return isChromiumEmbedded(bundleID: bundleID, bundleURL: app.bundleURL)
    }

    static func canSafelySaveClipboard(byteSize: Int) -> Bool {
        byteSize <= maxRestorableClipboardBytes
    }

    /// Is this bundle ID a known browser? Kept for callers and tests; routing uses the full
    /// classification, which also recognizes unlisted browsers by the http(s) links and HTML
    /// files they register for. Browsers go to clipboard paste because Chromium accepts an AX
    /// SelectedText write, reports success, and applies nothing (2026-08-12 Chrome silent-drop).
    static func isBrowser(bundleID: String) -> Bool {
        AppCompatibility.isKnownBrowser(bundleID: bundleID)
    }

    /// Classification-based replacement for the Electron-class check at record start: true for
    /// every class whose live AX cursor context is untrustworthy (web runtimes, the paste list,
    /// and terminals, whose AX value is the whole scrollback).
    static func cursorContextUntrusted(app: NSRunningApplication?) -> Bool {
        guard let app, let bundleID = app.bundleIdentifier else { return false }
        if prefersClipboardPaste(app: app) { return true }
        return AppCompatibility.classify(bundleID: bundleID, bundleURL: app.bundleURL)
            .appClass.cursorContextUntrusted
    }

    /// One emitted keyboard operation on the synthetic-typing path. Pure value type so the
    /// Option B newline routing can be unit-tested without posting real CGEvents.
    enum KeystrokeOp: Equatable {
        /// A chunk of text typed via CGEventKeyboardSetUnicodeString (≤ 20 UTF-16 units).
        case unicode([UniChar])
        /// A spoken line break. Newline policy 2b / Option B: Shift+Return — inserts a line
        /// break and NEVER sends (a bare Return / keyCode 36 alone would send in Slack/Messages).
        case shiftReturn
    }

    /// Pure decomposition of `text` into the ordered keystroke ops the typing path will emit.
    /// Every "\n"/"\r" becomes a `.shiftReturn` (Option B line break, never a bare Return);
    /// runs of other characters are chunked into ≤ 20 UTF-16-unit `.unicode` ops, splitting on
    /// Unicode scalar boundaries so surrogate pairs are never broken.
    static func keystrokeOps(for text: String) -> [KeystrokeOp] {
        let scalars = Array(text.unicodeScalars)
        var ops: [KeystrokeOp] = []
        var i = 0

        while i < scalars.count {
            if scalars[i].value == 0x0A || scalars[i].value == 0x0D {
                ops.append(.shiftReturn)
                // Collapse a CRLF / LFCR pair into a SINGLE break (AR-1 Low #7): "\r\n" is one
                // line break, not two. A genuine double break ("\n\n" from spoken "new paragraph")
                // is two DISTINCT LF scalars and is preserved — only a CR+LF *pair* collapses.
                if scalars[i].value == 0x0D, i + 1 < scalars.count, scalars[i + 1].value == 0x0A {
                    i += 2
                } else if scalars[i].value == 0x0A, i + 1 < scalars.count, scalars[i + 1].value == 0x0D {
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            // Build a chunk of scalars whose total UTF-16 length is ≤ 20.
            // A scalar outside the BMP (U+10000+) encodes as 2 UTF-16 code units (surrogate pair).
            var chunkUTF16: [UniChar] = []
            while i < scalars.count {
                let sv = scalars[i].value
                if sv == 0x0A || sv == 0x0D { break }  // newline handled above
                let scalarUTF16 = Array(String(scalars[i]).utf16)
                if chunkUTF16.count + scalarUTF16.count > 20 { break }
                chunkUTF16.append(contentsOf: scalarUTF16)
                i += 1
            }

            // Safety: a single scalar > 20 UTF-16 units is impossible (max is 2), but guard anyway.
            if chunkUTF16.isEmpty { i += 1; continue }
            ops.append(.unicode(chunkUTF16))
        }
        return ops
    }

    /// Insert text by simulating keyboard events with unicode characters.
    /// Works in Electron apps (VS Code, Slack, Discord) without touching the clipboard.
    /// CGEventKeyboardSetUnicodeString limits input to 20 UTF-16 code units per event.
    /// Chunks by Unicode scalars to avoid splitting surrogate pairs at chunk boundaries.
    private func typeViaKeyEvents(_ text: String, allowLineBreaks: Bool) -> Bool {
        // Never type a line break into a terminal (2026-09-24). The typed Shift+Return below
        // reaches most terminals, and the shells and agent TUIs inside them, as a plain Return
        // unless the program has enabled an extended keyboard protocol, so it would run the
        // command or submit the prompt. Returning false sends callers to paste, where the
        // terminal wraps the line breaks in bracketed paste.
        if AppCompatibility.hasLineBreak(text)
            && (!allowLineBreaks || frontmostProfile().typedLineBreaksUnsafe) {
            DiagnosticLogger.shared.log("TextInserter: refusing to type a line break (could be Return in a terminal)")
            return false
        }
        // Remote viewers may ignore the Unicode payload and forward virtualKey 0
        // literally as "a". Never use this backend for a recognized remote viewer, under any
        // per-app setting. Checked before the test seam so tests see the production refusal.
        guard !isRemoteDesktopFrontmost() else { return false }
        // AX work or clipboard snapshot providers may have yielded since the entry guard.
        guard insertionDestinationIsCurrent() else { return false }
        if let performUnicodeInsertion = performUnicodeInsertion {
            return performUnicodeInsertion(text)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for op in Self.keystrokeOps(for: text) {
            switch op {
            case .shiftReturn:
                // Newline policy 2b / Option B (the maintainer, 2026-06-10): a spoken "new line" is a
                // line break that NEVER sends. By the time text reaches here, every "\n" is a
                // deliberately-spoken break (Whisper's multi-segment joins are space-joined
                // upstream in Transcriber). Fire Shift+Return (keyCode 36 + .maskShift) — a
                // *bare* Return (keyCode 36 alone) would map to "send message" in Slack/Messages,
                // which Option B forbids. Shift+Return inserts a newline in those apps' compose
                // box and a plain line break in editors, never a send.
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                      let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
                    return false
                }
                keyDown.flags = .maskShift
                keyUp.flags = .maskShift
                SyntheticEventMarker.mark(keyDown)
                SyntheticEventMarker.mark(keyUp)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)

            case .unicode(let chunkUTF16):
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return false
                }

                chunkUTF16.withUnsafeBufferPointer { buffer in
                    keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                SyntheticEventMarker.mark(keyDown)
                SyntheticEventMarker.mark(keyUp)

                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }

        return true
    }

    /// Clipboard-based insertion with safety check and transient marking.
    ///
    /// A complete snapshot within the save limit is required before borrowing the clipboard.
    /// Unsafe snapshots fall back to single-line typing or visible dictation recovery.
    ///
    /// Transient marking: writes org.nspasteboard.TransientType + ConcealedType so
    /// clipboard managers (Maccy, Raycast, Paste) skip recording the dictated text.
    /// All pending-restore state (pendingRestore, pendingBackstop) is touched only from the main
    /// thread — every production caller reaches here on main (finalize/reprocess/secure-input/
    /// focus-settle) and the backstop closure is main-dispatched. The precondition turns a future
    /// off-main caller (e.g. FinalizePipeline.run with a real inserter) into a crash instead of a
    /// silent data race on the shared state.
    func pasteViaClipboard(_ text: String) {
        pasteViaClipboard(text, mayRetryChangedClipboard: true)
    }

    /// One retry across both snapshot-time and pre-write generation changes. No shortcut has
    /// been sent before either failure, so retrying cannot duplicate a previous insertion.
    private func pasteViaClipboard(_ text: String, mayRetryChangedClipboard: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        let pasteboard = self.pasteboard
        let route = AppCompatibility.pasteRestoreRoute(for: frontmostProfile().appClass)
        // A canary on the clipboard must never be saved as the user's "original".
        clipboardCanary?.abort(reason: "clipboard-borrow")
        pendingRestore?.pasteCheck?.cancel()
        // An earlier borrow still pending means its paste may land after this one's "before"
        // read; with the same text, that late paste would look like this one. So no
        // Accessibility check for a paste that overlaps an earlier one: the timers decide.
        // A borrow restored moments ago counts too (a restore on the first read can come before
        // an Electron target commits that paste).
        let overlapsEarlierBorrow = pendingRestore != nil
            || lastBorrowEndedAt.map { uptime() - $0 < TextInserter.pasteCheckQuietAfterBorrow } ?? false
        // Stop the paste-watch tap from acting on the previous borrow BEFORE this one touches the
        // pasteboard: after this returns, no tap-thread restore can interleave with the snapshot
        // and write below. (If the tap already restored it, the live clipboard is the user's
        // again, and the reuse check below re-snapshots it.)
        userPasteGate.claim(token: nil)

        // Saved-original: reuse the pending snapshot ONLY while our last dictation write is still
        // the live clipboard (else re-snapshotting would save that dictation's text). If anything
        // else wrote since — the user copied via right-click/pbcopy/a Copy button, no Command press
        // — the pending snapshot is stale, so re-snapshot the user's fresh copy instead.
        let snapshotGeneration = pasteboard.changeCount
        let reuse = TextInserter.shouldReusePendingSnapshot(
            pendingWrittenChangeCount: pendingRestore?.writtenChangeCount,
            currentChangeCount: pasteboard.changeCount)
        let savedItems: PasteboardAccess.Snapshot
        if reuse {
            savedItems = pendingRestore!.savedItems
        } else {
            do {
                savedItems = try captureClipboardSnapshot(pasteboard, Self.maxRestorableClipboardBytes)
            } catch {
                if error as? PasteboardAccess.Failure == .changed, mayRetryChangedClipboard {
                    pasteViaClipboard(text, mayRetryChangedClipboard: false)
                    return
                }
                fallbackWithoutBorrowingClipboard(text, failure: error as? PasteboardAccess.Failure)
                return
            }
        }
        let clipboardByteSize = savedItems.reduce(0) { total, item in
            total + item.reduce(0) { $0 + $1.1.count }
        }
        let timing = restoreTiming(route)
        var earlyOffReason: String?
        if timing.afterRead == nil {
            earlyOffReason = "route"
        } else if let reason = clipboardTrustReason() {
            earlyOffReason = reason
        }
        let restoreAfterRead = earlyOffReason == nil ? timing.afterRead : nil

        // Recheck after route/trust work too. NSPasteboard has no cross-process CAS;
        // this closes our own snapshot-to-write work window without claiming atomicity.
        guard pasteboard.changeCount == snapshotGeneration else {
            if mayRetryChangedClipboard {
                pasteViaClipboard(text, mayRetryChangedClipboard: false)
            } else {
                fallbackWithoutBorrowingClipboard(text, failure: .changed)
            }
            return
        }

        // Publish dictated text only after a successful clear, and require writeObjects
        // to confirm the write in that same generation before sending a paste shortcut.
        // Local routes write a host-only LAZY promise whose first read is the receipt; the remote
        // route keeps the eager write it was tuned with (remote viewers sync it immediately).
        var provider: DictationPasteProvider?
        let publication: PasteboardWriter.Result
        if route == .remote {
            publication = TextInserter.writeTransientString(text, to: pasteboard, writer: pasteboardWriter,
                                                          expectedGeneration: snapshotGeneration)
        } else {
            let lazy = DictationPasteProvider(text: text)
            lazy.onRead = { [weak self, weak lazy] in
                guard let self, let lazy else { return }
                self.noteReadReceipt(from: lazy, pasteboard: pasteboard)
            }
            provider = lazy
            publication = TextInserter.writeLazyDictation(provider: lazy, to: pasteboard, writer: pasteboardWriter,
                                                        expectedGeneration: snapshotGeneration)
        }

        guard let writtenChangeCount = publication.generation else {
            pendingBackstop?.cancel()
            pendingBackstop = nil
            pendingRestore = nil
            lastBorrowEndedAt = uptime()
            let recovery = Self.recoveryMessage(pasteboardWriter.recover(savedItems, after: publication, on: pasteboard))
            remoteInsertionFailed(text,
                message: "Speakfree could not publish your dictation, so no paste shortcut was sent. " + recovery,
                title: "Check your dictation")
            return
        }

        let pastedAt = uptime()
        let targetPID = frontmostPIDProvider()
        var gateToken: Int?
        if provider != nil {
            gateToken = userPasteGate.arm(
                pasteboard: pasteboard, savedItems: savedItems,
                writtenChangeCount: writtenChangeCount,
                layoutVKeyCode: (layoutVKeyCodeProvider?() ?? vKeyCode()).map { Int64($0) },
                restore: { [writer = pasteboardWriter] pb, items in
                    writer.restore(items, on: pb, expectedGeneration: writtenChangeCount).generation != nil
                },
                onOutcome: { [weak self] outcome in self?.handleUserPasteOutcome(outcome) })
        }
        pendingRestore = PendingClipboardRestore(savedItems: savedItems,
                                                 writtenChangeCount: writtenChangeCount,
                                                 provider: provider,
                                                 route: route,
                                                 pastedAt: pastedAt,
                                                 firstReadAt: nil,
                                                 restoreAfterRead: restoreAfterRead,
                                                 earlyOffReason: earlyOffReason,
                                                 targetPID: targetPID,
                                                 gateToken: gateToken)
        // Accessibility outcome check: local lazy writes only, with a known target app. Main
        // only creates the check and queues work; every AX call runs on `pasteCheckQueue`.
        var pasteCheck: PasteOutcomeCheck?
        if provider != nil, !overlapsEarlierBorrow, let reader = pasteFieldReader, let pid = targetPID,
           !pasteCheckDelays.isEmpty {
            let check = PasteOutcomeCheck(text: text, pid: pid, reader: reader, queue: pasteCheckQueue)
            check.captureBefore()
            pendingRestore?.pasteCheck = check
            pendingRestore?.pasteVerdict = "pending"
            pasteCheck = check
        }
        DiagnosticLogger.shared.log(
            "TextInserter: clipboard paste route=\(route.rawValue) len=\(text.count) "
            + "clip=\(clipboardByteSize / 1024)KB backstop=\(String(format: "%.1f", timing.backstop))s "
            + "early=\(restoreAfterRead.map { String(format: "%.2fs", $0) } ?? "off(\(earlyOffReason ?? "?"))")")
        // Arm the backstop BEFORE the paste: a target that reads synchronously during the paste
        // shortcut replaces it with the (shorter) after-read timer, never the other way round.
        armRestore(pasteboard: pasteboard, delay: timing.backstop, trigger: "backstop")

        simulatePaste(text, expectedChangeCount: writtenChangeCount)
        pasteCheck?.start(delays: pasteCheckDelays) { [weak self, weak pasteCheck] verdict in
            guard let self, let pasteCheck else { return }
            self.notePasteOutcome(verdict, from: pasteCheck, pasteboard: pasteboard)
        }
    }

    private static func recoveryMessage(_ recovery: PasteboardWriter.Recovery) -> String {
        switch recovery {
        case .restored: return "Your previous clipboard was restored."
        case .changed: return "A newer clipboard change was left alone."
        case .unavailable: return "The current clipboard was left alone."
        case .failed: return "macOS also refused to restore your previous clipboard."
        }
    }

    /// Never destroy clipboard data to recover from a failed snapshot. Our typing backend
    /// emits Shift+Return for line breaks, which can submit a command in an unknown app or a
    /// browser's terminal. Multiline text stays selectable in the recovery dialog instead.
    private func fallbackWithoutBorrowingClipboard(_ text: String, failure: PasteboardAccess.Failure?) {
        // Snapshot providers can block while focus changes or Secure Input starts. Typing
        // bypasses the normal final paste guard, so check again before emitting any key event.
        guard insertionDestinationIsCurrent() else {
            remoteInsertionFailed(text,
                message: "The destination or Secure Input changed while speakfree was preparing your dictation. Your clipboard was left unchanged. Review the dictation below; Copy Dictation will replace the clipboard only if you choose it.",
                title: "Check your dictation")
            return
        }
        if typeViaKeyEvents(text, allowLineBreaks: false) {
            outcomeAdjustment = .typed
            return
        }
        let reason: String
        switch failure {
        case .changed: reason = "Your clipboard changed again while speakfree was preparing the paste."
        case .tooLarge: reason = "Your clipboard holds an item too large to safely preserve."
        case .denied: reason = "Speakfree could not read your clipboard to safely preserve it."
        default: reason = "Your clipboard could not be completely preserved."
        }
        remoteInsertionFailed(text,
            message: reason + " Your clipboard was left unchanged. Review the dictation below; Copy Dictation will replace the clipboard only if you choose it.",
            title: "Check your dictation")
    }

    /// Main thread: the Accessibility check's final verdict for the LIVE borrow. Confirmed means
    /// the target pasted the text, whoever read the clipboard first: restore now.
    private func notePasteOutcome(_ verdict: PasteOutcomeVerdict, from check: PasteOutcomeCheck,
                                  pasteboard: NSPasteboard) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var pending = pendingRestore, pending.pasteCheck === check else { return }
        pending.pasteVerdict = verdict == .notYet ? "unconfirmed" : verdict.rawValue
        pendingRestore = pending
        guard verdict == .confirmed else { return }
        pendingBackstop?.cancel()
        pendingBackstop = nil
        performPendingRestore(pasteboard: pasteboard, trigger: "ax")
    }

    private func armRestore(pasteboard: NSPasteboard, delay: TimeInterval, trigger: String) {
        pendingBackstop?.cancel()
        let due = uptime() + delay
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if trigger == "backstop", self.shouldGraceLateBackstop(due: due) {
                self.armRestore(pasteboard: pasteboard, delay: TextInserter.lateBackstopGrace,
                                trigger: "backstop")
                return
            }
            self.performPendingRestore(pasteboard: pasteboard, trigger: trigger)
        }
        pendingBackstop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A backstop that fires well after its due time means main was blocked; a target's read of
    /// the lazy text may be queued behind it. Grant ONE grace period, and only while nothing has
    /// read yet (after a read, the text is cached by the pasteboard server and safe to replace).
    private func shouldGraceLateBackstop(due: TimeInterval) -> Bool {
        guard var pending = pendingRestore, pending.provider != nil,
              pending.firstReadAt == nil, !pending.backstopGraceUsed,
              uptime() - due > TextInserter.lateBackstopThreshold else { return false }
        pending.backstopGraceUsed = true
        pendingRestore = pending
        DiagnosticLogger.shared.log(
            "TextInserter: clipboard restore backstop ran late; waiting one grace period for a queued read")
        return true
    }

    /// Main-thread bookkeeping for a read receipt from the LIVE dictation's provider. A stale
    /// provider (a superseded dictation) is ignored; only the first receipt counts; speakfree's
    /// own read (`withOwnPasteboardRead`) was already filtered out by the provider.
    private func noteReadReceipt(from provider: DictationPasteProvider, pasteboard: NSPasteboard) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var pending = pendingRestore, pending.provider === provider,
              pending.firstReadAt == nil else { return }
        // A reader can start after the write. Recheck before treating the first read as a
        // receipt, while preserving an earlier reason for distrust for this entire borrow.
        if pending.earlyOffReason == nil, let reason = clipboardTrustReason() {
            pending.earlyOffReason = reason
            pending.restoreAfterRead = nil
        }
        // Unknown focus is not evidence that the target is still frontmost. The text is now
        // cached, so subsequent reads cannot establish the missing identity: backstop decides.
        let front = frontmostPIDProvider()
        guard let target = pending.targetPID, let front, front == target else {
            pending.firstReadAt = uptime()
            pending.restoreAfterRead = nil
            let reason = pending.targetPID == nil || front == nil
                ? "read-with-unknown-target-or-focus" : "read-while-other-app-frontmost"
            pending.earlyOffReason = pending.earlyOffReason ?? reason
            pendingRestore = pending
            if let token = pending.gateToken {
                userPasteGate.markUntrustedRead(token: token, reason: pending.earlyOffReason ?? "?")
            }
            return
        }
        let now = uptime()
        pending.firstReadAt = now
        pendingRestore = pending
        guard let afterRead = pending.restoreAfterRead else {
            if let token = pending.gateToken {
                userPasteGate.markUntrustedRead(token: token, reason: pending.earlyOffReason ?? "?")
            }
            return
        }
        // The target read the dictation: from now on the user's own Cmd+V may restore first.
        if let token = pending.gateToken { userPasteGate.markTrustedRead(token: token) }
        // Replaces the backstop. Normally this is much sooner; if the read itself came close to
        // the backstop, the margin still applies, which is safer than restoring right after a read.
        armRestore(pasteboard: pasteboard, delay: afterRead, trigger: "read")
    }

    /// Restore the saved clipboard (once) and log the outcome with its timing. Restores only if
    /// OUR latest write is still live; if the user or another app wrote in the meantime, their
    /// content is left alone.
    private func performPendingRestore(pasteboard: NSPasteboard, trigger: String) {
        pendingBackstop = nil
        // `pending` keeps the provider alive through the restore below.
        guard let pending = pendingRestore else { return }
        // Take the borrow back from the paste-watch tap. If the tap already restored it (the
        // user's Cmd+V won the race), its outcome is on the way to `handleUserPasteOutcome`,
        // which finishes the bookkeeping; restoring again here could clobber a newer copy.
        if let token = pending.gateToken, !userPasteGate.claim(token: token) { return }
        pendingRestore = nil
        lastBorrowEndedAt = uptime()
        pending.pasteCheck?.cancel()
        let restored = pasteboardWriter.restore(pending.savedItems, on: pasteboard,
            expectedGeneration: pending.writtenChangeCount).generation != nil
        let record = ClipboardRestoreRecord(
            route: pending.route, trigger: trigger, lazy: pending.provider != nil,
            pasteToRead: pending.firstReadAt.map { $0 - pending.pastedAt },
            pasteToRestore: uptime() - pending.pastedAt, restored: restored,
            earlyOffReason: pending.earlyOffReason, pasteCheck: pending.pasteVerdict)
        DiagnosticLogger.shared.log(record.logLine)
        onClipboardRestore?(record)
    }

    /// Main thread: what the paste-watch tap did with the user's Cmd+V (UserPasteRestore.swift).
    private func handleUserPasteOutcome(_ outcome: UserPasteRestoreGate.Outcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch outcome {
        case .restored(let token), .restoreFailed(let token):
            let restored: Bool
            if case .restored = outcome { restored = true } else { restored = false }
            userPasteGate.claim(token: token)  // clears the tap's "already restored" mark
            let now = uptime()
            if let pending = pendingRestore, pending.gateToken == token {
                pending.pasteCheck?.cancel()
                lastBorrowEndedAt = now
                pendingBackstop?.cancel()
                pendingBackstop = nil
                pendingRestore = nil
                let record = ClipboardRestoreRecord(
                    route: pending.route, trigger: "user-paste", lazy: true,
                    pasteToRead: pending.firstReadAt.map { $0 - pending.pastedAt },
                    pasteToRestore: now - pending.pastedAt, restored: restored,
                    earlyOffReason: pending.earlyOffReason, pasteCheck: pending.pasteVerdict)
                DiagnosticLogger.shared.log(record.userPasteLogLine)
                onClipboardRestore?(record)
            } else {
                // A newer borrow already replaced it (the next paste started first).
                DiagnosticLogger.shared.log("Clipboard restore: trigger=user-paste restored=\(restored) superseded")
            }
        case .skipped(_, let reason):
            DiagnosticLogger.shared.log("Clipboard restore: trigger=user-paste skipped reason=\(reason)")
        case .clipboardChanged:
            // The backstop or after-read timer still runs and logs restored=false.
            DiagnosticLogger.shared.log("Clipboard restore: trigger=user-paste skipped reason=clipboard-changed")
        case .notPaste, .ownSynthetic, .idle:
            break
        }
    }

    /// One finished clipboard borrow, as logged: which route, what triggered the restore, how
    /// long from Cmd+V to the first read and to the restore, and whether the user's clipboard was
    /// put back (false = something else wrote to the clipboard first, which is left alone).
    /// On the remote route the times count from the clipboard write; its Cmd+V goes 0.4 s later.
    struct ClipboardRestoreRecord: Equatable {
        let route: PasteRoute
        let trigger: String
        let lazy: Bool
        let pasteToRead: TimeInterval?
        let pasteToRestore: TimeInterval
        let restored: Bool
        let earlyOffReason: String?
        /// The Accessibility outcome check's verdict (confirmed, unconfirmed, unreadable,
        /// pending), nil when none ran. A verdict only, never field text.
        var pasteCheck: String? = nil

        var logLine: String {
            func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded()))ms" }
            let read = lazy ? (pasteToRead.map(ms) ?? "none") : "n/a"
            return "TextInserter: clipboard restore route=\(route.rawValue) trigger=\(trigger) "
                + "read=\(read) pasteToRestore=\(ms(pasteToRestore)) restored=\(restored)"
                + (earlyOffReason.map { " early=off(\($0))" } ?? "")
                + (pasteCheck.map { " ax=\($0)" } ?? "")
        }

        /// The user-paste trigger's line: "Clipboard restore: trigger=user-paste route=... ".
        var userPasteLogLine: String {
            func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded()))ms" }
            return "Clipboard restore: trigger=\(trigger) route=\(route.rawValue) "
                + "read=\(pasteToRead.map(ms) ?? "none") pasteToRestore=\(ms(pasteToRestore)) "
                + "restored=\(restored)"
        }
    }

    /// Observer for finished clipboard borrows (tests; nil in production, which only logs).
    var onClipboardRestore: ((ClipboardRestoreRecord) -> Void)?

    /// True while a dictation promise is on the clipboard and no process has read it yet.
    /// speakfree must not read it then (see AppDelegate.noteUserInteraction).
    var dictationPromiseUnread: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return pendingRestore?.provider.map { $0.provideCount == 0 } ?? false
    }

    /// The layout's "v" key code as the paste-watch gate wants it (the clipboard canary arms the
    /// same gate). Main thread.
    func layoutVKeyCodeForGate() -> Int64? {
        (layoutVKeyCodeProvider?() ?? vKeyCode()).map { Int64($0) }
    }

    /// True while speakfree has the user's clipboard borrowed (a restore is pending). Main only.
    var hasPendingClipboardBorrow: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return pendingRestore != nil
    }

    /// A reader can skip our current borrow without suppressing a later external copy.
    var ownsCurrentClipboard: Bool {
        pendingRestore?.writtenChangeCount == pasteboard.changeCount
    }

    /// Test seam: the live dictation's lazy provider, if a borrow is pending.
    var pendingDictationProviderForTest: DictationPasteProvider? { pendingRestore?.provider }

    /// Run `body` (a read of the clipboard by speakfree itself) without it counting as the
    /// target's read receipt. Main thread only; the provider consults the flag synchronously.
    static func withOwnPasteboardRead<T>(_ body: () -> T) -> T {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = DictationPasteProvider.ownReadInProgress
        DictationPasteProvider.ownReadInProgress = true
        defer { DictationPasteProvider.ownReadInProgress = previous }
        // Never overlap a paste-watch tap restore on the shared NSPasteboard object (this read
        // typically runs right after the user's Cmd+V, which is exactly when the tap writes).
        return UserPasteRestoreGate.shared.excludingTapRestore(body)
    }

    private func copyToClipboard(_ text: String) -> Bool {
        publishConcealedCopy(text) != nil
    }

    /// The existing recovery UI owns failure reporting; never enqueue a nested dialog.
    func copyForManualRecovery(_ text: String) -> Bool {
        publishConcealedCopy(text, reportFailure: false) != nil
    }

    private func publishConcealedCopy(_ text: String, reportFailure: Bool = true) -> Int? {
        // Focus-lost fallback: mark the write Concealed + Transient exactly like the two sibling
        // clipboard paths (pasteViaClipboard / secureInputClipboardFallback) so clipboard-history
        // tools skip recording the dictated text (AX-D).
        // A dictation trace is for the app it was dictated into; a copy the user may paste
        // anywhere (a message to someone) never carries one.
        clipboardCanary?.abort(reason: "clipboard-write")
        userPasteGate.claim(token: nil)
        let before = pasteboard.changeCount
        let saved = pendingRestore?.writtenChangeCount == before ? pendingRestore?.savedItems
            : try? captureClipboardSnapshot(pasteboard, Self.maxRestorableClipboardBytes)
        let publication = Self.writeTransientString(readableRecoveryText(text), to: pasteboard,
            writer: pasteboardWriter, expectedGeneration: before)
        guard let written = publication.generation else {
            let recovery: String
            if let saved {
                recovery = Self.recoveryMessage(pasteboardWriter.recover(saved, after: publication, on: pasteboard))
            } else if publication.recoveryGeneration != nil {
                recovery = "The previous clipboard could not be preserved."
            } else {
                recovery = Self.recoveryMessage(.unavailable)
            }
            if reportFailure {
                remoteInsertionFailed(text, message: "Speakfree could not copy the dictation to the clipboard. " + recovery,
                                      title: "Check your dictation")
            }
            return nil
        }
        return written
    }

    /// `text` with any dictation trace removed (cheap no-op for ordinary text).
    static func withoutTrace(_ text: String) -> String {
        DictationTrace.mayContainTrace(text) ? DictationTrace.strip(text) : text
    }

    /// Dot-only output cannot reconstruct the finished dictation by stripping.
    /// The attempt carries its own original text through deferred focus and remote-paste work.
    private func readableRecoveryText(_ text: String, attempt: InsertionAttempt? = nil) -> String {
        (attempt ?? activeInsertionAttempt)?.recoveryText ?? Self.withoutTrace(text)
    }

    /// How long dictated text may sit on the clipboard after a Secure-Input fallback before it
    /// is auto-cleared. Seam so tests can shrink it. Production default: 15 s — short enough
    /// that the plaintext does not linger, yet long enough for most users to paste.
    var secureInputClipboardClearDelay: TimeInterval = 15

    /// Why the concealed clipboard path was taken. The distinction matters to the UI:
    /// `.secureInput` means the text was definitely NOT inserted, so telling the user to
    /// press ⌘V (and auto-retrying the insert) is safe; `.axTimeoutMayHaveCommitted`
    /// means the AX write MAY have landed, so any retry or paste prompt risks a duplicate
    /// — the UI must stay at "copied" and do nothing clever.
    enum ConcealedFallbackReason { case secureInput, axTimeoutMayHaveCommitted }

    /// Called when `insert()` falls back to the concealed Secure-Input clipboard path instead of
    /// inserting text directly. Unlike `onFocusLost` (which fires for any focus failure), this
    /// fires ONLY for the concealed-copy cases so the UI can react (Secure-Input retry
    /// dialog / auto-clear notification). Carries the dictated text so the `.secureInput`
    /// case can auto-retry the insertion once Secure Input clears (the maintainer 2026-08-12).
    /// Set by the caller (AppDelegate) before each insertion.
    var onSecureInputFallback: ((String, ConcealedFallbackReason) -> Void)?

    /// Secure-Input clipboard fallback (audit AR-1). Dictating into a password field is the
    /// worst case, so unlike `copyToClipboard` this:
    ///   - marks the write org.nspasteboard.ConcealedType + TransientType, so clipboard
    ///     managers (Maccy, Raycast, Paste) skip recording it;
    ///   - auto-clears the clipboard after `secureInputClipboardClearDelay`, but ONLY if our
    ///     write is still the current contents (changeCount unchanged) — if the user copied
    ///     something else in the meantime we leave their clipboard alone.
    /// It does NOT restore the prior clipboard (the user explicitly invoked dictation expecting
    /// the text to be available to paste); the concealment + auto-clear are the protection.
    @discardableResult
    func secureInputClipboardFallback(_ text: String) -> Bool {
        let pasteboard = self.pasteboard
        let gate = userPasteGate
        guard let writtenChangeCount = publishConcealedCopy(text) else { return false }
        let writer = pasteboardWriter
        DispatchQueue.main.asyncAfter(deadline: .now() + secureInputClipboardClearDelay) {
            guard pasteboard.changeCount == writtenChangeCount else { return }
            // Recheck inside the gate and helper, not just before taking the gate lock.
            gate.writeOutsideBorrow {
                let cleared = writer.replace([], on: pasteboard, expectedGeneration: writtenChangeCount)
                if cleared.generation != nil {
                    DiagnosticLogger.shared.log("TextInserter: auto-cleared concealed Secure-Input clipboard text")
                }
            }
        }
        return true
    }

    /// Name of the app holding Secure Input, read from IOHIDSystem's
    /// kCGSSessionSecureInputPID (the same source `ioreg -l | grep SecureInput` shows).
    /// Best-effort: nil when the property is absent, unreadable, or the PID has no
    /// running application. Used only to make the Secure-Input dialog name the blocker.
    static func secureInputHolderName() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let pid = (dict["kCGSSessionSecureInputPID"] as? Int)
            ?? ((dict["HIDParameters"] as? [String: Any])?["kCGSSessionSecureInputPID"] as? Int)
        guard let pid else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }

    /// One tick of the Secure-Input retry loop (the maintainer 2026-08-12: "a little box that
    /// says secure input activated, hit Command V … keeps retrying, and if it gets it,
    /// it shuts down the box"). Pure so the policy is testable:
    ///   - the dictation leaving the clipboard (user copied something else, or the
    ///     auto-clear fired) or the hold expiring ends the dialog — nothing to paste;
    ///   - while Secure Input stays on, keep waiting (the user can still press ⌘V);
    ///   - when it clears, auto-insert ONLY if the same app is still frontmost —
    ///     inserting into whatever the user switched to would land text in the wrong app.
    enum SecureInputRetryAction: Equatable { case wait, insert, dismiss }

    static func secureInputRetryAction(secureInputActive: Bool,
                                       clipboardMoved: Bool,
                                       frontmostMatchesTarget: Bool,
                                       deadlinePassed: Bool) -> SecureInputRetryAction {
        if deadlinePassed || clipboardMoved { return .dismiss }
        if secureInputActive { return .wait }
        return frontmostMatchesTarget ? .insert : .wait
    }

    /// Publish transient/concealed text with a checked result. A successful result carries
    /// the exact clear generation; failure never supplies a generation usable for a paste.
    @discardableResult
    static func writeTransientString(_ text: String, to pasteboard: NSPasteboard,
                                     writer: PasteboardWriter = PasteboardWriter(),
                                     expectedGeneration: Int? = nil) -> PasteboardWriter.Result {
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        return writer.replace([item], on: pasteboard, expectedGeneration: expectedGeneration)
    }

    /// Write the dictation as a LAZY, host-only promise: `prepareForNewContents(.currentHostOnly)`
    /// keeps it off Universal Clipboard (no broadcast to the user's other devices, and no eager
    /// read by it), the three nspasteboard.org markers are real (empty) data so clipboard managers
    /// can skip the item from its type list alone, and the text itself is supplied by `provider`
    /// only when a process reads it. Only a confirmed publication supplies a generation.
    /// The item retains the provider until it has served the text.
    @discardableResult
    static func writeLazyDictation(provider: DictationPasteProvider, to pasteboard: NSPasteboard,
                                   writer: PasteboardWriter = PasteboardWriter(),
                                   expectedGeneration: Int? = nil) -> PasteboardWriter.Result {
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        for marker in DictationPasteProvider.markerTypes {
            item.setData(Data(), forType: marker)
        }
        return writer.replace([item], on: pasteboard, expectedGeneration: expectedGeneration, hostOnly: true)
    }

    /// The restore decision: restore the prior clipboard only if OUR write is still live, i.e. the
    /// current changeCount equals the one captured right after our write. Pure so the F4 fix is
    /// testable without timers or a real paste.
    static func shouldRestoreClipboard(currentChangeCount: Int, writtenChangeCount: Int) -> Bool {
        currentChangeCount == writtenChangeCount
    }

    /// Test seam for the F4 clipboard-restore round-trip (ClipboardRestoreTests). Forwards to the
    /// private save/restore so tests can exercise the real save→overwrite→restore cycle on a named
    /// pasteboard without reaching `NSPasteboard.general`.
    func savePasteboardForTest(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        savePasteboard(pasteboard)
    }

    func restorePasteboardForTest(_ pasteboard: NSPasteboard, items: [[(NSPasteboard.PasteboardType, Data)]]) {
        restorePasteboard(pasteboard, items: items)
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        TextInserter.snapshotPasteboard(pasteboard)
    }

    /// Every item, every type that yields data, in order. Shared with the clipboard canary.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[(NSPasteboard.PasteboardType, Data)]]) {
        TextInserter.writeBack(items, to: pasteboard)
    }

    /// Write saved clipboard items back. Thread-agnostic (no main-only state): the paste-watch
    /// tap calls it on its own thread.
    @discardableResult
    static func writeBack(_ items: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) -> Bool {
        PasteboardWriter().restore(items, on: pasteboard).generation != nil
    }

    /// A queued paste must finish consuming its dictation before another explicit copy can
    /// replace it. This follows the current borrow's receipt policy, without waiting out its
    /// after-read timer. An untrusted/own read or an eager remote write is not a receipt.
    var isWaitingForClipboardConsumption: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !hasDeferredInsertion else { return true }
        guard let pending = pendingRestore else { return false }
        if pending.pasteVerdict == PasteOutcomeVerdict.confirmed.rawValue { return false }
        guard pending.provider != nil, pending.firstReadAt != nil,
              pending.restoreAfterRead != nil, pending.earlyOffReason == nil else { return true }
        // A reader may have started since the earlier receipt; never silently keep trusting
        // that receipt when the current reader policy now says it is uncertain.
        return clipboardTrustReason() != nil
    }

    /// An explicit user copy supersedes a consumed automatic dictation borrow. Consumers
    /// supply raw representations; this API does not depend on the history feature.
    @discardableResult
    func replaceClipboardForUser(with items: [NSPasteboardItem]) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !items.isEmpty, !isWaitingForClipboardConsumption else { return false }
        clipboardCanary?.abort(reason: "explicit-user-copy")
        userPasteGate.claim(token: nil)
        let before = pasteboard.changeCount
        let saved: PasteboardAccess.Snapshot?
        if let pending = pendingRestore, pending.writtenChangeCount == before {
            saved = pending.savedItems
        } else {
            // This is an explicit replacement, so unreadable/oversized existing data
            // does not prohibit the user's copy. Preserve it for failure recovery when possible.
            saved = try? captureClipboardSnapshot(pasteboard, Self.maxRestorableClipboardBytes)
        }
        let result = pasteboardWriter.replace(items, on: pasteboard, expectedGeneration: before)
        guard result.generation != nil else {
            if let saved { _ = pasteboardWriter.recover(saved, after: result, on: pasteboard) }
            return false
        }
        pendingBackstop?.cancel()
        pendingBackstop = nil
        pendingRestore?.pasteCheck?.cancel()
        pendingRestore = nil
        lastBorrowEndedAt = uptime()
        return true
    }

    /// Replay the user's selected clipboard verbatim, with no text-pipeline pass.
    /// Remote viewers use their own clipboard synchronization; let the user paste
    /// there explicitly instead of guessing when rich content has crossed hosts.
    @discardableResult
    func pasteCurrentClipboard(expectedChangeCount: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pasteboard.changeCount == expectedChangeCount,
              !isSecureInputActive(), !isRemoteDesktopFrontmost() else { return false }
        if let postPasteShortcut { postPasteShortcut(); return true }
        guard let key = vKeyCode(), let events = Self.makeSyntheticPasteEvents(vKey: key) else { return false }
        events.0.post(tap: .cghidEventTap)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.01) {
            events.1.post(tap: .cghidEventTap)
        }
        return true
    }

    private func simulatePaste(_ text: String, expectedChangeCount: Int) {
        // For remote desktop apps, use AppleScript keystroke targeted at the process.
        // Remote desktop apps capture raw HID events and forward them to the remote
        // machine. CGEvent.post sends through HID, so Cmd+V becomes a raw "V" keypress.
        // AppleScript keystroke routes through the app's NSEvent dispatch, where its
        // local Cmd+V handler triggers clipboard sync + paste on the remote side.
        //
        // Delay the Cmd+V by 400ms so the remote clipboard has time to sync from
        // the local clipboard before the paste fires. Without this delay, Splashtop
        // pastes the OLD clipboard content on the remote (sync hadn't completed yet).
        if isRemoteDesktopFrontmost() {
            guard let pid = frontmostPIDProvider() else {
                remoteInsertionFailed(text, message: "The remote desktop is no longer available.")
                return
            }
            let bundleID = frontmostBundleIDProvider()
            let focusedElement = currentFocusedElement()
            let sentProfile = frontmostProfile()
            let attempt = activeInsertionAttempt
            attempt?.deferred = true
            outcomeDeferred = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { attempt?.finish(.deliveryFailed); return }
                let focusUnchanged = focusedElement.map { expected in
                    self.currentFocusedElement().map { CFEqual(expected, $0) } ?? false
                } ?? true
                guard self.frontmostPIDProvider() == pid,
                      self.frontmostBundleIDProvider() == bundleID,
                      self.pasteboard.changeCount == expectedChangeCount,
                      self.insertionDestinationIsCurrent(attempt: attempt), focusUnchanged else {
                    // A rapid second dictation owns the newer clipboard and its own paste.
                    // Do not paste any newer user copy or send input into changed focus.
                    self.remoteInsertionFailed(text, message: "The clipboard or focused field changed before the remote paste. SpeakFree did not send the paste shortcut.",
                                               lateFor: sentProfile, attempt: attempt)
                    return
                }
                let source = """
                    tell application "System Events"
                        tell (first process whose unix id is \(pid))
                            keystroke "v" using command down
                        end tell
                    end tell
                """
                if let error = self.executeAppleScript(source) {
                    Self.logAppleEventsDenialHint(error)
                    DiagnosticLogger.shared.log("TextInserter: remote paste failed; offering recovery")
                    self.remoteInsertionFailed(text, message: Self.remoteScriptFailureMessage(error),
                                               lateFor: sentProfile, attempt: attempt)
                } else {
                    self.recordDirect(.remotePasted, multiLine: AppCompatibility.hasLineBreak(text),
                                      profile: sentProfile)
                    attempt?.finish(.remotePasted)
                }
            }
            return
        }

        if let postPasteShortcut {
            guard validateClipboardBeforePaste(text, expectedChangeCount: expectedChangeCount) else { return }
            postPasteShortcut()
            return
        }
        guard let vKey = vKeyCode(),
              let (keyDown, keyUp) = TextInserter.makeSyntheticPasteEvents(vKey: vKey) else {
            remoteInsertionFailed(text, message: "macOS could not create the paste shortcut. Your dictation was not sent.",
                                  title: "Check your dictation")
            return
        }

        guard validateClipboardBeforePaste(text, expectedChangeCount: expectedChangeCount) else { return }
        keyDown.post(tap: .cghidEventTap)
        // Schedule the key-up on a background queue, not main: if the main thread is stalled the
        // synthetic Cmd+V key-DOWN would otherwise be left held (Command stuck) until main drains,
        // so post the key-up independently of main-thread health (AX-F).
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Check after route/event setup as well as publication. AppKit cannot atomically
    /// couple this check to another application's eventual handling of the key event.
    private func validateClipboardBeforePaste(_ text: String, expectedChangeCount: Int) -> Bool {
        let clipboardChanged = pasteboard.changeCount != expectedChangeCount
        let destinationChanged = !insertionDestinationIsCurrent()
        guard clipboardChanged || destinationChanged else { return true }
        // Only retire the operation whose shortcut is being abandoned; a newer borrow
        // has its own snapshot, timer and gate token. Never write an old snapshot here.
        if let pending = pendingRestore, pending.writtenChangeCount == expectedChangeCount {
            pendingBackstop?.cancel()
            if destinationChanged && !clipboardChanged {
                // No shortcut was sent; restore only our exact temporary generation.
                performPendingRestore(pasteboard: pasteboard, trigger: "destination-changed")
            } else {
                if let token = pending.gateToken { userPasteGate.claim(token: token) }
                pendingBackstop = nil
                pending.pasteCheck?.cancel()
                pendingRestore = nil
                lastBorrowEndedAt = uptime()
            }
        }
        remoteInsertionFailed(text,
            message: (clipboardChanged ? "The clipboard changed before the paste." : "The original destination could not be confirmed before the paste.")
                + " Speakfree did not send the paste shortcut.",
            title: "Check your dictation")
        return false
    }

    /// speakfree's own Cmd+V, marked (`SyntheticEventMarker`) so the paste-watch tap never takes
    /// it for the user's. Built here, not inline, so a test can check the marking.
    static func makeSyntheticPasteEvents(vKey: CGKeyCode,
                                         source: CGEventSource? = CGEventSource(stateID: .hidSystemState))
        -> (CGEvent, CGEvent)? {
        guard let source,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        SyntheticEventMarker.mark(keyDown)
        SyntheticEventMarker.mark(keyUp)
        return (keyDown, keyUp)
    }

    /// Returns the key code for 'v', using a cached value when the input source hasn't changed.
    private func vKeyCode() -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let sourceID = (TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }) ?? ""

        if sourceID == cachedInputSourceID, let cached = cachedVKeyCode {
            return cached
        }

        let code = keyCode(for: "v", in: inputSource)
        cachedInputSourceID = sourceID
        cachedVKeyCode = code
        return code
    }

    private func keyCode(for character: Character, in inputSource: TISInputSource) -> CGKeyCode? {
        guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return nil }

        let keyboardLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(layoutBytes))
        let keyboardType = UInt32(LMGetKbdType())
        let wanted = String(character).lowercased()

        for keyCode in 0..<128 {
            for modifierState: UInt32 in [0, UInt32(shiftKey >> 8)] {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var actualLength: Int = 0

                let status = UCKeyTranslate(
                    keyboardLayout, UInt16(keyCode), UInt16(kUCKeyActionDisplay),
                    modifierState, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &actualLength, &chars
                )
                guard status == noErr else { continue }

                let produced = String(utf16CodeUnits: chars, count: actualLength).lowercased()
                if produced == wanted { return CGKeyCode(keyCode) }
            }
        }
        return nil
    }
}
