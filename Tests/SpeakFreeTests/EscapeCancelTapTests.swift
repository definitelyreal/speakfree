import XCTest
@testable import SpeakFreeLib

final class EscapeCancelTapTests: XCTestCase {
    func testBareEscapeCancels() {
        XCTAssertTrue(EscapeCancelTap.isBareEscape(keyCode: 53, flags: []))
    }

    func testEscapeWithAModifierBelongsToTheFrontApp() {
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            XCTAssertFalse(EscapeCancelTap.isBareEscape(keyCode: 53, flags: modifier))
        }
    }

    func testOtherKeysAreNeverSwallowed() {
        for keyCode: Int64 in [36, 49, 51, 0, 63] {
            XCTAssertFalse(EscapeCancelTap.isBareEscape(keyCode: keyCode, flags: []))
        }
    }

    func testLockAndFnFlagsDoNotCountAsModifiers() {
        XCTAssertTrue(EscapeCancelTap.isBareEscape(keyCode: 53, flags: [.maskAlphaShift, .maskSecondaryFn]))
    }

    func testEscapeOnlyDiscardsWhileADictationIsLive() {
        XCTAssertEqual(EscapeCancelTap.action(isRecording: true, overlayVisible: true), .abortRecording)
        XCTAssertEqual(EscapeCancelTap.action(isRecording: false, overlayVisible: true), .discardPendingText)
        XCTAssertEqual(EscapeCancelTap.action(isRecording: false, overlayVisible: false), .ignore)
    }
}
