// ai-suggestion:unverified · session:019fecb2-8ac5-7423-90a3-d70aac039387 · 2026-08-10
import AppKit
import XCTest
@testable import SpeakFreeLib

final class CursorContextInteractionTests: XCTestCase {
    func testPrintableTypingExtendsRememberedTail() {
        XCTAssertEqual(
            HotkeyManager.cursorInteraction(
                eventType: .keyDown, eventKeyCode: 0, eventModifiers: 0, characters: "a"),
            .text("a"))
    }

    func testEditingKeysHaveConservativeMeanings() {
        XCTAssertEqual(HotkeyManager.cursorInteraction(
            eventType: .keyDown, eventKeyCode: 51, eventModifiers: 0, characters: nil), .backspace)
        XCTAssertEqual(HotkeyManager.cursorInteraction(
            eventType: .keyDown, eventKeyCode: 36, eventModifiers: 0, characters: "\r"), .newline)
        XCTAssertEqual(HotkeyManager.cursorInteraction(
            eventType: .keyDown, eventKeyCode: 123, eventModifiers: 0, characters: nil), .invalidate)
        XCTAssertEqual(HotkeyManager.cursorInteraction(
            eventType: .leftMouseDown, eventKeyCode: 0, eventModifiers: 0, characters: nil), .invalidate)
    }

    func testOnlyCommandPasteCanExtendKnownTail() {
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        XCTAssertEqual(HotkeyManager.cursorInteraction(
            eventType: .keyDown, eventKeyCode: 9, eventModifiers: command, characters: "v"), .paste)
        XCTAssertEqual(HotkeyManager.cursorInteraction(
            eventType: .keyDown, eventKeyCode: 0, eventModifiers: command, characters: "a"), .invalidate)
    }

    func testKnownEditsMaintainAUsableMidSentenceTail() {
        var tail = "This is"
        tail = HotkeyManager.updatedCursorTail(tail, after: .text(" "))!
        tail = HotkeyManager.updatedCursorTail(tail, after: .text("a"))!
        tail = HotkeyManager.updatedCursorTail(tail, after: .backspace)!
        tail = HotkeyManager.updatedCursorTail(tail, after: .paste, pastedText: "still")!
        XCTAssertEqual(tail, "This is still")
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: tail))
        XCTAssertEqual(TextPipeline.adjustCaseForInsertion(
            "Useful continuation", contextBefore: tail), "useful continuation")
    }

    func testUnknownEditsInvalidateRememberedTail() {
        XCTAssertNil(HotkeyManager.updatedCursorTail("known", after: .invalidate))
        XCTAssertNil(HotkeyManager.updatedCursorTail("known", after: .paste, pastedText: nil))
        XCTAssertNil(HotkeyManager.updatedCursorTail("", after: .backspace))
    }

    func testRememberedTailStaysBounded() {
        let result = HotkeyManager.updatedCursorTail(
            String(repeating: "a", count: 500), after: .text("b"))
        XCTAssertEqual(result?.count, 500)
        XCTAssertEqual(result?.last, "b")
    }
}
