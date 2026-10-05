// ai-suggestion:unverified · session:unknown/agent:astra_capture_final · 2026-10-05
// Named pasteboards and injected input/AX only; never posts a real key or reads user data.
import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

@MainActor
final class HistoryPublicationTests: XCTestCase {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("speakfree.test.history-publication.\(UUID().uuidString)"))
        board.clearContents()
        XCTAssertTrue(board.setString("original", forType: .string))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func item(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }

    private func subject(_ board: NSPasteboard) -> TextInserter {
        let inserter = TextInserter()
        inserter.pasteboard = board
        inserter.isSecureInputActive = { false }
        inserter.frontmostBundleIDProvider = { "example.editor" }
        inserter.frontmostPIDProvider = { 999_991 }
        inserter.focusedElementProvider = { nil }
        inserter.layoutVKeyCodeProvider = { 9 }
        inserter.postPasteShortcut = { XCTFail("No paste expected") }
        inserter.performInsertion = { _ in XCTFail("History never enters dictation insertion") }
        inserter.executeAppleScript = { _ in XCTFail("No AppleScript expected"); return nil }
        inserter.onRemoteInsertionFailure = { _, _ in XCTFail("No recovery UI expected") }
        return inserter
    }

    func testExplicitCopyFailureRecoversOriginalWithoutSubmittingPaste() {
        let board = board(), inserter = subject(board)
        var writes = 0
        inserter.pasteboardWriter.write = { board, items in
            writes += 1
            return writes == 1 ? false : board.writeObjects(items)
        }
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(writes, 2)
    }

    func testExternalCopyDuringFailedPublicationIsNeverOverwrittenByRecovery() {
        let board = board(), inserter = subject(board)
        var writes = 0
        inserter.pasteboardWriter.write = { board, _ in
            writes += 1
            board.clearContents()
            board.setString("external", forType: .string)
            return false
        }
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "external")
        XCTAssertEqual(writes, 1)
    }

    func testUnconfirmedClearNeverCallsWrite() {
        let board = board(), inserter = subject(board)
        inserter.pasteboardWriter.clear = { board, _ in board.changeCount }
        inserter.pasteboardWriter.write = { _, _ in XCTFail("No confirmed clear"); return true }
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testExplicitSelectionPreservesExactRichBytesAndUsesOnlyReplayBoundary() {
        let board = board(), inserter = subject(board)
        let rich = item("  chosen\n")
        let rtf = Data(#"{\rtf1 chosen}"#.utf8)
        rich.setData(rtf, forType: .rtf)
        XCTAssertTrue(inserter.replaceClipboardForUser(with: [rich]))
        XCTAssertEqual(board.string(forType: .string), "  chosen\n")
        XCTAssertEqual(board.data(forType: .rtf), rtf)
        var pastes = 0
        inserter.postPasteShortcut = { pastes += 1 }
        XCTAssertTrue(inserter.pasteCurrentClipboard(expectedChangeCount: board.changeCount))
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(board.string(forType: .string), "  chosen\n")
    }

    func testFinalSubmissionRejectsChangedClipboardSecureInputAndRemoteApps() {
        let board = board(), inserter = subject(board)
        let before = board.changeCount
        board.clearContents()
        board.setString("new copy", forType: .string)
        XCTAssertFalse(inserter.pasteCurrentClipboard(expectedChangeCount: before))
        inserter.isSecureInputActive = { true }
        XCTAssertFalse(inserter.pasteCurrentClipboard(expectedChangeCount: board.changeCount))
        inserter.isSecureInputActive = { false }
        inserter.frontmostBundleIDProvider = { "com.microsoft.rdc.macos" }
        XCTAssertFalse(inserter.pasteCurrentClipboard(expectedChangeCount: board.changeCount))
    }

    func testQueuedRefocusBlocksHistoryPublicationUntilOriginalWorkCompletes() {
        let board = board(), inserter = subject(board)
        let target = AXUIElementCreateApplication(999_992)
        let inserted = expectation(description: "injected AX insertion")
        inserter.refocusElement = { _ in true }
        inserter.directAXInsert = { _, _ in inserted.fulfill(); return true }
        XCTAssertTrue(inserter.insert(text: "dictation", refocusing: target))
        XCTAssertTrue(inserter.hasDeferredInsertion)
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "original")
        wait(for: [inserted], timeout: 2)
        XCTAssertFalse(inserter.hasDeferredInsertion)
        XCTAssertTrue(inserter.replaceClipboardForUser(with: [item("chosen")]))
    }

    func testCurrentDictationBorrowBlocksHistoryButANewExternalCopyEndsOwnership() {
        let board = board(), inserter = subject(board)
        // Select the existing remote path solely to inject its AppleScript call.
        // No NSWorkspace query, Accessibility IPC, or real key event is used.
        inserter.frontmostBundleIDProvider = { "com.microsoft.rdc.macos" }
        let submitted = expectation(description: "injected remote submission")
        inserter.executeAppleScript = { _ in submitted.fulfill(); return nil }
        inserter.pasteViaClipboard("pending dictation")
        XCTAssertTrue(inserter.hasDeferredInsertion)
        XCTAssertTrue(inserter.ownsCurrentClipboard)
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("chosen")]))
        wait(for: [submitted], timeout: 2)
        XCTAssertFalse(inserter.hasDeferredInsertion)
        XCTAssertTrue(inserter.isWaitingForClipboardConsumption,
                      "Main's existing backstop still owns this clipboard; no new early restore policy")
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("chosen")]))
        board.clearContents()
        board.setString("external copy", forType: .string)
        XCTAssertFalse(inserter.ownsCurrentClipboard)
        XCTAssertTrue(inserter.replaceClipboardForUser(with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "chosen")
    }

    func testRestorePublishesExactGenerationSoMonitorCanIgnoreIt() {
        let board = board(), inserter = subject(board)
        var receipt: Int?
        let observer = NotificationCenter.default.addObserver(forName: PasteboardWriteReceipt.notification,
            object: nil, queue: .main) { note in
                if note.userInfo?["name"] as? String == board.name.rawValue {
                    receipt = note.userInfo?["changeCount"] as? Int
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        inserter.restorePasteboardForTest(board, items: [[(.string, Data("restored".utf8))]])
        XCTAssertEqual(receipt, board.changeCount)
        XCTAssertEqual(board.string(forType: .string), "restored")
    }
}
