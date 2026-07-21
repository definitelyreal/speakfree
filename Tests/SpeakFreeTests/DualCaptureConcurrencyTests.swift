import XCTest
@testable import SpeakFreeLib

final class DualCaptureConcurrencyTests: XCTestCase {
    func testSecondaryResultWaitsForDelayedCaptureStop() async {
        let result = SecondaryCaptureResult()
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            result.resolve([0.1, 0.2, 0.3])
        }
        let samples = await result.value()
        XCTAssertEqual(samples, [0.1, 0.2, 0.3])
    }

    func testSecondaryResultCanResolveBeforeFinalizeAwaitsIt() async {
        let result = SecondaryCaptureResult()
        result.resolve([0.4, 0.5])
        let samples = await result.value()
        XCTAssertEqual(samples, [0.4, 0.5])
    }

    // NOTE: there is deliberately no "two inferences overlap at the app layer" test.
    // Both engine backends serialize internally (Whisper's serial engineQueue,
    // Parakeet's actor), so finalize now transcribes sequentially, primary first —
    // asserting overlap against a fake probe proved nothing about the real engines
    // and advertised a property production intentionally does not have.

    // MARK: - value(timeout:) — a wedged Bluetooth HAL must degrade to primary-only

    func testTimedValueReturnsEmptyWhenNeverResolved() async {
        let result = SecondaryCaptureResult()
        let started = Date()
        let samples = await result.value(timeout: 0.1)
        XCTAssertEqual(samples, [], "an unresolved secondary must time out to primary-only")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testTimedValueReturnsSamplesWhenResolvedInTime() async {
        let result = SecondaryCaptureResult()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            result.resolve([0.7])
        }
        let samples = await result.value(timeout: 2.0)
        XCTAssertEqual(samples, [0.7])
    }

    func testTimedValueReturnsImmediatelyWhenAlreadyResolved() async {
        let result = SecondaryCaptureResult()
        result.resolve([0.8, 0.9])
        let samples = await result.value(timeout: 0.001)
        XCTAssertEqual(samples, [0.8, 0.9])
    }

    func testLateResolveAfterTimeoutDoesNotCrashAndServesLaterWaiters() async {
        let result = SecondaryCaptureResult()
        let timedOut = await result.value(timeout: 0.05)
        XCTAssertEqual(timedOut, [])
        // The capture queue eventually unwedges and resolves — must not double-resume
        // the timed-out waiter, and later waiters get the real samples.
        result.resolve([0.6])
        let late = await result.value()
        XCTAssertEqual(late, [0.6])
    }
}
