// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class KeyboardGestureMachineTests: XCTestCase {
    func testRecordedCharacterPathPreviewsThenCommitsSwipe() {
        var machine = KeyboardGestureMachine()
        machine.begin(role: .character, x: 10, y: 10, timestamp: 0)
        XCTAssertEqual(machine.move(x: 20, y: 10, timestamp: 0.04), [])
        XCTAssertEqual(machine.move(x: 31, y: 12, timestamp: 0.08), [])
        XCTAssertEqual(machine.move(x: 44, y: 14, timestamp: 0.13), [.previewSwipe])
        XCTAssertEqual(machine.end(), .commitSwipe)
        XCTAssertEqual(machine.state, .idle)
    }

    func testSpaceCursorRequiresHorizontalDominanceAndEmitsDeltas() {
        var machine = KeyboardGestureMachine()
        machine.begin(role: .space, x: 50, y: 50, timestamp: 0)
        XCTAssertEqual(machine.move(x: 55, y: 75, timestamp: 0.1), [])
        XCTAssertEqual(machine.state, .tapPending)
        XCTAssertEqual(machine.move(x: 75, y: 52, timestamp: 0.2), [.moveCursor(2)])
        XCTAssertEqual(machine.move(x: 88, y: 52, timestamp: 0.3), [.moveCursor(1)])
        XCTAssertEqual(machine.end(), .none)
    }

    func testDeleteWordFiresOnceAndSuppressesTap() {
        var machine = KeyboardGestureMachine()
        machine.begin(role: .delete, x: 100, y: 20, timestamp: 0)
        XCTAssertEqual(machine.move(x: 65, y: 22, timestamp: 0.1), [.deleteWord])
        XCTAssertEqual(machine.move(x: 30, y: 22, timestamp: 0.2), [])
        XCTAssertEqual(machine.end(), .none)
    }

    func testAlternateSelectionAndCancellationAreExclusive() {
        var machine = KeyboardGestureMachine()
        machine.begin(role: .character, x: 10, y: 10, timestamp: 0)
        XCTAssertTrue(machine.beginAlternateSelection())
        XCTAssertEqual(machine.move(x: 80, y: 10, timestamp: 0.5), [])
        XCTAssertEqual(machine.end(hasSelectedAlternate: true), .selectedAlternate)

        machine.begin(role: .character, x: 10, y: 10, timestamp: 1)
        _ = machine.move(x: 40, y: 10, timestamp: 1.2)
        machine.cancel()
        XCTAssertEqual(machine.end(), .none)
    }

    func testDeleteRepeatSuppressesReleaseTap() {
        var machine = KeyboardGestureMachine()
        machine.begin(role: .delete, x: 10, y: 10, timestamp: 0)
        XCTAssertTrue(machine.beginDeleteRepeating())
        XCTAssertTrue(machine.beginDeleteRepeating())
        XCTAssertEqual(machine.end(), .none)
    }

    func testDisabledCharacterDragDoesNotBecomeATapOrSwipe() {
        var machine = KeyboardGestureMachine()
        machine.begin(role: .disabledCharacter, x: 10, y: 10, timestamp: 0)
        XCTAssertEqual(machine.move(x: 45, y: 10, timestamp: 0.1), [])
        XCTAssertEqual(machine.state, .suppressed)
        XCTAssertEqual(machine.end(), .none)
    }
}
