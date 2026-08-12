// Claude · 2026-08-12 · Session: 9bb7d552-ac60-4aeb-b987-841018c752be
import XCTest
@testable import SpeakFreeLib

/// Policy tests for the Secure-Input retry dialog (Michael 2026-08-12: "a little box …
/// keeps retrying, and if it gets it, it shuts down the box"). The loop itself is a
/// 0.5s timer in AppDelegate; every decision it takes routes through the pure
/// `TextInserter.secureInputRetryAction`, pinned here.
final class SecureInputRetryTests: XCTestCase {

    private func action(secure: Bool = false, moved: Bool = false,
                        sameApp: Bool = true, expired: Bool = false)
        -> TextInserter.SecureInputRetryAction {
        TextInserter.secureInputRetryAction(secureInputActive: secure,
                                            clipboardMoved: moved,
                                            frontmostMatchesTarget: sameApp,
                                            deadlinePassed: expired)
    }

    func testWaitsWhileSecureInputStaysOn() {
        XCTAssertEqual(action(secure: true), .wait,
                       "while Secure Input holds, the user can still press ⌘V — keep the box up")
    }

    func testInsertsWhenSecureInputClearsInTheSameApp() {
        XCTAssertEqual(action(secure: false, sameApp: true), .insert,
                       "the moment Secure Input clears with the target app frontmost, auto-insert")
    }

    func testNeverInsertsIntoADifferentApp() {
        XCTAssertEqual(action(secure: false, sameApp: false), .wait,
                       "user switched apps — auto-inserting would land text in the wrong app")
    }

    func testDismissesWhenTheClipboardMovesOn() {
        XCTAssertEqual(action(moved: true), .dismiss,
                       "the dictation is no longer on the clipboard — the box promises nothing")
        XCTAssertEqual(action(secure: true, moved: true), .dismiss,
                       "clipboard-moved dismissal wins even while Secure Input is still on")
    }

    func testDismissesAtTheDeadline() {
        XCTAssertEqual(action(expired: true), .dismiss)
        XCTAssertEqual(action(secure: true, sameApp: false, expired: true), .dismiss,
                       "the hold expiring ends the dialog regardless of every other input")
    }

    func testDismissalBeatsInsertionOnTheSameTick() {
        XCTAssertEqual(action(secure: false, moved: true, sameApp: true), .dismiss,
                       "a stale clipboard must never be re-inserted just because Secure Input cleared")
    }
}
