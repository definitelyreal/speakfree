// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T1.6 — Fail loudly on setup failure
//
// These tests exercise the two seams added to AppDelegate:
//
//   • `_setupExecutor`  — replaces `setupInner()` with a scripted throw so tests can
//                          trigger the failure path without running real setup.
//   • `_alertPresenter` — replaces the blocking NSAlert so tests can inspect calls
//                          without a visible dialog or a runloop block.
//
// The StatusBarController.State machine is also asserted directly — no AppKit runloop
// is required because the state property is plain Swift and can be set/read without
// launching the app.

import XCTest
@testable import SpeakFreeLib

// MARK: - Helpers

private struct FakeSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - StatusBarController.State machine

final class SetupFailureStateTests: XCTestCase {

    // MARK: setupFailed state — icon path

    /// The `.setupFailed` state is distinct from `.idle` and `.noModel`.
    func test_setupFailedState_isNotIdle() {
        let state = StatusBarController.State.setupFailed(message: "boom")
        XCTAssertNotEqual(state, .idle)
        XCTAssertNotEqual(state, .noModel)
    }

    /// Two `.setupFailed` states with the same message are equal (Equatable).
    func test_setupFailedState_equatableByMessage() {
        let a = StatusBarController.State.setupFailed(message: "disk full")
        let b = StatusBarController.State.setupFailed(message: "disk full")
        let c = StatusBarController.State.setupFailed(message: "other error")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    /// The error message is preserved in the associated value.
    func test_setupFailedState_carriesMessage() {
        let expected = "Config file corrupted"
        let state = StatusBarController.State.setupFailed(message: expected)
        if case .setupFailed(let msg) = state {
            XCTAssertEqual(msg, expected)
        } else {
            XCTFail("Expected .setupFailed, got \(state)")
        }
    }

    // MARK: drawErrorIcon smoke test

    /// `drawErrorIcon` returns an NSImage without crashing. Visual accuracy is tested
    /// by running the app, not by unit tests.
    func test_drawErrorIcon_returnsImage() {
        let img = StatusBarController.drawErrorIcon()
        XCTAssertEqual(img.size.width, 18)
        XCTAssertEqual(img.size.height, 18)
        XCTAssertTrue(img.isTemplate, "error icon must be a template image")
    }
}

// MARK: - AppDelegate setup-failure routing

final class SetupFailureRoutingTests: XCTestCase {

    // MARK: helpers

    /// Build a minimal AppDelegate with the headless seams wired up.
    /// We skip `applicationDidFinishLaunching` (which dispatches the real `setup()`
    /// to a background thread) and call `setup()` directly on the test thread after
    /// installing the seams.
    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        // Wire up a real StatusBarController so state can be read back.
        // (StatusBarController creates an NSStatusItem — fine in xctest.)
        delegate.statusBar = StatusBarController()
        // Suppress the blocking NSAlert.
        delegate._alertPresenter = { _ in /* no-op in tests */ }
        return delegate
    }

    // MARK: simulated-throw test (T1.6 acceptance criterion)

    /// A setup throw must:
    ///   1. Route to the alert presenter (not silently swallowed).
    ///   2. Leave the status bar in `.setupFailed` with the error message.
    ///   3. NOT crash the process (test exits cleanly).
    func test_setupThrow_routesToAlertAndErrorState() {
        let delegate = makeDelegate()

        let errorMessage = "Simulated config parse failure"
        var alertMessageReceived: String?

        // Replace the alert with a recorder.
        delegate._alertPresenter = { msg in alertMessageReceived = msg }

        // Inject a throwing executor to simulate a fatal setup error.
        delegate._setupExecutor = {
            throw FakeSetupError(message: errorMessage)
        }

        // setup()'s catch runs on the background thread and calls
        // DispatchQueue.main.sync for the alert, so the main thread must actively
        // drain its queue while we wait. Do NOT use XCTWaiter/wait(for:) here:
        // under Xcode 26.2 it no longer services the GCD main queue while waiting,
        // so the background thread parks in main.sync forever and XCTest aborts the
        // whole suite with a stalled-wait SIGABRT (found in the 2026-07-01 audit).
        // Instead, spin the main run loop ourselves until setup() returns.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            delegate.runSetupForTesting()
            done.signal()
        }
        var completed = false
        let deadline = Date(timeIntervalSinceNow: 5.0)
        while Date() < deadline {
            // Services both the main.async state hop and the main.sync alert call.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if done.wait(timeout: .now()) == .success { completed = true; break }
        }
        XCTAssertTrue(completed, "setup() must return within 5s — main.sync alert hop deadlocked")

        // One more spin so any trailing main.async work lands before asserting.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        // 1. Alert presenter was called with the error message.
        XCTAssertEqual(alertMessageReceived, errorMessage,
                       "alert presenter must receive the exact error message")

        // 2. Status bar is in the setupFailed state.
        XCTAssertEqual(delegate.statusBar.state,
                       StatusBarController.State.setupFailed(message: errorMessage),
                       "status bar must be in .setupFailed after a setup throw")
    }

    // MARK: no throw — success path is unaffected

    /// When the executor does NOT throw, the alert presenter must NOT be called.
    func test_setupNoThrow_alertNotCalled() {
        let delegate = makeDelegate()

        var alertCalled = false
        delegate._alertPresenter = { _ in alertCalled = true }
        delegate._setupExecutor = { /* success — no throw */ }

        // Same drain-loop pattern as the throwing test (see comment there) — the
        // success path has no main.sync hop today, but keep the tests symmetric so
        // a future main-thread hop in setup() can't reintroduce the stalled-wait abort.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            delegate.runSetupForTesting()
            done.signal()
        }
        var completed = false
        let deadline = Date(timeIntervalSinceNow: 5.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if done.wait(timeout: .now()) == .success { completed = true; break }
        }
        XCTAssertTrue(completed, "setup() must return within 5s")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertFalse(alertCalled, "alert must not be called when setup succeeds")
        // State should remain .idle (executor no-op means setup() returned without error).
        XCTAssertEqual(delegate.statusBar.state, .idle,
                       "status bar must remain .idle when setup does not throw")
    }
}
