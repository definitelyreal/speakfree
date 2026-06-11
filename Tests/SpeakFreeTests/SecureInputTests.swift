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
@testable import SpeakFreeLib

final class SecureInputTests: XCTestCase {

    // MARK: - helpers

    /// A throwaway named pasteboard so tests never read or write NSPasteboard.general —
    /// the developer's real clipboard locally, and a hang risk on headless CI (the pboard
    /// daemon can block indefinitely outside a full Aqua session). Test-host-safety, PLAN.md P-1.
    private func makeTestPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("speakfree-test-" + UUID().uuidString))
    }

    private func makeInserter(secureInput: Bool) -> TextInserter {
        let inserter = TextInserter()
        inserter.isSecureInputActive = { secureInput }
        // Ghost-typing guard: stub the real insertion mechanism so NO test can ever post
        // synthetic CGEvent keystrokes or paste into whatever window happens to be frontmost
        // on the dev's machine. Tests that need to observe the inserted text override this.
        inserter.performInsertion = { _ in }
        // Clipboard guard: all clipboard paths write a private named pasteboard, never .general.
        inserter.pasteboard = makeTestPasteboard()
        // AX guard: never perform the real focused-element WindowServer IPC from a test —
        // it blocks forever on headless CI (this exact call hung the CI suite for 17 min).
        inserter.focusedElementProvider = { nil }
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
        // Override the ghost-typing stub to RECORD what gets routed to insertion. Without the
        // performInsertion seam this line would post real keystrokes / paste "normal text" into
        // the frontmost window on the host (the bug that started this whole investigation).
        var inserted: String?
        inserter.performInsertion = { inserted = $0 }

        var callbackFired = false
        // No element → pasteText() path → secure-input guard must not fire the callback.
        inserter.insert(text: "normal text", onFocusLost: { callbackFired = true })

        XCTAssertEqual(inserted, "normal text",
                       "guard-off path must route the text to the (stubbed) insertion mechanism")
        XCTAssertFalse(callbackFired,
                       "onFocusLost must not be called by the secure-input guard when secure input is off")
    }

    // MARK: - async refocus path re-checks secure input after focus-settle delay

    /// If secure input becomes active during the 150ms focus-settle window (after the
    /// synchronous guard passes but before the async closure fires), the closure must
    /// fall back to the copy-only affordance rather than posting AX or paste events.
    ///
    /// Setup: the secure-input seam starts false (the sync guard at insert() entry
    /// passes) and the refocus seam is injected to return true, so the 150ms
    /// focus-settle closure IS dispatched. The secure-input seam then flips to true
    /// before the closure executes. The closure's re-check must consult the seam a
    /// second time and fall back to copy-only (onFocusLost fires asynchronously)
    /// without touching AX or paste.
    func test_secureInput_asyncRefocusPathRechecksBeforeInserting() {
        let exp = expectation(description: "async re-check fires onFocusLost from the closure")
        let inserter = TextInserter()
        inserter.pasteboard = makeTestPasteboard()
        inserter.focusedElementProvider = { nil }

        // Start with secure input OFF so the synchronous guard at insert() entry passes.
        var secureInputIsOn = false
        var secureInputChecks = 0
        inserter.isSecureInputActive = {
            secureInputChecks += 1
            return secureInputIsOn
        }
        // Force the refocus branch to "succeed" so the async closure is dispatched —
        // a real AX refocus can never succeed in a headless test runner.
        var refocusCalled = false
        inserter.refocusElement = { _ in
            refocusCalled = true
            return true
        }

        var callbackFired = false
        let bogusElement = AXUIElementCreateSystemWide()
        let scheduled = inserter.insert(text: "secret", refocusing: bogusElement, onFocusLost: {
            callbackFired = true
            exp.fulfill()
        })

        // The sync guard passed and the async path was scheduled.
        XCTAssertTrue(scheduled, "insert must return true when the refocus path is scheduled")
        XCTAssertTrue(refocusCalled, "the refocus seam must be consulted")
        XCTAssertFalse(callbackFired, "onFocusLost must NOT have fired synchronously")
        XCTAssertEqual(secureInputChecks, 1, "exactly one secure-input check (entry guard) before the closure runs")

        // Secure input becomes active during the 150ms focus-settle window.
        secureInputIsOn = true

        // The closure's re-check must consult the seam again and fall back to copy-only.
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(callbackFired, "the async re-check must fire onFocusLost when secure input became active mid-settle")
        XCTAssertEqual(secureInputChecks, 2, "the async closure must re-check secure input (second seam consultation)")
    }

    // MARK: - AR-1: Secure-Input clipboard fallback is concealed + auto-cleared

    /// The Secure-Input fallback must write the dictated text with the nspasteboard
    /// Concealed + Transient markers so clipboard-history tools skip it — unlike the old
    /// bare clearContents()+setString that left plaintext for any app to read.
    func test_secureInputFallback_setsConcealedAndTransientMarkers() {
        let pb = makeTestPasteboard()
        pb.clearContents()

        let inserter = TextInserter()
        inserter.pasteboard = pb
        inserter.secureInputClipboardClearDelay = 60  // don't auto-clear during the assertions
        inserter.secureInputClipboardFallback("my-secret-password")

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let types = pb.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(concealed), "Concealed marker must be present")
        XCTAssertTrue(types.contains(transient), "Transient marker must be present")
        XCTAssertEqual(pb.string(forType: .string), "my-secret-password",
                       "the text is still pasteable while it lives")
        pb.clearContents()
    }

    /// The fallback must auto-clear the dictated text after the (test-shortened) delay,
    /// so the plaintext does not linger on the general pasteboard.
    func test_secureInputFallback_autoClearsAfterDelay() {
        let pb = makeTestPasteboard()
        pb.clearContents()

        let inserter = TextInserter()
        inserter.pasteboard = pb
        inserter.secureInputClipboardClearDelay = 0.2
        inserter.secureInputClipboardFallback("ephemeral-secret")
        XCTAssertEqual(pb.string(forType: .string), "ephemeral-secret",
                       "text present immediately after fallback")

        let exp = expectation(description: "clipboard auto-clears")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // After the 0.2s clear delay (+ slack), our concealed write must be gone.
            XCTAssertNil(pb.string(forType: .string),
                         "dictated text must be auto-cleared from the clipboard")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    /// If the user copies something else after the fallback, auto-clear must NOT clobber it
    /// (it only clears when its own write is still the live clipboard content).
    func test_secureInputFallback_doesNotClobberUserCopyAfterwards() {
        let pb = makeTestPasteboard()
        pb.clearContents()

        let inserter = TextInserter()
        inserter.pasteboard = pb
        inserter.secureInputClipboardClearDelay = 0.2
        inserter.secureInputClipboardFallback("dictated-secret")

        // User copies something else before the auto-clear fires.
        pb.clearContents()
        pb.setString("user-copied-this", forType: .string)

        let exp = expectation(description: "user clipboard preserved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            XCTAssertEqual(pb.string(forType: .string), "user-copied-this",
                           "auto-clear must not wipe the user's later copy")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        pb.clearContents()
    }

    /// End-to-end: insert() under Secure Input routes through the concealed fallback (markers
    /// present), proving the worst-case path no longer leaks plaintext via bare copyToClipboard.
    func test_secureInput_insertRoutesThroughConcealedFallback() {
        let inserter = makeInserter(secureInput: true)
        let pb = inserter.pasteboard
        pb.clearContents()

        inserter.secureInputClipboardClearDelay = 60
        inserter.insert(text: "password-into-secure-field")

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let types = pb.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(concealed),
                      "insert() under Secure Input must use the concealed clipboard fallback")
        pb.clearContents()
    }

    // MARK: - M2: onSecureInputFallback fires only on the secure-input path

    /// `onSecureInputFallback` fires when `insert()` hits the secure-input guard, so the UI can
    /// show a distinct "auto-clears" notification (audit M2).
    func test_secureInput_onSecureInputFallbackFires() {
        let inserter = makeInserter(secureInput: true)
        var fallbackFired = false
        inserter.onSecureInputFallback = { fallbackFired = true }
        inserter.insert(text: "password-dictation")
        XCTAssertTrue(fallbackFired, "onSecureInputFallback must fire when Secure Input is active")
    }

    /// `onSecureInputFallback` must NOT fire when Secure Input is inactive (regular insertion path).
    func test_noSecureInput_onSecureInputFallbackDoesNotFire() {
        let inserter = makeInserter(secureInput: false)
        var fallbackFired = false
        inserter.onSecureInputFallback = { fallbackFired = true }
        inserter.insert(text: "normal-text")
        XCTAssertFalse(fallbackFired, "onSecureInputFallback must not fire on the normal insertion path")
    }

    // MARK: - M2: auto-clear delay default is 15 s

    /// The default auto-clear delay must be 15 s (shortened from 30 s in M2 to reduce the
    /// window in which the plaintext sits on the general pasteboard).
    func test_secureInputClearDelay_defaultIs15Seconds() {
        let inserter = TextInserter()
        XCTAssertEqual(inserter.secureInputClipboardClearDelay, 15, accuracy: 0.001,
                       "Default auto-clear delay must be 15 s (audit M2)")
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
