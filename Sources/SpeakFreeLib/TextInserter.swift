import AppKit
import Foundation
import Cocoa
import Carbon.HIToolbox
import ApplicationServices

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
        return !lastChar.isWhitespace && !lastChar.isNewline
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

    func shouldPrependSpace(before element: AXUIElement?) -> Bool {
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
            result = !charBefore.isWhitespace && !charBefore.isNewline
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
            onSecureInputFallback?()
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
                            self.onSecureInputFallback?()
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
                                case .fallbackToKeystrokes:
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
            onSecureInputFallback?()
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
    enum AXSetOutcome: Equatable { case inserted, fallbackToKeystrokes, concealClipboard }

    static func axSetOutcome(_ error: AXError) -> AXSetOutcome {
        switch error {
        case .success: return .inserted
        case .cannotComplete: return .concealClipboard
        default: return .fallbackToKeystrokes
        }
    }

    /// Insert text directly via the Accessibility API. Returns the three-way `AXSetOutcome` so the
    /// caller can distinguish a clean rejection (safe to retype) from a timeout that may have
    /// committed (must NOT retype — conceal instead). See `axSetOutcome`.
    private func insertViaAccessibility(_ text: String) -> AXSetOutcome {
        guard let element = currentFocusedElement() else { return .fallbackToKeystrokes }

        // Check if the element supports setting the SelectedText attribute
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return .fallbackToKeystrokes
        }

        // Set the selected text — this replaces current selection or inserts at cursor. No
        // per-element messaging timeout (L4): keep the process-wide 0.5s cap so a stuck target
        // can't hang the main thread; a `.cannotComplete` under that cap routes to conceal, not
        // a duplicating retype.
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return Self.axSetOutcome(result)
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
    ]

    /// Large image clipboards are common while dictating into creative/chat apps. A
    /// 512 KB ceiling forced a 4.6 MB clipboard in Codex back to synthetic Unicode
    /// events, the exact path that intermittently dropped the user's insertion. Keep a
    /// finite cap, but allow ordinary images to be saved and restored around Cmd+V.
    static let maxRestorableClipboardBytes = 16 * 1_024 * 1_024

    static func prefersClipboardPaste(bundleID: String) -> Bool {
        if clipboardPasteApps.contains(bundleID) { return true }
        return bundleID.lowercased().contains("superhuman")
    }

    static func canSafelySaveClipboard(byteSize: Int) -> Bool {
        byteSize <= maxRestorableClipboardBytes
    }

    private func shouldUseClipboardPaste() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }

        // Exact match against known Electron / clipboard-paste apps
        if Self.prefersClipboardPaste(bundleID: bundleID) { return true }

        // Browser-agnostic check: Google Docs/Sheets/Slides in any browser
        let lower = bundleID.lowercased()
        if isBrowser(bundleID: lower), let title = frontWindowTitle() {
            let t = title.lowercased()
            if t.contains("google docs") || t.contains("google sheets") || t.contains("google slides") {
                return true
            }
        }

        return false
    }

    /// Is this bundle ID a known browser? Covers Chromium forks, Safari, and Firefox.
    private func isBrowser(bundleID: String) -> Bool {
        let browsers = [
            "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
            "company.thebrowser.browser",  // Arc
            "com.brave.browser", "com.microsoft.edgemac",
            "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "com.microsoft.edgemac.dev", "com.microsoft.edgemac.beta",
            "com.kagi.kagimacos",  // Orion
        ]
        return browsers.contains(where: { bundleID.contains($0) })
    }

    /// Get the title of the frontmost window via Accessibility API.
    private func frontWindowTitle() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowElement = windowRef else { return nil }
        // swiftlint:disable:next force_cast
        let window = windowElement as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
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
    private func pasteViaClipboard(_ text: String) {
        let pasteboard = self.pasteboard

        // Save FIRST: one materialization serves both the size check and the restore
        // snapshot. Measuring separately via item.data(forType:) read every payload
        // twice — with the 16 MB cap that's up to ~32 MB of main-thread copying at
        // insert time for a large image clipboard.
        let savedItems = savePasteboard(pasteboard)
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
        // ONE generation (clearContents bumps it; the subsequent write stays in that same
        // generation), NOT two. The previous `+2` guard was therefore never satisfied, so the
        // user's clipboard was NEVER restored after a paste insertion. Comparing against the
        // post-write count (equality, the same pattern `secureInputClipboardFallback` uses) makes
        // the restore fire when nothing else touched the clipboard, and skips it if the user or
        // another app wrote in the meantime.
        let writtenChangeCount = TextInserter.writeTransientString(text, to: pasteboard)

        simulatePaste()

        // Restore after a generous delay to let the target app consume the paste.
        // Remote desktop paste is delayed 400ms + needs clipboard sync to remote,
        // so give it extra time before restoring.
        let restoreDelay: Double = isRemoteDesktopFrontmost() ? 3.0 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Only restore if OUR write is still the live clipboard content. If changeCount moved
            // past our write, the user or another app put something on the clipboard — leave it.
            if TextInserter.shouldRestoreClipboard(currentChangeCount: pasteboard.changeCount,
                                                   writtenChangeCount: writtenChangeCount) {
                self.restorePasteboard(pasteboard, items: savedItems)
            }
        }
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

    /// Called when `insert()` falls back to the concealed Secure-Input clipboard path instead of
    /// inserting text directly. Unlike `onFocusLost` (which fires for any focus failure), this
    /// fires ONLY for the secure-input case so the UI can show an auto-clear notification.
    /// Set by the caller (AppDelegate) before each insertion. Reset to nil after each use so it
    /// does not accidentally fire on a later non-secure fallback.
    var onSecureInputFallback: (() -> Void)?

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
