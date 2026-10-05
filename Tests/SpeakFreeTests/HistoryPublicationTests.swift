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
        // Eager named test boards only. Blocked-provider tests below use the real worker.
        inserter.clipboardPreparation = PasteboardPreparation(executeRead: { $0() })
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

    private func replace(_ inserter: TextInserter, with items: [NSPasteboardItem]) -> Bool {
        var written = false
        inserter.prepareClipboardForUser { result in
            if case .success(let prepared) = result {
                written = inserter.replaceClipboardForUser(with: items, prepared: prepared) != nil
            }
        }
        return written
    }

    func testExplicitReplacementAcceptsPreviousHistoryItemLargerThanDictationCap() {
        let board = board(), inserter = subject(board)
        let payload = Data(repeating: 7, count: 20 * 1_024 * 1_024)
        board.clearContents()
        XCTAssertTrue(board.setData(payload, forType: .png))
        XCTAssertTrue(replace(inserter, with: [item("next selection")]))
        XCTAssertEqual(board.string(forType: .string), "next selection")
    }

    func testExplicitReplacementOfOversizedClipboardUsesChosenItemWithoutRollback() {
        let board = board(), inserter = subject(board)
        let payload = Data(repeating: 8, count: TextInserter.maxExplicitReplacementBytes + 1)
        board.clearContents()
        XCTAssertTrue(board.setData(payload, forType: .png))
        XCTAssertTrue(replace(inserter, with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "chosen")
    }

    func testExplicitCopyFailureRecoversOriginalWithoutSubmittingPaste() {
        let board = board(), inserter = subject(board)
        var writes = 0
        var localOnly: [Bool] = []
        inserter.pasteboardWriter.clear = { board, hostOnly in
            localOnly.append(hostOnly)
            return board.clearContents()
        }
        inserter.pasteboardWriter.write = { board, items in
            writes += 1
            return writes == 1 ? false : board.writeObjects(items)
        }
        XCTAssertFalse(replace(inserter, with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(localOnly, [true, true], "Both History publication and recovery stay local")
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
        XCTAssertFalse(replace(inserter, with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "external")
        XCTAssertEqual(writes, 1)
    }

    func testUnconfirmedClearNeverCallsWrite() {
        let board = board(), inserter = subject(board)
        inserter.pasteboardWriter.clear = { board, _ in board.changeCount }
        inserter.pasteboardWriter.write = { _, _ in XCTFail("No confirmed clear"); return true }
        XCTAssertFalse(replace(inserter, with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testExplicitSelectionPreservesExactRichBytesAndUsesOnlyReplayBoundary() {
        let board = board(), inserter = subject(board)
        let rich = item("  chosen\n")
        let rtf = Data(#"{\rtf1 chosen}"#.utf8)
        rich.setData(rtf, forType: .rtf)
        XCTAssertTrue(replace(inserter, with: [rich]))
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
        XCTAssertFalse(replace(inserter, with: [item("chosen")]))
        XCTAssertEqual(board.string(forType: .string), "original")
        wait(for: [inserted], timeout: 2)
        XCTAssertFalse(inserter.hasDeferredInsertion)
        XCTAssertTrue(replace(inserter, with: [item("chosen")]))
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
        XCTAssertFalse(replace(inserter, with: [item("chosen")]))
        wait(for: [submitted], timeout: 2)
        XCTAssertFalse(inserter.hasDeferredInsertion)
        XCTAssertTrue(inserter.isWaitingForClipboardConsumption,
                      "Main's existing backstop still owns this clipboard; no new early restore policy")
        XCTAssertFalse(replace(inserter, with: [item("chosen")]))
        board.clearContents()
        board.setString("external copy", forType: .string)
        XCTAssertFalse(inserter.ownsCurrentClipboard)
        XCTAssertTrue(replace(inserter, with: [item("chosen")]))
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

    func testBlockedRollbackProviderDoesNotBlockExplicitCopyOrSpawnMoreReaders() throws {
        let board = board(), inserter = subject(board)
        let worker = DispatchQueue(label: "test.clipboard.blocked-provider")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = expectation(description: "provider entered off-main")
        var timeout: DispatchWorkItem?
        let service = PasteboardPreparation(executeRead: { worker.async(execute: $0) },
            scheduleTimeout: { timeout = $0 }, read: { board, limit, cancelled in
                XCTAssertFalse(Thread.isMainThread)
                return try PasteboardAccess.snapshot(board, maximumBytes: limit, cancelled: cancelled,
                    read: { item, type in
                        entered.fulfill()
                        release.wait()
                        return item.data(forType: type)
                    })
            })
        inserter.clipboardPreparation = service
        let before = board.changeCount
        var completions = 0
        inserter.prepareClipboardForUser { result in
            completions += 1
            guard case .success(let prepared) = result else { XCTFail("Explicit Copy must survive a hung previous owner"); return }
            XCTAssertNil(prepared.snapshot)
            XCTAssertNotNil(inserter.replaceClipboardForUser(with: [self.item("chosen")], prepared: prepared))
        }
        wait(for: [entered], timeout: 2)
        let responsive = expectation(description: "main remains responsive while provider blocks")
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 1)
        try XCTUnwrap(timeout).perform()
        XCTAssertEqual(completions, 1)
        XCTAssertNotEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "chosen")
        for index in 0..<5 {
            XCTAssertNotNil(inserter.prepareClipboardForUser { result in
                guard case .success(let prepared) = result else { XCTFail("Copy must remain available"); return }
                XCTAssertNil(prepared.snapshot, "The occupied worker must not start another reader")
                XCTAssertNotNil(inserter.replaceClipboardForUser(with: [self.item("next \(index)")], prepared: prepared))
            })
        }
        let lastGeneration = board.changeCount
        release.signal()
        let drained = expectation(description: "late provider response discarded")
        worker.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(completions, 1, "Late response must not deliver a second authorization")
        XCTAssertEqual(board.changeCount, lastGeneration)
        XCTAssertEqual(board.string(forType: .string), "next 4")
    }

    func testUnreadableRollbackAllowsExplicitCopyButExternalGenerationStillWins() {
        for changed in [false, true] {
            let board = board(), inserter = subject(board)
            var readWork: (() -> Void)?
            inserter.clipboardPreparation = PasteboardPreparation(executeRead: { readWork = $0 },
                scheduleTimeout: { _ in }, read: { _, _, _ in throw PasteboardAccess.Failure.unreadable })
            var failed = false
            inserter.prepareClipboardForUser { result in
                switch result {
                case .failure: failed = true
                case .success(let prepared):
                    XCTAssertFalse(changed)
                    XCTAssertNil(prepared.snapshot)
                    XCTAssertNotNil(inserter.replaceClipboardForUser(with: [self.item("chosen")], prepared: prepared))
                }
            }
            if changed {
                board.clearContents()
                board.setString("external", forType: .string)
            }
            let generation = board.changeCount
            readWork?()
            XCTAssertEqual(failed, changed)
            if changed { XCTAssertEqual(board.changeCount, generation) }
            XCTAssertEqual(board.string(forType: .string), changed ? "external" : "chosen")
        }
    }

    func testTimedOutRollbackCannotReplaceExternalCopyOrCancelledRequest() throws {
        for cancelled in [false, true] {
            let board = board(), inserter = subject(board)
            var timeout: DispatchWorkItem?
            inserter.clipboardPreparation = PasteboardPreparation(executeRead: { _ in },
                scheduleTimeout: { timeout = $0 })
            var failures = 0
            let request = inserter.prepareClipboardForUser { result in
                guard case .failure = result else { XCTFail("Stale or cancelled intent must not publish"); return }
                failures += 1
            }
            if cancelled { request?.cancel() }
            else { board.clearContents(); board.setString("external", forType: .string) }
            let generation = board.changeCount
            try XCTUnwrap(timeout).perform()
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(board.changeCount, generation)
            XCTAssertEqual(board.string(forType: .string), cancelled ? "original" : "external")
        }
    }

    func testPreparedSnapshotCannotReplaceNewBorrowOrCancelledRequest() throws {
        let board = board(), inserter = subject(board)
        var prepared: PasteboardPreparation.Prepared?
        let request = inserter.prepareClipboardForUser { if case .success(let value) = $0 { prepared = value } }
        request?.cancel()
        XCTAssertNil(inserter.replaceClipboardForUser(with: [item("chosen")], prepared: try XCTUnwrap(prepared)))
        XCTAssertEqual(board.string(forType: .string), "original")

        inserter.prepareClipboardForUser { if case .success(let value) = $0 { prepared = value } }
        inserter.frontmostBundleIDProvider = { "com.microsoft.rdc.macos" }
        let submitted = expectation(description: "injected new dictation")
        inserter.executeAppleScript = { _ in submitted.fulfill(); return nil }
        inserter.pasteViaClipboard("new dictation")
        XCTAssertNil(inserter.replaceClipboardForUser(with: [item("chosen")], prepared: try XCTUnwrap(prepared)))
        XCTAssertEqual(board.string(forType: .string), "new dictation")
        wait(for: [submitted], timeout: 2)
    }

    func testRemoteOfferNeverMaterializesBeforeExplicitLocalOnlyReplacement() throws {
        final class RemoteProvider: NSObject, NSPasteboardItemDataProvider {
            var reads = 0
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {
                reads += 1
                item.setString("remote payload", forType: type)
            }
        }
        let board = board(), inserter = subject(board)
        let provider = RemoteProvider(), remote = NSPasteboardItem()
        remote.setData(Data(), forType: PasteboardAccess.remoteClipboardType)
        remote.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        XCTAssertTrue(board.writeObjects([remote]))
        var prepared: PasteboardPreparation.Prepared?
        inserter.prepareClipboardForUser { if case .success(let value) = $0 { prepared = value } }
        let ready = try XCTUnwrap(prepared)
        XCTAssertNil(ready.snapshot, "A remote offer is deliberately not fetched for rollback")
        XCTAssertEqual(provider.reads, 0)
        var localOnly = false
        inserter.pasteboardWriter.clear = { board, hostOnly in
            localOnly = hostOnly
            return board.prepareForNewContents(with: .currentHostOnly)
        }
        XCTAssertNotNil(inserter.replaceClipboardForUser(with: [item("local choice")], prepared: ready))
        XCTAssertTrue(localOnly)
        XCTAssertEqual(provider.reads, 0)
        XCTAssertEqual(board.string(forType: .string), "local choice")
    }

    func testRemoteOfferFailedPublicationDoesNotPretendRollbackIsAvailable() throws {
        let board = board(), inserter = subject(board)
        let remote = item("remote fixture")
        remote.setData(Data(), forType: PasteboardAccess.remoteClipboardType)
        board.clearContents()
        board.writeObjects([remote])
        var prepared: PasteboardPreparation.Prepared?
        inserter.prepareClipboardForUser { if case .success(let value) = $0 { prepared = value } }
        var writes = 0
        inserter.pasteboardWriter.write = { _, _ in writes += 1; return false }
        XCTAssertNil(inserter.replaceClipboardForUser(with: [item("local choice")], prepared: try XCTUnwrap(prepared)))
        XCTAssertEqual(writes, 1, "No fabricated snapshot can restore an unmaterialized remote offer")
    }

    func testLaterRemoteItemPreventsAllPayloadReadsEvenWhenRootOmitsMarker() throws {
        let board = board(), inserter = subject(board)
        let local = item("first local item"), remote = item("second remote item")
        remote.setData(Data(), forType: PasteboardAccess.remoteClipboardType)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([local, remote]))
        var reads = 0
        inserter.clipboardPreparation = PasteboardPreparation(executeRead: { $0() },
            offeredTypes: { board in
                // Model a root offer that only describes the first item.
                [[.string]] + (board.pasteboardItems ?? []).map(\.types)
            }, read: { _, _, _ in
                reads += 1
                XCTFail("No local or remote payload may be read after any remote marker")
                return []
            })
        var prepared: PasteboardPreparation.Prepared?
        inserter.prepareClipboardForUser { if case .success(let value) = $0 { prepared = value } }
        let ready = try XCTUnwrap(prepared)
        XCTAssertNil(ready.snapshot)
        XCTAssertEqual(reads, 0)
        XCTAssertNotNil(inserter.replaceClipboardForUser(with: [item("chosen")], prepared: ready))
        XCTAssertEqual(board.string(forType: .string), "chosen")
    }
}
