// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_elegance_audit · 2026-10-01
// Claude · 2026-07-15 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
//
// Round-2 adversarial-review fixes for the insertion / AX / UI surface (Agent A):
//   I2  updated Oct 1: missing focus identity retains the draft instead of authorizing a blind paste
//   I5  global-monitor fallback handles fn (flagsChanged) via the pure fnTransition decision
//   I6  onboarding engine picker index is derived from the applied suggestion, not hard-selected to 0
//
// I1 (EnginePickerView re-save on download completion), I3 (per-element AX 2s timeout), and I4
// (screenContext clears on the gate-failure / engine-start-failed paths) have NO unit-test seam —
// they live inside a real async download completion, a real AX SetAttributeValue round-trip, and
// AppDelegate's recording lifecycle respectively. Those are covered by the code change + review,
// not a test here.
//
// All tests use the existing TextInserter seams (performInsertion / focusedElementProvider /
// refocusElement / directAXInsert / a named pasteboard) or pure static helpers, so the suite NEVER
// posts real keystrokes, touches the developer's clipboard, or performs AX WindowServer IPC.

import XCTest
import ApplicationServices
@testable import SpeakFreeLib

final class AdversarialR2InsertionTests: XCTestCase {

    private func makeTestPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("speakfree-r2-test-" + UUID().uuidString))
    }

    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // MARK: - I2: nil re-query cannot confirm the original control

    /// The earlier test explicitly allowed blind paste on nil. The maintainer's current original-control
    /// requirement supersedes that choice: unknown focus is retained and reported, never success.
    func test_i2_nilRequeryRetainsInsteadOfBlindPasting() {
        let exp = expectation(description: "unknown focus retains the draft")
        let inserter = TextInserter()
        inserter.pasteboard = makeTestPasteboard()
        inserter.isSecureInputActive = { false }
        inserter.frontmostPIDProvider = { 999_991 }
        inserter.focusedElementProvider = { nil }   // nil on sync check AND closure re-check
        inserter.refocusElement = { _ in true }      // schedule the async closure
        inserter.directAXInsert = { _, _ in false }  // force the post-AX fallback branch, no real AX IPC

        var pasted: String?
        inserter.performInsertion = {
            pasted = $0
        }
        var focusLostFired = false
        let target = AXUIElementCreateApplication(999_991)
        _ = inserter.insert(text: "hello world", refocusing: target, onFocusLost: {
            focusLostFired = true
            exp.fulfill()
        })

        wait(for: [exp], timeout: 2.0)
        XCTAssertNil(pasted, "a nil re-query cannot authorize a paste into an unknown control")
        XCTAssertTrue(focusLostFired, "the caller must retain the draft when focus cannot be confirmed")
        let types = inserter.pasteboard.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(concealed))
        XCTAssertEqual(inserter.pasteboard.string(forType: .string), "hello world")
        inserter.pasteboard.clearContents()
    }

    /// Complement: a DIFFERENT element affirmatively returned DOES conceal (focus really moved).
    func test_i2_differentElementConceals() {
        let exp = expectation(description: "async fallback fires onFocusLost on a different element")
        let inserter = TextInserter()
        inserter.pasteboard = makeTestPasteboard()
        inserter.pasteboard.clearContents()
        inserter.secureInputClipboardClearDelay = 60
        inserter.isSecureInputActive = { false }
        let target = AXUIElementCreateSystemWide()
        let other = AXUIElementCreateApplication(getpid())
        XCTAssertFalse(CFEqual(other, target), "precondition: the two elements must be distinct")
        inserter.focusedElementProvider = { other }
        inserter.refocusElement = { _ in true }
        inserter.directAXInsert = { _, _ in false }

        var blindPasted: String?
        inserter.performInsertion = { blindPasted = $0 }
        var focusLostFired = false
        _ = inserter.insert(text: "secret", refocusing: target, onFocusLost: {
            focusLostFired = true
            exp.fulfill()
        })

        wait(for: [exp], timeout: 2.0)
        XCTAssertNil(blindPasted, "a different focused element must conceal, not blind-paste")
        XCTAssertTrue(focusLostFired, "onFocusLost must fire when focus moved to a different element")
        let types = inserter.pasteboard.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(concealed), "a real focus move must conceal the clipboard write")
        inserter.pasteboard.clearContents()
    }

    // MARK: - I5: global-monitor fallback fn-transition decision

    func test_i5_fnTransition_pressReleaseCycle() {
        // fn down while not pressed → keyDown.
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: true, modifierPressed: false), .keyDown)
        // fn up while pressed → keyUp.
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: true, modifierPressed: true), .none,
                       "fn still down and already pressed → no repeat keyDown")
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: false, modifierPressed: true), .keyUp)
        // fn up while not pressed → nothing (idle / an unrelated modifier).
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: false, modifierPressed: false), .none)
    }

    func test_contextInteractionMonitor_filtersHotkeyAndSyntheticEvents() {
        let currentPID: Int64 = 1234
        XCTAssertFalse(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .keyDown, eventKeyCode: 63, eventModifiers: 0,
            sourcePID: 0, currentPID: currentPID,
            hotkeyKeyCode: 63, requiredModifiers: 0))
        XCTAssertFalse(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .keyDown, eventKeyCode: 9, eventModifiers: 0,
            sourcePID: currentPID, currentPID: currentPID,
            hotkeyKeyCode: 63, requiredModifiers: 0))
    }

    func test_contextInteractionMonitor_countsRealMouseAndKeyboardNavigation() {
        let args = (currentPID: Int64(1234), hotkey: UInt16(63))
        XCTAssertTrue(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .leftMouseDown, eventKeyCode: 0, eventModifiers: 0,
            sourcePID: 0, currentPID: args.currentPID,
            hotkeyKeyCode: args.hotkey, requiredModifiers: 0))
        XCTAssertTrue(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .keyDown, eventKeyCode: 48, eventModifiers: 0,
            sourcePID: 0, currentPID: args.currentPID,
            hotkeyKeyCode: args.hotkey, requiredModifiers: 0))
    }

    func test_contextInteractionMonitor_excludesSystemEventsAutomationPaste() {
        // The remote-desktop insertion path pastes via System Events ("keystroke v" at
        // +0.4s); that synthetic Cmd-V carries System Events' PID and must NOT
        // self-invalidate the remembered context remote-desktop apps depend on.
        let systemEventsPID: Int64 = 777
        XCTAssertFalse(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .keyDown, eventKeyCode: 9, eventModifiers: 0x100000,
            sourcePID: systemEventsPID, currentPID: 1234,
            hotkeyKeyCode: 63, requiredModifiers: 0,
            automationPID: systemEventsPID))
        // A real keystroke from any other source still counts…
        XCTAssertTrue(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .keyDown, eventKeyCode: 9, eventModifiers: 0,
            sourcePID: 0, currentPID: 1234,
            hotkeyKeyCode: 63, requiredModifiers: 0,
            automationPID: systemEventsPID))
        // …and an unknown automation PID (System Events not running) excludes nothing.
        XCTAssertTrue(HotkeyManager.shouldCountAsUserInteraction(
            eventType: .keyDown, eventKeyCode: 9, eventModifiers: 0,
            sourcePID: 777, currentPID: 1234,
            hotkeyKeyCode: 63, requiredModifiers: 0,
            automationPID: nil))
    }

    // MARK: - I6: onboarding engine picker index derives from the applied suggestion

    func test_i6_enginePickerIndexMatchesSuggestion() {
        XCTAssertEqual(WelcomeController.enginePickerIndex(for: "parakeet"), 0)
        XCTAssertEqual(WelcomeController.enginePickerIndex(for: "whisper"), 1)

        // Full chain through the applySuggestion → currentSelection seam: a whisper suggestion must
        // drive the picker to row 1 (previously hard-coded to 0, disagreeing with the model row).
        let controller = WelcomeController()
        controller.applySuggestion(engine: "whisper", model: "small.en")
        XCTAssertEqual(WelcomeController.enginePickerIndex(for: controller.currentSelection.engine), 1,
                       "a whisper suggestion must select the Whisper picker row, not Parakeet")

        controller.applySuggestion(engine: "parakeet", model: "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(WelcomeController.enginePickerIndex(for: controller.currentSelection.engine), 0)
    }
}
