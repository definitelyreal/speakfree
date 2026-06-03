import AppKit
import Foundation
import Cocoa
import Carbon.HIToolbox
import ApplicationServices

class TextInserter {
    // Cache the 'v' key code — only changes if keyboard layout changes
    private var cachedVKeyCode: CGKeyCode?
    private var cachedInputSourceID: String?

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
    @discardableResult
    func insert(text: String, refocusing element: AXUIElement? = nil, onFocusLost: (() -> Void)? = nil) -> Bool {
        if let element = element {
            let currentElement = currentFocusedElement()
            let sameElement = currentElement.map { CFEqual($0, element) } ?? false

            if !sameElement {
                let refocused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
                if refocused {
                    // Use non-blocking delay for focus to settle, then insert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
                pasteText(text)
                return true
            }
        } else {
            pasteText(text)
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
        // Refuse to insert text when Secure Input is active (e.g. password fields).
        // CGEventTap is not disabled — the tap re-enables itself via kCGEventTapDisabled*
        // handling in HotkeyManager. We just skip the insertion so passwords stay safe.
        if IsSecureEventInputEnabled() {
            DiagnosticLogger.shared.log("TextInserter: skipping insertion — Secure Input is enabled (password field?)")
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let isRemote = isRemoteDesktopFrontmost()
        let isBroken = isElectronApp()
        DiagnosticLogger.shared.log("TextInserter: inserting \(text.count) chars into \(frontApp) (remoteDesktop=\(isRemote), brokenApp=\(isBroken))")

        // Remote desktop: type via AppleScript keystroke (clipboard sync unreliable)
        if isRemote {
            DiagnosticLogger.shared.log("TextInserter: using AppleScript keystroke (remote desktop)")
            typeViaAppleScript(text)
            return
        }

        // Broken apps (Superhuman, Google Docs): AX "succeeds" but changes nothing,
        // and CGEvent unicode gets mangled/dropped. Go straight to clipboard paste.
        if isBroken {
            DiagnosticLogger.shared.log("TextInserter: using clipboard paste (broken app)")
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

    /// Check if the frontmost app mangles CGEvent unicode typing.
    /// Covers Superhuman (Electron apostrophe/comma garbling) and Google Docs editors
    /// in any browser (custom contenteditable that ignores synthetic unicode events).
    private func isElectronApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else { return false }
        let brokenApps = [
            "superhuman",
        ]
        if brokenApps.contains(where: { bundleID.contains($0) }) { return true }

        // Browser-agnostic check: look at the frontmost window title via AX.
        // Google Docs/Sheets/Slides set the page title to "<doc name> - Google Docs"
        // (or Sheets/Slides), which appears in the browser's window title.
        if isBrowser(bundleID: bundleID), let title = frontWindowTitle() {
            let lower = title.lowercased()
            if lower.contains("google docs") || lower.contains("google sheets") || lower.contains("google slides") {
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

    /// Insert text by simulating keyboard events with unicode characters.
    /// Works in Electron apps (VS Code, Slack, Discord) without touching the clipboard.
    /// CGEventKeyboardSetUnicodeString handles up to 20 UTF-16 code units per event,
    /// so we chunk the text accordingly.
    private func typeViaKeyEvents(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let utf16 = Array(text.utf16)
        let chunkSize = 20  // max unicode chars per CGEvent
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            let chunk = Array(utf16[index..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }

            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            index = end
        }

        return true
    }

    /// Legacy clipboard-based insertion. Saves and restores clipboard.
    private func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboard(pasteboard)
        let changeCountBeforePaste = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
