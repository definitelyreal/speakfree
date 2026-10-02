// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

/// Synthetic input and geometry only: never installs a key monitor or changes real settings.
final class SettingsWindowBehaviorTests: XCTestCase {
    func testACommandChordWaitsForTheLetterInsteadOfCapturingCommand() {
        var recorder = SettingsKeyRecorderState()
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 55, flags: .command), .ignore)
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 56, flags: [.command, .shift]), .ignore)
        XCTAssertEqual(recorder.receive(type: .keyDown, keyCode: 9, flags: [.command, .shift]),
                       .capture(9, ["cmd", "shift"]))
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 56, flags: .command), .ignore)
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 55, flags: []), .ignore)
    }

    func testSingleModifierIsChosenOnReleaseForEitherSideAndFn() {
        let cases: [(UInt16, NSEvent.ModifierFlags)] = [
            (55, .command), (54, .command), (56, .shift), (60, .shift),
            (58, .option), (61, .option), (59, .control), (62, .control), (63, .function)
        ]
        for (code, flag) in cases {
            var recorder = SettingsKeyRecorderState()
            XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: code, flags: flag), .ignore)
            XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: code, flags: []), .capture(code, []))
        }
    }

    func testAnAbandonedModifierChordNeverTurnsIntoASingleModifier() {
        var recorder = SettingsKeyRecorderState()
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 55, flags: .command), .ignore)
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 58, flags: [.command, .option]), .ignore)
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 55, flags: .option), .ignore)
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 58, flags: []), .ignore)
        // All keys are up; a fresh deliberate single modifier works again.
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 61, flags: .option), .ignore)
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 61, flags: []), .capture(61, []))
    }

    func testEscapeCancelsAndRejectedPlainKeyDoesNotPoisonNextChord() {
        var recorder = SettingsKeyRecorderState()
        XCTAssertEqual(recorder.receive(type: .keyDown, keyCode: 53, flags: []), .cancel)
        XCTAssertEqual(recorder.receive(type: .keyDown, keyCode: 9, flags: []), .capture(9, []))
        XCTAssertEqual(recorder.receive(type: .flagsChanged, keyCode: 59, flags: .control), .ignore)
        XCTAssertEqual(recorder.receive(type: .keyDown, keyCode: 9, flags: .control), .capture(9, ["ctrl"]))
    }

    func testAStandardKeyWithModifiersHasADistinctCustomPickerChoice() {
        XCTAssertEqual(SettingsHotkeyChoice.current(keyCode: 63, modifiers: []), .standard(63))
        XCTAssertEqual(SettingsHotkeyChoice.current(keyCode: 63, modifiers: ["cmd"]), .custom)
        XCTAssertEqual(SettingsHotkeyChoice.current(keyCode: 61, modifiers: ["shift"]), .custom)
        XCTAssertEqual(SettingsHotkeyChoice.current(keyCode: 9, modifiers: ["cmd", "shift"]), .custom)
        XCTAssertNotEqual(SettingsHotkeyChoice.custom, .standard(63))
    }

    func testPartiallyOffscreenWindowMovesFullyInsideWithoutResizing() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let frame = NSRect(x: 1400, y: -230, width: 760, height: 650)
        let fitted = WindowScreenPlacement.fit(frame, to: screen)
        XCTAssertTrue(screen.contains(fitted))
        XCTAssertEqual(fitted.size, frame.size)
        XCTAssertEqual(fitted.origin, NSPoint(x: 680, y: 25))
    }

    func testOversizedWindowFitsSmallerDisplayIncludingNegativeOrigin() {
        let screen = NSRect(x: -800, y: -500, width: 800, height: 450)
        let fitted = WindowScreenPlacement.fit(NSRect(x: -1400, y: -700, width: 1000, height: 900), to: screen)
        XCTAssertEqual(fitted, screen)
    }

    func testVisibleUserPlacementIsPreserved() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let frame = NSRect(x: 200, y: 125, width: 760, height: 650)
        XCTAssertEqual(WindowScreenPlacement.fit(frame, to: screen), frame)
    }

    func testScreenWithMostWindowAreaWinsAndUnpluggedDisplayFallsBack() {
        let primary = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let other = NSRect(x: 1440, y: 0, width: 1280, height: 900)
        XCTAssertEqual(WindowScreenPlacement.screen(for: NSRect(x: 1400, y: 60, width: 760, height: 650),
                                                    visibleFrames: [primary, other]), other)
        XCTAssertEqual(WindowScreenPlacement.screen(for: NSRect(x: 3000, y: 50, width: 760, height: 650),
                                                    visibleFrames: [primary]), primary)
        XCTAssertNil(WindowScreenPlacement.screen(for: primary, visibleFrames: []))
    }
}
