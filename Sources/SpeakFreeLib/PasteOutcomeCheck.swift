// ai-suggestion:unverified · Claude · 2026-09-25 · feat/fast-clipboard
//
// Accessibility outcome check (DESIGN.md approach B). After speakfree's Cmd+V, read the focused
// field: if its character count grew by exactly the pasted text and that text now sits just
// before the caret, the target has read the clipboard and pasted it, so the user's clipboard can
// come back at once. This checks the OUTCOME instead of guessing who read the clipboard first,
// so it stays safe even while a clipboard reader that ignores the markers is running.
//
// Rules (from the design review):
//   - require BOTH the count increase and the string match (a short dictation may already sit
//     before the caret);
//   - every AX call runs off main, on speakfree's OWN application/element refs with a 0.1 s
//     messaging timeout. Never on the system-wide element: a timeout set there changes the
//     process-wide 0.5 s cap (AppDelegate). Never force AXManualAccessibility on Electron apps;
//   - anything unreadable or unconfirmed keeps the timer; a miss only costs speed;
//   - field text is held in memory for the comparison and never logged. Logs carry the verdict.

import AppKit
import ApplicationServices
import Foundation

/// One read of the focused field.
struct PasteFieldSnapshot: Equatable {
    /// Identity of the focused element (focus moving to another field voids the comparison).
    let elementID: AnyHashable
    /// AXNumberOfCharacters (UTF-16 units in practice).
    let characterCount: Int
    let selectionLocation: Int
    let selectionLength: Int
    /// The `precedingLength` UTF-16 units just before the caret, when requested and readable.
    let textBeforeCaret: String?
}

protocol PasteFieldReading {
    /// Read the focused field of app `pid`. nil when it cannot be read. Called off main.
    func read(pid: pid_t, precedingLength: Int) -> PasteFieldSnapshot?
}

enum PasteOutcomeVerdict: String, Equatable {
    /// The pasted text is in the field, just before the caret, and the field grew by it.
    case confirmed
    /// Readable, but the paste has not (visibly) landed yet.
    case notYet = "not-yet"
    /// Cannot be judged (no field, no counts, focus moved). Stop checking; the timer decides.
    case unreadable
}

enum PasteOutcome {
    /// Pure verdict (unit-tested).
    static func verdict(before: PasteFieldSnapshot?, after: PasteFieldSnapshot?, text: String) -> PasteOutcomeVerdict {
        guard let before, let after else { return .unreadable }
        guard before.elementID == after.elementID else { return .unreadable }
        let length = (text as NSString).length
        guard length > 0 else { return .unreadable }
        let expectedGrowth = length - before.selectionLength
        guard after.characterCount - before.characterCount == expectedGrowth,
              after.selectionLength == 0,
              after.selectionLocation == before.selectionLocation + length,
              let preceding = after.textBeforeCaret, preceding == text else {
            return .notYet
        }
        return .confirmed
    }

    /// When to look after the paste keystroke (seconds). Native apps answer on the first look;
    /// Electron commits through its renderer and needs a few. After the last look the timer decides.
    static let defaultDelays: [TimeInterval] = [0.02, 0.05, 0.1, 0.18, 0.3, 0.5, 0.8, 1.2]
}

/// One paste's check. Created on main; all reads happen on `queue`, in order.
final class PasteOutcomeCheck {
    private let text: String
    private let pid: pid_t
    private let reader: PasteFieldReading
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cancelled = false
    private var before: PasteFieldSnapshot?

    init(text: String, pid: pid_t, reader: PasteFieldReading, queue: DispatchQueue) {
        self.text = text
        self.pid = pid
        self.reader = reader
        self.queue = queue
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Any thread. Stop checking (the borrow ended another way).
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// Main thread, BEFORE the paste keystroke: queue the "before" read. The queue is serial, so
    /// it always completes before any "after" read. If the target handles the paste before it
    /// answers this read, before == after and the check never confirms: the safe direction.
    func captureBefore() {
        queue.async { [self] in
            guard !isCancelled else { return }
            before = reader.read(pid: pid, precedingLength: 0)
        }
    }

    /// Main thread, right after the paste keystroke. `report` is called on MAIN, once, with the
    /// final verdict (confirmed, unreadable, or not-yet after the last look).
    func start(delays: [TimeInterval], report: @escaping (PasteOutcomeVerdict) -> Void) {
        let startedAt = DispatchTime.now()
        func look(_ index: Int) {
            guard index < delays.count else { return }
            queue.asyncAfter(deadline: startedAt + delays[index]) { [self] in
                guard !isCancelled else { return }
                guard before != nil else {
                    DispatchQueue.main.async { report(.unreadable) }
                    return
                }
                let after = reader.read(pid: pid, precedingLength: (text as NSString).length)
                let verdict = PasteOutcome.verdict(before: before, after: after, text: text)
                if verdict == .notYet && index + 1 < delays.count {
                    look(index + 1)
                } else {
                    DispatchQueue.main.async { report(verdict) }
                }
            }
        }
        look(0)
    }
}

/// The production reader: plain AX attribute reads with a short per-ref timeout.
struct AXPasteFieldReader: PasteFieldReading {
    static let messagingTimeout: Float = 0.1

    /// CFEqual/CFHash identity for an AXUIElement.
    struct ElementIdentity: Hashable {
        let element: AXUIElement
        static func == (lhs: ElementIdentity, rhs: ElementIdentity) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    func read(pid: pid_t, precedingLength: Int) -> PasteFieldSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedValue = focusedRef, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement  // swiftlint:disable:this force_cast
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let count = countRef as? Int else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }  // swiftlint:disable:this force_cast

        var preceding: String?
        if precedingLength > 0, range.location >= precedingLength {
            var wanted = CFRange(location: range.location - precedingLength, length: precedingLength)
            if let param = AXValueCreate(.cfRange, &wanted) {
                var stringRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    focused, kAXStringForRangeParameterizedAttribute as CFString, param, &stringRef) == .success {
                    preceding = stringRef as? String
                }
            }
        }
        return PasteFieldSnapshot(elementID: AnyHashable(ElementIdentity(element: focused)),
                                  characterCount: count, selectionLocation: range.location,
                                  selectionLength: range.length, textBeforeCaret: preceding)
    }
}
