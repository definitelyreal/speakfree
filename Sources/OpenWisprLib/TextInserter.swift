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

    /// Check if a space should be prepended before inserting text.
    /// Returns true if the character before the cursor is a non-whitespace character.
    /// Runs AX queries with a 300ms timeout to avoid blocking on slow apps (Electron).
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

            let cursorPos = range.location
            guard cursorPos <= fullText.count,
                  let index = fullText.index(fullText.startIndex, offsetBy: cursorPos, limitedBy: fullText.endIndex) else { semaphore.signal(); return }

            let charBefore = fullText[fullText.index(before: index)]
            result = !charBefore.isWhitespace && !charBefore.isNewline
            semaphore.signal()
        }

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
                        // Try direct AX insertion on the refocused element first
                        var settable: DarwinBoolean = false
                        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
                           settable.boolValue,
                           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                            return
                        }
                        // Fall back to clipboard paste
                        self.pasteViaClipboard(text)
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
        if insertViaAccessibility(text) {
            DiagnosticLogger.shared.log("TextInserter: used AX insertion")
            return
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
            DiagnosticLogger.shared.log("TextInserter: AppleScript keystroke failed: \(error) — falling back to clipboard")
            pasteViaClipboard(text)
        }
    }

    /// Insert text directly via the Accessibility API. Returns true on success.
    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let element = currentFocusedElement() else { return false }

        // Check if the element supports setting the SelectedText attribute
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }

        // Set the selected text — this replaces current selection or inserts at cursor
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return result == .success
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
    ]

    private func shouldUseClipboardPaste() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }

        // Exact match against known Electron / clipboard-paste apps
        if Self.clipboardPasteApps.contains(bundleID) { return true }

        // Fuzzy match for variants (e.g. "superhuman.superhuman.staging")
        let lower = bundleID.lowercased()
        if lower.contains("superhuman") { return true }

        // Browser-agnostic check: Google Docs/Sheets/Slides in any browser
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
                i += 1
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
        let pasteboard = NSPasteboard.general

        // Safety check: measure existing clipboard binary footprint
        let clipboardByteSize = pasteboard.pasteboardItems?.reduce(0) { total, item in
            total + item.types.reduce(0) { $0 + (item.data(forType: $1)?.count ?? 0) }
        } ?? 0
        if clipboardByteSize > 512_000 {
            DiagnosticLogger.shared.log(
                "TextInserter: clipboard has \(clipboardByteSize / 1024)KB of data — "
                + "falling back to CGEvent to avoid clobbering it"
            )
            _ = typeViaKeyEvents(text)
            return
        }

        let savedItems = savePasteboard(pasteboard)
        let changeCountBeforePaste = pasteboard.changeCount

        pasteboard.clearContents()

        // Transient markers tell clipboard managers to skip recording this write.
        // org.nspasteboard.TransientType = "don't persist"
        // org.nspasteboard.ConcealedType = "don't show in history"
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])

        simulatePaste()

        // Restore after a generous delay to let the target app consume the paste.
        // Remote desktop paste is delayed 400ms + needs clipboard sync to remote,
        // so give it extra time before restoring.
        let restoreDelay: Double = isRemoteDesktopFrontmost() ? 3.0 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // changeCount increments on every clipboard change. We set it once (clearContents + setString).
            // If it changed again since then, the user or another app wrote to the clipboard — don't restore.
            let expectedChangeCount = changeCountBeforePaste + 2  // clearContents + setString
            if pasteboard.changeCount == expectedChangeCount {
                self.restorePasteboard(pasteboard, items: savedItems)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        let pasteboard = NSPasteboard.general
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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
