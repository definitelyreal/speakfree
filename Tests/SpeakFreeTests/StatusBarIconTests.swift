import XCTest
@testable import SpeakFreeLib

final class StatusBarIconTests: XCTestCase {
    func testMenuBarIconStaysStillWhileDictating() {
        // The on-screen pill already shows recording and processing; the menu bar does not
        // animate or recolour for them.
        XCTAssertTrue(StatusBarController.keepsIdleIcon(for: .idle))
        XCTAssertTrue(StatusBarController.keepsIdleIcon(for: .recording))
        XCTAssertTrue(StatusBarController.keepsIdleIcon(for: .transcribing))
    }

    func testMenuBarStillReportsThingsThePillDoesNot() {
        for state: StatusBarController.State in [.downloading, .ready, .waitingForPermission,
                                                 .copiedToClipboard, .noSpeech, .captureFailed] {
            XCTAssertFalse(StatusBarController.keepsIdleIcon(for: state), "\(state)")
        }
    }
}
