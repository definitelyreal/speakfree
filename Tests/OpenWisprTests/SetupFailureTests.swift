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
@testable import OpenWisprLib

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

        // Call setup() synchronously — the implementation dispatches the
        // state change to main and then calls DispatchQueue.main.sync for the
        // alert, so we need to drain the main queue.
        let exp = expectation(description: "setup-failure side-effects reach main queue")
        DispatchQueue.global().async {
            // We're calling the internal `setup()` indirectly via the executor seam.
            // AppDelegate.setup() is private, so we trigger it the same way the app
            // does — but we can't call it from a test directly.  Instead we invoke it
            // through the public seam contract by running a method that calls setup().
            // Since we can't call `setup()` (it is private), we exercise the SAME code
            // path by directly simulating what setup() does when the executor throws:
            // that is, we replicate the catch block via the seams.
            //
            // Actually: setup() IS accessible in test targets because AppDelegate is
            // @testable-imported.  We use perform(selector:) as a workaround.
            // Better: use the internal bridge below.
            delegate.runSetupForTesting()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        // Drain the main queue so the DispatchQueue.main.async state update fires.
        // Use a short runloop spin — just enough for the async to execute.
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

        let exp = expectation(description: "non-throwing setup completes")
        DispatchQueue.global().async {
            delegate.runSetupForTesting()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertFalse(alertCalled, "alert must not be called when setup succeeds")
        // State should remain .idle (executor no-op means setup() returned without error).
        XCTAssertEqual(delegate.statusBar.state, .idle,
                       "status bar must remain .idle when setup does not throw")
    }
}
