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
                  let rangeValue = rangeRef else { semaphore.signal(); return }

            var range = CFRange()
            // swiftlint:disable:next force_cast
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
        // Try direct AX text insertion first — no clipboard involvement
        if insertViaAccessibility(text) {
            return
        }

        // Try typing via CGEvent unicode — works in Electron apps without clipboard
        if typeViaKeyEvents(text) {
            return
        }

        // Last resort: clipboard-based paste
        pasteViaClipboard(text)
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
        // Check changeCount before restoring — if user copied something new, don't overwrite it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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

        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        // Non-blocking delay between key down and up — some apps need time to register the paste command
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
