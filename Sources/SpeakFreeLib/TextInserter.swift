// ai-suggestion:unverified · session:019fecb2-8ac5-7423-90a3-d70aac039387 · 2026-08-10
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

    /// Seam for the pasteboard all clipboard paths write to (`pasteViaClipboard`,
    /// `copyToClipboard`, `secureInputClipboardFallback`). Production stays on
    /// `.general`; tests inject a named pasteboard so the suite never touches the
    /// developer's real clipboard (test-host-safety rule, PLAN.md P-1).
    var pasteboard: NSPasteboard = .general

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

    /// What to hand back and the guard that says it is still safe to. `savedItems` is the user's
    /// clipboard from BEFORE the first un-restored dictation paste (never re-snapshotted while a
    /// restore is pending AND the clipboard is still our text, or a rapid second dictation would
    /// save dictation-1's text as the "original"). `writtenChangeCount` tracks the LATEST write.
    struct PendingClipboardRestore {
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
        var writtenChangeCount: Int
    }

    /// Which restore policy the frontmost app gets.
    enum PasteRoute: String { case remote, electron, native }

    private var pendingRestore: PendingClipboardRestore?
    private var pendingBackstop: DispatchWorkItem?

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
    /// 2026-07-29, Michael: "additional spaces should be tracked so that you are able to see
    /// them." Spacing damage is invisible in the recordings corpus — the `.txt` sidecar holds
    /// only the dictation, while the defect lives in the JOIN, which exists solely in the target
    /// app. Nothing downstream could count these, so a run of spurious leading spaces was only
    /// ever visible to Michael. This is the missing observation.
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
    // Returns true if text was pasted, false if focus couldn't be restored (text copied to clipboard instead).
    //
    // Secure Input guard — covers ALL insertion paths (AX, keystroke, clipboard, refocus).
    // When a password field (or any app with Secure Event Input) is active, we must not
    // inject keystrokes or paste. The text is dictated-into-a-password-field — the most
    // sensitive case — so the fallback uses the CONCEALED clipboard path (audit AR-1):
    // org.nspasteboard.ConcealedType/TransientType markers + auto-clear, so clipboard-history
    // tools skip it and the plaintext doesn't linger. The caller is notified via onFocusLost.
    @discardableResult
    func insert(text: String, refocusing element: AXUIElement? = nil, onFocusLost: (() -> Void)? = nil) -> Bool {
        if isSecureInputActive() {
            DiagnosticLogger.shared.log("TextInserter: Secure Input is active — concealed clipboard fallback instead of inserting")
            secureInputClipboardFallback(text)
            onSecureInputFallback?(text, .secureInput)
            onFocusLost?()
            return false
        }

        if let element = element {
            let currentElement = currentFocusedElement()
            let sameElement = currentElement.map { CFEqual($0, element) } ?? false

            if !sameElement {
                let refocused = refocusElement(element)
                if refocused {
                    // Use non-blocking delay for focus to settle, then insert.
                    // Re-check secure input inside the closure: the system could enable it
                    // during the 150ms focus-settle window (e.g. user tabs into a password field).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self else { return }
                        if self.isSecureInputActive() {
                            DiagnosticLogger.shared.log("TextInserter: Secure Input became active during focus-settle — concealed clipboard fallback")
                            self.secureInputClipboardFallback(text)
                            self.onSecureInputFallback?(text, .secureInput)
                            onFocusLost?()
                            return
                        }
                        // Try direct AX insertion on the refocused element first. This targets
                        // `element` specifically, so it is safe even if focus moved.
                        let axInserted: Bool
                        if let directAXInsert = self.directAXInsert {
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
                                let setResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
                                switch Self.axSetOutcome(setResult) {
                                case .inserted:
                                    axInserted = true
                                case .concealClipboard:
                                    DiagnosticLogger.shared.log("TextInserter: refocus AX set timed out (may have committed) — concealed clipboard fallback instead of blind paste")
                                    self.secureInputClipboardFallback(text)
                                    onFocusLost?()
                                    return
                                case .fallbackToKeystrokes, .retryViaPaste:
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
                        if axInserted { return }

                        // AX insertion into the intended element failed. Before blind-pasting Cmd+V
                        // into whatever is frontmost, re-verify focus is STILL the element we
                        // refocused: focus can move during the 150ms settle (TOCTOU), and a paste
                        // would then land in the wrong app. If it moved, conceal-copy the text and
                        // notify instead of pasting (AX-C).
                        //
                        // I2: conceal ONLY when the re-query affirmatively returns a DIFFERENT
                        // element. A nil result means the AX query couldn't determine focus (the
                        // 0.5s process cap or a flaky WindowServer read), NOT that focus moved — the
                        // old `?? false` treated nil as "moved" and concealed a paste that should
                        // have proceeded, booking a phantom success. nil now falls through to paste.
                        let focusMovedAway = self.currentFocusedElement().map { !CFEqual($0, element) } ?? false
                        if focusMovedAway {
                            DiagnosticLogger.shared.log("TextInserter: focus moved during settle — concealed clipboard fallback instead of blind paste")
                            self.secureInputClipboardFallback(text)
                            onFocusLost?()
                            return
                        }
                        // Fall back to clipboard paste (through the test seam so a unit test
                        // reaching this closure can never fire a real Cmd+V — PLAN.md P-1).
                        (self.performInsertion ?? self.pasteViaClipboard)(text)
                    }
                    return true
                } else {
                    copyToClipboard(text)
                    onFocusLost?()
                    return false
                }
            } else {
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

    private static func queryFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
        guard result == .success, let element = elementRef else { return nil }
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }

    private func pasteText(_ text: String) {
        // Note: Secure Input is checked at insert() — the entry point for all paths — so it
        // is guaranteed inactive by the time pasteText() is reached.
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let isRemote = isRemoteDesktopFrontmost()
        let isBroken = shouldUseClipboardPaste()
        DiagnosticLogger.shared.log("TextInserter: inserting \(text.count) chars into \(frontApp) (remoteDesktop=\(isRemote), brokenApp=\(isBroken))")

        // Remote desktop: type via AppleScript keystroke (clipboard sync unreliable)
        if isRemote {
            DiagnosticLogger.shared.log("TextInserter: using AppleScript keystroke (remote desktop)")
            typeViaAppleScript(text)
            return
        }

        // Electron / contenteditable apps: CGEvent unicode is slow or mangled.
        // Use clipboard paste for instant insertion regardless of text length.
        if isBroken {
            DiagnosticLogger.shared.log("TextInserter: using clipboard paste (Electron/broken app)")
            pasteViaClipboard(text)
            return
        }

        // Try direct AX text insertion first — no clipboard involvement
        switch insertViaAccessibility(text) {
        case .inserted:
            DiagnosticLogger.shared.log("TextInserter: used AX insertion")
            return
        case .concealClipboard:
            // L4: the AX set timed out under the 0.5s cap — it may have COMMITTED. Retyping via
            // keystrokes (or blind-pasting) would duplicate it, so conceal-copy the text and fire
            // the auto-clear notify instead, mirroring the Secure-Input fallback.
            DiagnosticLogger.shared.log("TextInserter: AX insertion timed out (may have committed) — concealed clipboard fallback instead of retyping")
            secureInputClipboardFallback(text)
            onSecureInputFallback?(text, .axTimeoutMayHaveCommitted)
            return
        case .retryViaPaste:
            // The AX set reported success but the field verifiably did NOT grow — provable
            // non-insertion (distinct from the timeout above). A real Cmd+V paste inserts the
            // text inline. Concealing without pasting was the Chrome silent-drop bug.
            DiagnosticLogger.shared.log("TextInserter: AX insertion dropped silently (field did not grow) — clipboard paste")
            pasteViaClipboard(text)
            return
        case .fallbackToKeystrokes:
            break
        }

        // Try typing via CGEvent unicode — works in most apps
        if typeViaKeyEvents(text) {
            DiagnosticLogger.shared.log("TextInserter: used CGEvent unicode typing")
            return
        }

        // Last resort: clipboard-based paste
        DiagnosticLogger.shared.log("TextInserter: using clipboard paste (fallback)")
        pasteViaClipboard(text)
    }

    /// Type text into the frontmost app via AppleScript keystroke.
    /// Used for remote desktop apps where clipboard sync is unreliable.
    private func typeViaAppleScript(_ text: String) {
        // Multi-line text is slow and lossy as per-line keystrokes on remote desktop.
        // Fall back to clipboard which remote desktop apps sync correctly.
        if text.contains("\n") || text.contains("\r") {
            pasteViaClipboard(text)
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier  // target by PID — process name can be ambiguous
        // Escape double quotes and backslashes for AppleScript
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: """
            tell application "System Events"
                tell (first process whose unix id is \(pid))
                    keystroke "\(escaped)"
                end tell
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            Self.logAppleEventsDenialHint(error)
            DiagnosticLogger.shared.log("TextInserter: AppleScript keystroke failed: \(error) — falling back to clipboard")
            pasteViaClipboard(text)
        }
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
    enum AXSetOutcome: Equatable { case inserted, fallbackToKeystrokes, concealClipboard, retryViaPaste }

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

    /// Insert text directly via the Accessibility API. Returns the three-way `AXSetOutcome` so the
    /// caller can distinguish a clean rejection (safe to retype) from a timeout that may have
    /// committed (must NOT retype — conceal instead). See `axSetOutcome`.
    private func insertViaAccessibility(_ text: String) -> AXSetOutcome {
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
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
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

    /// Remote desktop apps that don't properly forward CGEvent unicode key events.
    private static let remoteDesktopBundleIDs: Set<String> = [
        "com.splashtop.stp.macosx",          // Splashtop Personal
        "com.splashtop.Splashtop-Streamer",  // Splashtop Streamer
        "com.splashtop.PersonalBusiness",    // Splashtop Business
        "com.splashtop.streamer",
        "com.microsoft.rdc.macos",           // Microsoft Remote Desktop
        "com.microsoft.rdc.osx",
        "com.teamviewer.TeamViewer",         // TeamViewer
        "com.parallels.desktop.console",     // Parallels
        "com.vmware.fusion",                 // VMware Fusion
        "com.realvnc.vncviewer",             // RealVNC
        "com.citrix.receiver.icaviewer",     // Citrix
        "com.parsec-cloud.parsec",           // Parsec
        "com.moonlight-stream.Moonlight",    // Moonlight
    ]

    func isRemoteDesktopFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        if Self.remoteDesktopBundleIDs.contains(bundleID) { return true }
        // Fuzzy match for apps with variant bundle IDs
        let lower = bundleID.lowercased()
        let remoteKeywords = ["splashtop", "teamviewer", "parsec", "moonlight", "vnc", "remotedesktop"]
        return remoteKeywords.contains(where: { lower.contains($0) })
    }

    /// Apps that should receive text via clipboard paste rather than CGEvent unicode typing.
    /// Covers Electron apps (where synthetic key events are slow or mangled) and
    /// contenteditable web apps in browsers (Google Docs etc.).
    private static let clipboardPasteApps: Set<String> = [
        // --- Electron / CEF apps (CGEvent typing is slow — clipboard paste is instant) ---
        "org.whispersystems.signal-desktop",   // Signal
        "com.tinyspeck.slackmacgap",           // Slack
        "com.microsoft.VSCode",                // VS Code
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",       // Cursor
        "com.hnc.Discord",                     // Discord
        "com.hnc.Discord.ptb",
        "com.hnc.Discord.canary",
        "notion.id",                           // Notion
        "com.linear",                          // Linear
        "com.figma.Desktop",                   // Figma
        "com.spotify.client",                  // Spotify
        "com.github.GitHubClient",             // GitHub Desktop
        "com.1password.1password",             // 1Password
        "md.obsidian",                         // Obsidian
        "com.superhuman.superhuman",           // Superhuman (already caught by fuzzy match, but explicit)
        "com.microsoft.teams2",                // Teams
        "us.zoom.xos",                         // Zoom (chat)
        "com.loom.desktop",                    // Loom
        "com.openai.codex",                    // Codex/ChatGPT desktop contenteditable
        "com.openai.chat",                     // ChatGPT Classic
        // Claude for Desktop (2026-07-28). Electron, and its composer accepts
        // kAXSelectedText as SETTABLE — so insertViaAccessibility returned .inserted
        // and the text never appeared. Proven from the 2026-07-26 log: the same
        // 188-char dictation failed three times into Claude via AX, then landed
        // first try in Signal via clipboard paste.
        "com.anthropic.claudefordesktop",      // Claude
    ]

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

    static func prefersClipboardPaste(bundleID: String) -> Bool {
        let normalizedBundleID = bundleID.lowercased()
        if clipboardPasteApps.contains(where: { $0.lowercased() == normalizedBundleID }) {
            return true
        }
        return normalizedBundleID.contains("superhuman")
    }

    /// The AX-unreliable contenteditable class: every known/probed Electron or CEF app, plus
    /// explicit clipboard-routed editors. These apps already cannot use AX insertion reliably;
    /// live focused-element/window reads are optional enrichment and must not contend with the
    /// hotkey path. Native apps and browsers keep context unless separately classified.
    static func shouldAvoidLiveWindowContext(bundleID: String?, bundleURL: URL?) -> Bool {
        guard let bundleID else { return false }
        if prefersClipboardPaste(bundleID: bundleID) { return true }
        return isChromiumEmbedded(bundleID: bundleID, bundleURL: bundleURL)
    }

    /// Chromium-embedding frameworks. An app shipping one of these renders its text fields
    /// as web contenteditables, which is what makes both synthetic typing and AX writes
    /// unreliable — the exact class the hand-maintained list above was approximating.
    private static let embeddedChromiumFrameworks = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
    ]

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

    private func shouldUseClipboardPaste() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return false }

        // Known list, then a generic embedded-Chromium probe of the live bundle.
        if Self.prefersClipboardPaste(app: frontApp) { return true }

        // Browsers render their text fields as web contenteditables/textareas. Chromium accepts an
        // AX SelectedText write, reports success, and applies NOTHING — and Chrome's own bundle is
        // not caught by the embedded-Chromium probe (it ships "Google Chrome Framework", not the
        // "Electron"/"Chromium Embedded Framework" the probe looks for). So proactively route ALL
        // browser content to clipboard paste. This covers web contenteditables in general, not only
        // Google Docs/Sheets/Slides (the previous narrow window-title check), and it is safe for the
        // browser's own chrome-UI: Cmd+V works in the address bar too. (2026-08-12 Chrome silent-drop.)
        if Self.isBrowser(bundleID: bundleID) { return true }

        return false
    }

    /// Is this bundle ID a known browser? Covers Chromium forks, Safari, and Firefox. Static + pure
    /// (lowercases internally) so the browser→clipboard-paste routing is unit-testable without a live
    /// frontmost app.
    static func isBrowser(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        let browsers = [
            "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
            "company.thebrowser.browser",  // Arc
            "com.brave.browser", "com.microsoft.edgemac",
            "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "com.microsoft.edgemac.dev", "com.microsoft.edgemac.beta",
            "com.kagi.kagimacos",  // Orion
        ]
        return browsers.contains(where: { lower.contains($0) })
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
    private func typeViaKeyEvents(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for op in Self.keystrokeOps(for: text) {
            switch op {
            case .shiftReturn:
                // Newline policy 2b / Option B (Michael, 2026-06-10): a spoken "new line" is a
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

                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }

        return true
    }

    /// Clipboard-based insertion with safety check and transient marking.
    ///
    /// Safety check: if the clipboard holds large binary data (images, files > 512 KB),
    /// fall back to CGEvent typing rather than clobbering precious clipboard contents.
    ///
    /// Transient marking: writes org.nspasteboard.TransientType + ConcealedType so
    /// clipboard managers (Maccy, Raycast, Paste) skip recording the dictated text.
    /// All pending-restore state (pendingRestore, pendingBackstop) is touched only from the main
    /// thread — every production caller reaches here on main (finalize/reprocess/secure-input/
    /// focus-settle) and the backstop closure is main-dispatched. The precondition turns a future
    /// off-main caller (e.g. FinalizePipeline.run with a real inserter) into a crash instead of a
    /// silent data race on the shared state.
    private func pasteViaClipboard(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let pasteboard = self.pasteboard
        let route: PasteRoute = isRemoteDesktopFrontmost() ? .remote
            : (shouldUseClipboardPaste() ? .electron : .native)

        // Saved-original: reuse the pending snapshot ONLY while our last dictation write is still
        // the live clipboard (else re-snapshotting would save that dictation's text). If anything
        // else wrote since — the user copied via right-click/pbcopy/a Copy button, no Command press
        // — the pending snapshot is stale, so re-snapshot the user's fresh copy instead.
        let reuse = TextInserter.shouldReusePendingSnapshot(
            pendingWrittenChangeCount: pendingRestore?.writtenChangeCount,
            currentChangeCount: pasteboard.changeCount)
        let savedItems = reuse ? pendingRestore!.savedItems : savePasteboard(pasteboard)
        let clipboardByteSize = savedItems.reduce(0) { total, item in
            total + item.reduce(0) { $0 + $1.1.count }
        }
        if !Self.canSafelySaveClipboard(byteSize: clipboardByteSize) {
            DiagnosticLogger.shared.log(
                "TextInserter: clipboard has \(clipboardByteSize / 1024)KB of data — "
                + "falling back to CGEvent to avoid clobbering it"
            )
            _ = typeViaKeyEvents(text)
            return
        }

        // Write the dictated text (transient/concealed-marked) and snapshot changeCount AFTER the
        // write. A `clearContents()` + `writeObjects()` sequence advances `changeCount` by exactly
        // ONE generation, so the restore guard compares against THIS returned value (equality).
        let writtenChangeCount = TextInserter.writeTransientString(text, to: pasteboard)

        simulatePaste()

        pendingRestore = PendingClipboardRestore(savedItems: savedItems,
                                                 writtenChangeCount: writtenChangeCount)
        let delay = TextInserter.restoreBackstopDelay(route: route)
        DiagnosticLogger.shared.log(
            "TextInserter: clipboard paste route=\(route.rawValue) len=\(text.count) "
            + "clip=\(clipboardByteSize / 1024)KB backstop=\(String(format: "%.1f", delay))s")
        armRestoreBackstop(pasteboard: pasteboard, delay: delay)
    }

    private func armRestoreBackstop(pasteboard: NSPasteboard, delay: TimeInterval) {
        pendingBackstop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performPendingRestore(pasteboard: pasteboard)
        }
        pendingBackstop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Restore the saved clipboard (once) when the backstop fires, and log the outcome. Restores
    /// only if OUR latest write is still live; if the user or another app wrote in the meantime,
    /// their content is left alone.
    private func performPendingRestore(pasteboard: NSPasteboard) {
        pendingBackstop = nil
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        let restored = TextInserter.shouldRestoreClipboard(
            currentChangeCount: pasteboard.changeCount, writtenChangeCount: pending.writtenChangeCount)
        if restored {
            restorePasteboard(pasteboard, items: pending.savedItems)
        }
        DiagnosticLogger.shared.log("TextInserter: clipboard restore restored=\(restored)")
    }

    private func copyToClipboard(_ text: String) {
        // Focus-lost fallback: mark the write Concealed + Transient exactly like the two sibling
        // clipboard paths (pasteViaClipboard / secureInputClipboardFallback) so clipboard-history
        // tools skip recording the dictated text (AX-D).
        TextInserter.writeTransientString(text, to: pasteboard)
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
    /// case can auto-retry the insertion once Secure Input clears (Michael 2026-08-12).
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
    func secureInputClipboardFallback(_ text: String) {
        let pasteboard = self.pasteboard
        pasteboard.clearContents()

        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])

        let writtenChangeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + secureInputClipboardClearDelay) {
            // Only clear if our concealed write is still the live clipboard content.
            if pasteboard.changeCount == writtenChangeCount {
                pasteboard.clearContents()
                DiagnosticLogger.shared.log("TextInserter: auto-cleared concealed Secure-Input clipboard text")
            }
        }
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

    /// One tick of the Secure-Input retry loop (Michael 2026-08-12: "a little box that
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

    /// Write `text` to `pasteboard` exactly as `pasteViaClipboard` does (clearContents +
    /// transient/concealed-marked writeObjects) and return the `changeCount` AFTER the write.
    ///
    /// Extracted so the changeCount contract that drives clipboard restore is unit-testable on a
    /// named (non-general) pasteboard without simulating a real Cmd+V. The key invariant the F4
    /// regression test pins: this whole sequence advances `changeCount` by exactly ONE, so the
    /// restore guard must compare against THIS returned value (equality), never `before + 2`.
    @discardableResult
    static func writeTransientString(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
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
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[(NSPasteboard.PasteboardType, Data)]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    private func simulatePaste() {
        guard let vKey = vKeyCode() else { return }

        // For remote desktop apps, use AppleScript keystroke targeted at the process.
        // Remote desktop apps capture raw HID events and forward them to the remote
        // machine. CGEvent.post sends through HID, so Cmd+V becomes a raw "V" keypress.
        // AppleScript keystroke routes through the app's NSEvent dispatch, where its
        // local Cmd+V handler triggers clipboard sync + paste on the remote side.
        //
        // Delay the Cmd+V by 400ms so the remote clipboard has time to sync from
        // the local clipboard before the paste fires. Without this delay, Splashtop
        // pastes the OLD clipboard content on the remote (sync hadn't completed yet).
        if isRemoteDesktopFrontmost(), let app = NSWorkspace.shared.frontmostApplication {
            let pid = app.processIdentifier  // target by PID — process name can be ambiguous
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let script = NSAppleScript(source: """
                    tell application "System Events"
                        tell (first process whose unix id is \(pid))
                            keystroke "v" using command down
                        end tell
                    end tell
                """)
                var error: NSDictionary?
                script?.executeAndReturnError(&error)
                if let error = error {
                    Self.logAppleEventsDenialHint(error)
                    DiagnosticLogger.shared.log("TextInserter: AppleScript paste failed: \(error)")
                }
            }
            return
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        // Schedule the key-up on a background queue, not main: if the main thread is stalled the
        // synthetic Cmd+V key-DOWN would otherwise be left held (Command stuck) until main drains,
        // so post the key-up independently of main-thread health (AX-F).
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) {
            keyUp.post(tap: .cghidEventTap)
        }
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
