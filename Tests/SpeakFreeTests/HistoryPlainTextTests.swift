// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-02
import AppKit
import XCTest
@testable import SpeakFreeLib

final class HistoryPlainTextTests: XCTestCase {
    private func entry(_ representations: [HistoryRepresentation]) -> HistoryEntry {
        HistoryEntry(source: .clipboard, items: [.init(representations: representations)])
    }
    private var rich: HistoryEntry {
        entry([.init(type: "public.rtf", data: Data(#"{\rtf1\ansi Bold \b text\b0}"#.utf8)),
               .init(type: "public.utf8-plain-text", data: Data("Bold text".utf8))])
    }
    func testExplicitPlainPasteKeepsOriginalRichBytesAndIdentity() throws {
        let original = rich
        let plain = try XCTUnwrap(original.plainTextVariant())
        XCTAssertEqual(plain.id, original.id)
        XCTAssertEqual(plain.plainText, "Bold text")
        XCTAssertEqual(plain.items[0].representations.map(\.type), ["public.utf8-plain-text"])
        XCTAssertEqual(original.items[0].representations.count, 2)
        XCTAssertFalse(plain.canPastePlainText)
    }
    func testRTFOnlyConvertsLocally() throws {
        let original = entry([.init(type: "public.rtf", data: Data(#"{\rtf1\ansi Hello \b world\b0}"#.utf8))])
        XCTAssertTrue(original.canPastePlainText)
        XCTAssertEqual(try XCTUnwrap(original.plainTextVariant()).plainText, "Hello world")
    }
    func testPlainImageFileAndUnsafeHTMLOnlyCannotUseConversion() {
        for item in [entry([.init(type: "public.utf8-plain-text", data: Data("already plain".utf8))]),
                     entry([.init(type: "public.png", data: Data([0, 1]))]),
                     entry([.init(type: "public.file-url", data: Data("file:///synthetic".utf8))]),
                     entry([.init(type: "public.html", data: Data("<img src='https://example.invalid/x'>".utf8))])] {
            XCTAssertFalse(item.canPastePlainText)
            XCTAssertNil(item.plainTextVariant())
        }
        let mixed = HistoryEntry(source: .clipboard, items: rich.items + [.init(representations: [
            .init(type: "public.png", data: Data([0, 1]))])])
        XCTAssertNil(mixed.plainTextVariant(), "Never silently drop an item during conversion")
    }
    func testRightArrowSelectsPlainActionAndReturnUsesItExactlyOnce() {
        let model = HistoryPickerModel()
        let original = rich
        model.entries = [original]
        model.resetForPresentation()
        model.handle(.move(0))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 124, modifiers: [],
            rowNavigationFocused: model.rowNavigationFocused), .focusPlainText)
        model.handle(.focusPlainText)
        var choices: [HistoryEntry] = []
        model.choose = { value, copy in XCTAssertFalse(copy); choices.append(value) }
        model.handle(.activate(copyOnly: false))
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0].items[0].representations.map(\.type), ["public.utf8-plain-text"])
        model.handle(.focusRow)
        model.activate()
        XCTAssertEqual(choices.last, original)
    }
    func testSearchArrowsAndDisabledButtonNeverActivateConversion() {
        let model = HistoryPickerModel()
        model.entries = [entry([.init(type: "public.utf8-plain-text", data: Data("Plain".utf8))])]
        model.resetForPresentation()
        XCTAssertNil(HistoryPickerKeyAction.action(keyCode: 124, modifiers: [],
            rowNavigationFocused: model.rowNavigationFocused))
        model.handle(.move(0)); model.handle(.focusPlainText)
        XCTAssertEqual(model.keyboardFocus, .row)
        model.choose = { _, _ in XCTFail("Disabled action must not choose") }
        model.activate(id: model.entries[0].id, plainText: true)
    }
    func testPointerMovementReselectsRowAfterKeyboardWithinTheSameTrackingArea() {
        let model = HistoryPickerModel()
        let original = rich
        model.pointerLocation = { .zero }
        let second = entry([.init(type: "public.utf8-plain-text", data: Data("Other".utf8))])
        model.entries = [original, second]
        model.resetForPresentation()
        model.move(1)
        model.hover(original.id, at: .zero)
        XCTAssertEqual(model.selectedID, second.id)
        model.hover(original.id, at: NSPoint(x: 1, y: 0))
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertEqual(model.keyboardFocus, .row)
    }
}
