// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-02
import AppKit
import XCTest
@testable import SpeakFreeLib

final class HistoryPlainTextTests: XCTestCase {
    func testExplicitRowClickReplacesAaFocusBeforeCopyFallback() {
        let model = HistoryPickerModel()
        let original = rich
        let plain = entry([.init(type: "public.utf8-plain-text", data: Data("Plain".utf8))])
        model.entries = [original, plain]
        model.resetForPresentation()
        model.handle(.focusPlainText)
        var choices: [HistoryEntry] = []
        model.choose = { value, _ in
            choices.append(value)
            model.pasteBehavior = .copyOnly
        }
        // A click can arrive without hover first. A failed paste keeps the picker open.
        model.activate(id: plain.id)
        XCTAssertEqual(model.keyboardFocus, .row)
        model.activate()
        XCTAssertEqual(choices, [plain, plain], "Return must still copy the selected plain row")
        model.move(-1)
        XCTAssertEqual(model.keyboardFocus, .row, "Explicit original-format choice ends Aa intent")
    }

    func testHistoryRefreshKeepsAaIntentButNeverSelectsADisabledAction() {
        let model = HistoryPickerModel()
        let original = rich
        let next = rich
        let plain = entry([.init(type: "public.utf8-plain-text", data: Data("Plain".utf8))])
        model.entries = [original, plain, next]
        model.resetForPresentation()
        model.handle(.focusPlainText)
        model.entries = [plain, next]
        model.reconcileSelection()
        XCTAssertEqual(model.selectedID, plain.id)
        XCTAssertEqual(model.keyboardFocus, .row)
        model.move(1)
        XCTAssertEqual(model.selectedID, next.id)
        XCTAssertEqual(model.keyboardFocus, .plainText)
    }

    func testTypingAfterArrowOrHoverReturnsCaretControlToSearch() {
        let model = HistoryPickerModel()
        model.entries = [rich]
        model.resetForPresentation()
        model.move(0)
        XCTAssertEqual(model.editorFocus, .search)
        model.handle(.focusPlainText)
        XCTAssertEqual(model.editorFocus, .search)
        model.query = "Bold"
        model.searchChanged()
        XCTAssertEqual(model.keyboardFocus, .search)
        XCTAssertNil(HistoryPickerKeyAction.action(keyCode: 123, modifiers: [],
            rowNavigationFocused: model.rowNavigationFocused))
    }
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
        XCTAssertEqual(model.keyboardFocus, .search)
        let right = model.keyAction(keyCode: 124, modifiers: [])
        XCTAssertEqual(right, .focusPlainText)
        if let right { model.handle(right) }
        XCTAssertEqual(model.keyboardFocus, .plainText)
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
        model.handle(model.keyAction(keyCode: 124, modifiers: [])!)
        XCTAssertEqual(model.keyboardFocus, .search, "A plain-only first item has no action to focus")
        model.handle(.move(0)); model.handle(.focusPlainText)
        XCTAssertEqual(model.keyboardFocus, .row)
        model.choose = { _, _ in XCTFail("Disabled action must not choose") }
        model.activate(id: model.entries[0].id, plainText: true)
    }
    func testSearchCaretFilterNavigationAndReopenRouteArrowsCorrectly() {
        let model = HistoryPickerModel()
        model.entries = [rich]
        model.resetForPresentation()
        model.query = "Bold"
        model.searchChanged()
        XCTAssertNil(model.keyAction(keyCode: 124, modifiers: []))
        XCTAssertNil(model.keyAction(keyCode: 123, modifiers: []))
        model.keyboardFocus = .filter(.all)
        XCTAssertEqual(model.keyAction(keyCode: 124, modifiers: []), .cycleFilter(1))
        model.resetForPresentation()
        XCTAssertEqual(model.keyAction(keyCode: 124, modifiers: []), .focusPlainText)
        XCTAssertNil(model.keyAction(keyCode: 124, modifiers: .shift))
        model.handle(.focusPlainText)
        XCTAssertEqual(model.keyAction(keyCode: 123, modifiers: []), .focusRow)
    }
    func testRepeatedActivationIsBlockedWhilePastingAndCopiesAfterFailureUntilReopened() {
        let model = HistoryPickerModel()
        model.entries = [rich]
        model.resetForPresentation()
        var copyChoices: [Bool] = []
        model.choose = { _, copy in
            copyChoices.append(copy)
            model.pasteBehavior = .pasting
        }
        model.activate()
        model.activate()
        model.activate(id: model.entries[0].id, plainText: true)
        XCTAssertEqual(copyChoices, [false], "A double-click must not start overlapping attempts")
        model.pasteBehavior = .copyOnly
        model.activate()
        XCTAssertEqual(copyChoices, [false, true], "A failed destination must not be retried by the next click")
        model.resetForPresentation()
        model.activate()
        XCTAssertEqual(copyChoices, [false, true, false], "Explicitly reopening captures a new destination")
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
