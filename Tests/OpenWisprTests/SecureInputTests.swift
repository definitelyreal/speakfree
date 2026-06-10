// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T1.4 — Secure Input on all insertion paths
//
// The `isSecureInputActive` closure is the seam that lets tests simulate a
// password field without a real CGEventTap / secure-input context.
//
// Tests verify that EVERY code path through insert() is blocked when the
// seam returns true, and that the copy-only affordance fires exactly once.

import XCTest
@testable import OpenWisprLib

final class SecureInputTests: XCTestCase {

    // MARK: - helpers

    private func makeInserter(secureInput: Bool) -> TextInserter {
        let inserter = TextInserter()
        inserter.isSecureInputActive = { secureInput }
        return inserter
    }

    // MARK: - secure input active: insert() returns false on all paths

    /// insert() with no element (direct pasteText path) returns false when secure input is on.
    func test_secureInput_noElement_returnsFalse() {
        let inserter = makeInserter(secureInput: true)
        let result = inserter.insert(text: "hello")
        XCTAssertFalse(result, "insert must return false under secure input")
    }

    /// insert() with an element (refocus path) returns false when secure input is on.
    /// The AXUIElement itself is never touched — the guard fires before any AX call.
    func test_secureInput_withElement_returnsFalse() {
        let inserter = makeInserter(secureInput: true)
        // A non-nil but deliberately bogus element (won't be poked because the guard fires first).
        let bogusElement = AXUIElementCreateSystemWide()
        let result = inserter.insert(text: "hello", refocusing: bogusElement)
        XCTAssertFalse(result, "insert must return false under secure input even with a refocus element")
    }

    // MARK: - secure input active: onFocusLost callback fires

    /// The copy-only affordance calls onFocusLost so the caller can update the UI
    /// (e.g. show the "copied to clipboard" status bar state).
    func test_secureInput_onFocusLostCallbackFires() {
        let inserter = makeInserter(secureInput: true)
        var callbackFired = false
        inserter.insert(text: "password hint", onFocusLost: { callbackFired = true })
        XCTAssertTrue(callbackFired, "onFocusLost must be called under secure input")
    }

    /// onFocusLost fires exactly once (not zero, not twice).
    func test_secureInput_onFocusLostCallbackFiresExactlyOnce() {
        let inserter = makeInserter(secureInput: true)
        var count = 0
        inserter.insert(text: "x", onFocusLost: { count += 1 })
        XCTAssertEqual(count, 1, "onFocusLost must fire exactly once under secure input")
    }

    // MARK: - secure input inactive: insert() does NOT trip the guard

    /// When secure input is off, insert() does not call onFocusLost due to the guard.
    /// (Focus might still be lost for other reasons, but not from the secure-input guard.)
    func test_noSecureInput_guardDoesNotFireCallback() {
        let inserter = makeInserter(secureInput: false)
        var callbackFired = false
        // No element → pasteText() path → secure-input guard must not fire the callback.
        inserter.insert(text: "normal text", onFocusLost: { callbackFired = true })
        XCTAssertFalse(callbackFired, "onFocusLost must not be called by the secure-input guard when secure input is off")
    }

    // MARK: - seam default produces a real Bool (smoke test)

    /// The default seam compiles and returns a Bool without crashing.
    /// We can't control the system-wide secure-input state in a unit test, so we only
    /// assert the type — not the value.
    func test_defaultSeam_returnsBool() {
        let inserter = TextInserter()
        let value = inserter.isSecureInputActive()
        XCTAssert(value == true || value == false, "default seam must return a Bool")
    }
}
