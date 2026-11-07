import XCTest
@testable import SpeakFreeLib

final class RegisteredHotKeyTests: XCTestCase {
    private let option = UInt64(1 << 19), command = UInt64(1 << 20)
    private let shift = UInt64(1 << 17), control = UInt64(1 << 18)

    func testAKeyWithARealModifierIsRegistered() {
        let combination = RegisteredHotKey.combination(keyCode: 49, modifierFlags: option)
        XCTAssertEqual(combination?.keyCode, 49)
        XCTAssertEqual(combination?.carbonModifiers, UInt32(2048))  // optionKey
        XCTAssertEqual(RegisteredHotKey.combination(keyCode: 9, modifierFlags: command | shift | control)?
            .carbonModifiers, UInt32(256 | 512 | 4096))  // cmdKey | shiftKey | controlKey
    }

    func testAModifierUsedAloneIsNotACombination() {
        // fn, Right Option and friends are handled by the modifier path.
        for keyCode: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            XCTAssertNil(RegisteredHotKey.combination(keyCode: keyCode, modifierFlags: 0))
            XCTAssertNil(RegisteredHotKey.combination(keyCode: keyCode, modifierFlags: option))
        }
    }

    func testAPlainCharacterKeyIsNeverTakenAwayFromTyping() {
        // A hand-edited config could ask for bare Space; registering it would swallow
        // every space typed on the Mac.
        XCTAssertNil(RegisteredHotKey.combination(keyCode: 49, modifierFlags: 0))
        XCTAssertNil(RegisteredHotKey.combination(keyCode: 49, modifierFlags: shift))
    }

    func testAFunctionKeyCanBeRegisteredAlone() {
        XCTAssertEqual(RegisteredHotKey.combination(keyCode: 105, modifierFlags: 0)?.carbonModifiers, 0)  // F13
    }

    func testTheDictationKeyChoosesItsListeningMethod() {
        XCTAssertEqual(HotkeyManager.listening(keyCode: 63, modifiers: 0), .modifierTap)
        XCTAssertEqual(HotkeyManager.listening(keyCode: 61, modifiers: 0), .modifierTap)
        XCTAssertEqual(HotkeyManager.listening(keyCode: 49, modifiers: option), .registered)
        XCTAssertEqual(HotkeyManager.listening(keyCode: 105, modifiers: 0), .registered)
        XCTAssertEqual(HotkeyManager.listening(keyCode: 49, modifiers: 0), .keyboardMonitor)
    }
}
