// Claude · 2026-09-24 · Edit Mode V1
import XCTest
import AppKit
@testable import SpeakFreeLib

/// The real edit window, never shown or activated: no keystrokes are posted and the pasteboard
/// is never touched. Text is driven through NSTextView's own insertText path.
@MainActor
final class EditWindowHarnessTests: XCTestCase {

    private var scratch: URL!
    private var cleaner: ScriptedCleaner!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        cleaner = ScriptedCleaner()
    }

    override func tearDown() async throws {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func make(_ settings: EditModeSettings) -> (EditSessionCore, EditWindowController) {
        let core = EditSessionCore(persistenceEnabled: false, settings: settings, cleaner: cleaner,
                                   clipboard: FakeClipboard())
        let wc = EditWindowController(core: core, targetName: "TextEdit")
        core.onEvent = { [weak wc] in wc?.handle($0) }
        return (core, wc)
    }

    private func dictate(_ core: EditSessionCore, _ text: String) -> UUID {
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: text.lowercased(), pipelineText: text)
        return id
    }

    func testParagraphsRenderAsOneLineBreakApartAndCarryTheirIDs() {
        let (core, wc) = make(.cloudOff)
        let a = dictate(core, "One.")
        let b = dictate(core, "Two.")
        XCTAssertEqual(wc.textView.string, "One.\nTwo.")
        let storage = wc.textView.textStorage!
        XCTAssertEqual(storage.attribute(.editSegmentID, at: 0, effectiveRange: nil) as? String, a.uuidString)
        XCTAssertEqual(storage.attribute(.editSegmentID, at: 5, effectiveRange: nil) as? String, b.uuidString)
    }

    func testTypingFlowsBackIntoTheRightParagraph() {
        let (core, wc) = make(.cloudOff)
        _ = dictate(core, "One.")
        let b = dictate(core, "Two.")
        wc.textView.setSelectedRange(NSRange(location: 9, length: 0))   // end of "Two."
        wc.textView.insertText(" More", replacementRange: wc.textView.selectedRange())
        XCTAssertEqual(core.segment(b)?.currentText, "Two. More")
        XCTAssertEqual(core.segment(b)?.state, .edited)
        XCTAssertEqual(core.commitText, "One.\n\nTwo. More")
    }

    func testShiftReturnLineBreakStaysInsideTheParagraph() {
        let (core, wc) = make(.cloudOff)
        let a = dictate(core, "Line one")
        wc.textView.setSelectedRange(NSRange(location: 8, length: 0))
        wc.textView.insertText("\u{2028}Line two", replacementRange: wc.textView.selectedRange())
        XCTAssertEqual(core.displayedSegments.count, 1)
        XCTAssertEqual(core.segment(a)?.currentText, "Line one\nLine two")
        XCTAssertEqual(core.commitText, "Line one\nLine two")
    }

    func testBackspaceAcrossTheBoundaryMergesInTheModel() {
        let (core, wc) = make(.cloudOff)
        let a = dictate(core, "One.")
        _ = dictate(core, "Two.")
        wc.textView.insertText("", replacementRange: NSRange(location: 4, length: 1))   // the "\n"
        XCTAssertEqual(core.displayedSegments.map(\.id), [a])
        XCTAssertEqual(core.segment(a)?.currentText, "One.Two.")
        XCTAssertEqual(core.versions(for: a)?.takes, 2)
    }

    func testASettleElsewhereKeepsTheCaretAndMarksTheChange() async {
        let (core, wc) = make(.cloudOn)
        let a = dictate(core, "Tell Jon Kama now.")
        let b = dictate(core, "Second paragraph here.")
        await drainMainActor()
        // Caret in paragraph two, after "Second".
        let caretInB = ("Tell Jon Kama now.\n" as NSString).length + 6
        wc.textView.setSelectedRange(NSRange(location: caretInB, length: 0))
        cleaner.finish(cleaner.index(for: "Tell Jon Kama now.")!, .success([SpanEdit(find: "Jon", replace: "John", reason: "name"),
                                    SpanEdit(find: " Kama", replace: ",", reason: "spoken comma")]))
        await drainMainActor()
        XCTAssertEqual(wc.textView.string, "Tell John, now.\nSecond paragraph here.")
        let newCaret = ("Tell John, now.\n" as NSString).length + 6
        XCTAssertEqual(wc.textView.selectedRange().location, newCaret, "the caret stays after \"Second\"")
        XCTAssertEqual(core.segment(b)?.state, .cleaning)
        let storage = wc.textView.textStorage!
        let johnAt = ("Tell " as NSString).length
        XCTAssertEqual(storage.attribute(.toolTip, at: johnAt, effectiveRange: nil) as? String, "was: Jon · name")
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: johnAt, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil), "unchanged words are unmarked")
        XCTAssertEqual(core.segment(a)?.state, .settled)
    }

    func testTypingAfterAMarkedWordDoesNotExtendTheMark() async {
        let (core, wc) = make(.cloudOn)
        let a = dictate(core, "Call Jon")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "Jon", replace: "John", reason: "name")]))
        await drainMainActor()
        let end = (wc.textView.string as NSString).length
        wc.textView.setSelectedRange(NSRange(location: end, length: 0))
        wc.textView.insertText(" now", replacementRange: wc.textView.selectedRange())
        XCTAssertEqual(core.segment(a)?.currentText, "Call John now")
        let storage = wc.textView.textStorage!
        XCTAssertNil(storage.attribute(.underlineStyle, at: end + 1, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.editSegmentID, at: end + 1, effectiveRange: nil) as? String, a.uuidString)
    }

    func testRestoreFromTheCoreRerendersThatParagraph() async {
        let (core, wc) = make(.cloudOn)
        let a = dictate(core, "Alpha beta.")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "beta", replace: "Beta", reason: "name")]))
        await drainMainActor()
        XCTAssertEqual(wc.textView.string, "Alpha Beta.")
        core.restore(.original, segmentID: a)
        XCTAssertEqual(wc.textView.string, "Alpha beta.")
        XCTAssertNil(wc.textView.textStorage!.attribute(.underlineStyle, at: 6, effectiveRange: nil))
    }

    func testCompareCardsAppearOutsideTheText() async {
        let (core, wc) = make(.cloudOn)
        let a = dictate(core, "Alpha.")
        await drainMainActor()
        cleaner.finish(0, .success([]))
        await drainMainActor()
        XCTAssertTrue(core.startCompare(segmentID: a, models: [.sonnet, .opus]))
        XCTAssertFalse(wc.comparePanel.isHidden)
        XCTAssertEqual(wc.textView.string, "Alpha.", "candidates never enter the editable text")
        core.dismissCompare()
        XCTAssertTrue(wc.comparePanel.isHidden)
    }
}
