// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
// Fault injection uses private named pasteboards, never the system clipboard or real keys.
import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

final class PasteboardPublicationTests: XCTestCase {
    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.publication.\(UUID().uuidString)"))
        pb.clearContents()
        XCTAssertTrue(pb.setString("original", forType: .string))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }
    private func item(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }
    private func subject(_ pb: NSPasteboard) -> TextInserter {
        let inserter = TextInserter()
        inserter.pasteboard = pb
        inserter.userPasteGate = UserPasteRestoreGate()
        inserter.frontmostBundleIDProvider = { "com.microsoft.VSCode" }
        inserter.frontmostBundleURLProvider = { nil }
        inserter.frontmostPIDProvider = { 999_991 }
        inserter.focusedElementProvider = { nil }
        inserter.isSecureInputActive = { false }
        inserter.layoutVKeyCodeProvider = { 9 }
        inserter.pasteFieldReader = nil
        inserter.clipboardTrustReason = { nil }
        inserter.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        inserter.postPasteShortcut = { XCTFail("Failed publication must never send Cmd+V") }
        inserter.performUnicodeInsertion = { _ in XCTFail("Failure must show recovery text"); return false }
        inserter.executeAppleScript = { _ in XCTFail("Failed publication must never send remote paste"); return nil }
        return inserter
    }

    func testClearFailureDoesNotAttemptWriteOrChangeOriginal() {
        let pb = board()
        var writer = PasteboardWriter()
        writer.clear = { pb, _ in pb.changeCount }
        writer.write = { _, _ in XCTFail("Cannot publish after an unconfirmed clear"); return true }
        let result = writer.replace([item("replacement")], on: pb)
        XCTAssertNil(result.generation)
        XCTAssertEqual(result.failure, .clear)
        XCTAssertNil(result.recoveryGeneration)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testExternalGenerationBetweenClearAndWriteIsNeverWrittenOrRecovered() {
        let pb = board()
        var writer = PasteboardWriter()
        writer.clear = { pb, _ in
            let owned = pb.clearContents()
            pb.clearContents()
            pb.setString("external", forType: .string)
            return owned
        }
        writer.write = { _, _ in XCTFail("External clipboard must win"); return false }
        let result = writer.replace([item("replacement")], on: pb)
        XCTAssertEqual(result.failure, .changed)
        XCTAssertNil(result.recoveryGeneration)
        XCTAssertEqual(pb.string(forType: .string), "external")
    }

    func testFailedDictationPublicationRestoresOwnedOriginalAndShowsTextWithoutPaste() {
        let pb = board()
        let inserter = subject(pb)
        var writes = 0
        inserter.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? false : pb.writeObjects(items)
        }
        var recoveryText: String?
        inserter.onRemoteInsertionFailure = { text, message in
            recoveryText = text
            XCTAssertTrue(message.contains("restored"))
        }
        inserter.pasteViaClipboard("recover\nthis dictation")
        XCTAssertEqual(recoveryText, "recover\nthis dictation")
        XCTAssertEqual(pb.string(forType: .string), "original")
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
        XCTAssertFalse(inserter.userPasteGate.isWatching)
    }

    func testFailedDictationWriteNeverRecoversOverExternalGeneration() {
        let pb = board()
        let inserter = subject(pb)
        var writes = 0
        inserter.pasteboardWriter.write = { pb, _ in
            writes += 1
            pb.clearContents()
            pb.setString("external", forType: .string)
            return false
        }
        var shown = false
        inserter.onRemoteInsertionFailure = { _, _ in shown = true }
        inserter.pasteViaClipboard("dictation")
        XCTAssertTrue(shown)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(pb.string(forType: .string), "external")
    }

    func testReportedWriteSuccessAfterExternalReplacementStillCannotPaste() {
        let pb = board()
        let inserter = subject(pb)
        inserter.pasteboardWriter.write = { pb, _ in
            pb.clearContents()
            pb.setString("external", forType: .string)
            return true
        }
        inserter.onRemoteInsertionFailure = { _, _ in }
        inserter.pasteViaClipboard("dictation")
        XCTAssertEqual(pb.string(forType: .string), "external")
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
    }

    func testExplicitCopyFailureReturnsFalseAndRecoversOriginal() {
        let pb = board()
        let inserter = subject(pb)
        var writes = 0
        inserter.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? false : pb.writeObjects(items)
        }
        XCTAssertFalse(inserter.replaceClipboardForUser(with: [item("history entry")]))
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testTapRestoreFailureIsNotReportedAsRestored() {
        let pb = board()
        let gate = UserPasteRestoreGate()
        let saved = [[(NSPasteboard.PasteboardType.string, Data("saved".utf8))]]
        let token = gate.arm(pasteboard: pb, savedItems: saved, writtenChangeCount: pb.changeCount,
                             layoutVKeyCode: 9, restore: { _, _ in false }, onOutcome: { _ in })
        gate.markTrustedRead(token: token)
        let result = gate.handleKeyDown(type: .keyDown, keyCode: 9, flags: .maskCommand,
                                       userData: 0, sourcePID: 0, isAutorepeat: false)
        XCTAssertEqual(result, .restoreFailed(token: token))
        XCTAssertTrue(gate.claim(token: token), "A failed restore must not be treated as a completed restore")
        XCTAssertFalse(gate.isWatching)
    }

    func testCanaryFailedPublicationRecoversOriginalWithoutStartingOrClaimingClean() {
        let pb = board()
        let store = ClipboardTrustStore(fileURL: nil)
        var env = ClipboardCanary.Environment(pasteboard: pb, store: store)
        env.secondsSinceUserInput = { 1000 }
        env.runningBundleIDs = { [] }
        env.isScreenLocked = { true }
        env.quietClipboardInterval = 0
        env.writeGate = { $0() }
        env.pasteGate = nil
        var writes = 0
        env.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? false : pb.writeObjects(items)
        }
        let canary = ClipboardCanary(environment: env)
        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("publication-failed"))
        XCTAssertFalse(canary.isRunning)
        XCTAssertTrue(store.state.results.isEmpty)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testClearFailureKeepsOriginalAndShowsDictationWithoutCallingWrite() {
        let pb = board()
        let inserter = subject(pb)
        inserter.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        inserter.pasteboardWriter.write = { _, _ in XCTFail("Cannot write after failed clear"); return false }
        var recovered: String?
        inserter.onRemoteInsertionFailure = { text, _ in recovered = text }
        inserter.pasteViaClipboard("dictation")
        XCTAssertEqual(recovered, "dictation")
        XCTAssertEqual(pb.string(forType: .string), "original")
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
    }

    func testRecoveryRechecksOwnershipWhenExternalCopyArrivesBeforeRecoveryClear() {
        let pb = board()
        var writer = PasteboardWriter()
        writer.write = { _, _ in false }
        let result = writer.replace([item("replacement")], on: pb)
        XCTAssertNotNil(result.recoveryGeneration)
        pb.clearContents()
        pb.setString("new external copy", forType: .string)
        writer.clear = { _, _ in XCTFail("Recovery cannot clear a later generation"); return -1 }
        XCTAssertEqual(writer.recover([[(.string, Data("original".utf8))]], after: result, on: pb), .changed)
        XCTAssertEqual(pb.string(forType: .string), "new external copy")
    }

    func testSecureInputCopyFailureDoesNotClaimCopiedOrScheduleAutoClear() {
        let pb = board()
        let inserter = subject(pb)
        inserter.isSecureInputActive = { true }
        let report = CompatibilityReport()
        report.isEnabled = true
        inserter.compatibilityReport = report
        inserter.secureInputClipboardClearDelay = 0.01
        var writes = 0
        inserter.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? false : pb.writeObjects(items)
        }
        var recovered: String?
        inserter.onRemoteInsertionFailure = { text, _ in recovered = text }
        inserter.onSecureInputFallback = { _, _ in XCTFail("Cannot report copied after failed write") }
        XCTAssertFalse(inserter.insert(text: "secure dictation", onFocusLost: {
            XCTFail("Cannot report clipboard fallback after failed write")
        }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(recovered, "secure dictation")
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed])
        XCTAssertEqual(pb.string(forType: .string), "original")
        XCTAssertEqual(writes, 2)
    }

    func testBothPublicationAndRecoveryFailureStillSurfaceSelectableDictation() {
        let pb = board()
        let inserter = subject(pb)
        var writes = 0
        inserter.pasteboardWriter.write = { _, _ in writes += 1; return false }
        var recovered: String?
        inserter.onRemoteInsertionFailure = { text, message in
            recovered = text
            XCTAssertTrue(message.contains("refused to restore"))
        }
        inserter.pasteViaClipboard("still recoverable")
        XCTAssertEqual(recovered, "still recoverable")
        XCTAssertEqual(writes, 2, "Recovery is bounded; never loop on a failed server")
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
    }

    func testCanaryRestoreFailureIsInconclusiveAndDoesNotClaimRestored() {
        let pb = board()
        let store = ClipboardTrustStore(fileURL: nil)
        var env = ClipboardCanary.Environment(pasteboard: pb, store: store)
        env.secondsSinceUserInput = { 1000 }
        env.runningBundleIDs = { [] }
        env.isScreenLocked = { true }
        env.quietClipboardInterval = 0
        env.writeGate = { $0() }
        env.pasteGate = nil
        env.holdOverride = 0.01
        var writes = 0
        env.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? pb.writeObjects(items) : false
        }
        let canary = ClipboardCanary(environment: env)
        let finished = expectation(description: "failed restore recorded")
        canary.onFinish = { result in
            XCTAssertFalse(result.restored)
            XCTAssertEqual(result.outcome, .inconclusive)
            finished.fulfill()
        }
        XCTAssertEqual(canary.startIfDue(mode: .lock), .started)
        wait(for: [finished], timeout: 1)
    }


    func testExternalCopyDuringRecoveryIsReportedAsPreservedNotRefused() {
        let pb = board()
        let inserter = subject(pb)
        var clears = 0
        inserter.pasteboardWriter.clear = { pb, _ in
            clears += 1
            let owned = pb.clearContents()
            if clears == 2 {
                pb.clearContents()
                pb.setString("external", forType: .string)
            }
            return owned
        }
        inserter.pasteboardWriter.write = { _, _ in false }
        var shown = false
        inserter.onRemoteInsertionFailure = { _, message in
            shown = true
            XCTAssertTrue(message.contains("newer clipboard change was left alone"))
            XCTAssertFalse(message.contains("refused to restore"))
        }
        inserter.pasteViaClipboard("dictation")
        XCTAssertTrue(shown)
        XCTAssertEqual(pb.string(forType: .string), "external")
    }


    func testTimerRestoreRecordsFailureWhenPublicationIsRejected() {
        let pb = board()
        let inserter = subject(pb)
        var writes = 0
        inserter.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? pb.writeObjects(items) : false
        }
        inserter.restoreTiming = { _ in .init(backstop: 2, afterRead: 0.01) }
        inserter.postPasteShortcut = { _ = pb.string(forType: .string) }
        let finished = expectation(description: "failed timer restore recorded")
        inserter.onClipboardRestore = { record in
            XCTAssertFalse(record.restored)
            finished.fulfill()
        }
        inserter.pasteViaClipboard("dictation")
        wait(for: [finished], timeout: 1)
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
        XCTAssertEqual(writes, 2)
    }

    func testTapRestoreRecordsFailureInsteadOfSuccessInInserter() {
        let pb = board()
        let inserter = subject(pb)
        var writes = 0
        inserter.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? pb.writeObjects(items) : false
        }
        inserter.postPasteShortcut = { _ = pb.string(forType: .string) }
        let finished = expectation(description: "failed tap restore recorded")
        inserter.onClipboardRestore = { record in
            XCTAssertFalse(record.restored)
            finished.fulfill()
        }
        inserter.pasteViaClipboard("dictation")
        let outcome = inserter.userPasteGate.handleKeyDown(type: .keyDown, keyCode: 9, flags: .maskCommand,
                                                           userData: 0, sourcePID: 0, isAutorepeat: false)
        guard case .restoreFailed = outcome else { return XCTFail("Expected failed restore, got \(outcome)") }
        wait(for: [finished], timeout: 1)
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
        XCTAssertEqual(writes, 2)
    }


    func testFailedConcealedCopyWithoutSnapshotDoesNotClaimClipboardWasUnchanged() {
        let pb = board()
        let inserter = subject(pb)
        inserter.captureClipboardSnapshot = { _, _ in throw PasteboardAccess.Failure.tooLarge }
        inserter.pasteboardWriter.write = { _, _ in false }
        var shown = false
        inserter.onRemoteInsertionFailure = { _, message in
            shown = true
            XCTAssertTrue(message.contains("previous clipboard could not be preserved"))
            XCTAssertFalse(message.contains("clipboard was left alone"))
        }
        XCTAssertFalse(inserter.secureInputClipboardFallback("dictation"))
        XCTAssertTrue(shown)
    }


    func testExplicitCopyStillWorksWhenOriginalSnapshotIsUnavailable() {
        let pb = board()
        let inserter = subject(pb)
        inserter.captureClipboardSnapshot = { _, _ in throw PasteboardAccess.Failure.denied }
        XCTAssertTrue(inserter.replaceClipboardForUser(with: [item("chosen history entry")]))
        XCTAssertEqual(pb.string(forType: .string), "chosen history entry")
    }


    func testFocusLossCopyFailureIsReportedAsDeliveryFailedWithoutCopiedCallback() {
        let pb = board()
        let inserter = subject(pb)
        inserter.refocusElement = { _ in false }
        let report = CompatibilityReport()
        report.isEnabled = true
        inserter.compatibilityReport = report
        var writes = 0
        inserter.pasteboardWriter.write = { pb, items in
            writes += 1
            return writes == 1 ? false : pb.writeObjects(items)
        }
        var shown = false
        inserter.onRemoteInsertionFailure = { _, _ in shown = true }
        XCTAssertFalse(inserter.insert(text: "dictation", refocusing: AXUIElementCreateApplication(999_991),
                                       onFocusLost: { XCTFail("Failed copy must not claim copied") }))
        XCTAssertTrue(shown)
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed])
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testExternalCopyDuringPostPublicationSetupCancelsOnlyStaleBorrowBeforePaste() {
        let pb = board()
        let inserter = subject(pb)
        let initialGeneration = pb.changeCount
        var replaced = false
        // Target PID is captured after successful publication, before the shortcut.
        inserter.frontmostPIDProvider = {
            if !replaced, pb.changeCount != initialGeneration {
                replaced = true
                pb.clearContents()
                pb.setString("new external copy", forType: .string)
            }
            return 999_991
        }
        var shown = false
        inserter.onRemoteInsertionFailure = { text, message in
            shown = true
            XCTAssertEqual(text, "dictation")
            XCTAssertTrue(message.contains("clipboard changed before the paste"))
        }
        inserter.pasteViaClipboard("dictation")
        XCTAssertTrue(replaced)
        XCTAssertTrue(shown)
        XCTAssertEqual(pb.string(forType: .string), "new external copy")
        XCTAssertFalse(inserter.hasPendingClipboardBorrow)
        XCTAssertFalse(inserter.userPasteGate.isWatching)
        XCTAssertFalse(inserter.isWaitingForClipboardConsumption)
    }

}
