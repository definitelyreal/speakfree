// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_races · 2026-10-01
// Adversarial code-aware tests. No general clipboard reads/writes, posted events, AX IPC,
// real history, permissions, or microphone access. Ordering assertions are not benchmarks.
import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import SpeakFreeLib

final class ClipboardCitizenshipTests: XCTestCase {
    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.citizenship.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func write(_ text: String, to pb: NSPasteboard) {
        pb.clearContents()
        XCTAssertTrue(pb.setString(text, forType: .string))
    }

    private func inserter(_ pb: NSPasteboard) -> TextInserter {
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
        // Tests drive the event order explicitly; a scheduled restore must not race the oracle.
        inserter.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        inserter.postPasteShortcut = {}
        inserter.performUnicodeInsertion = { _ in
            XCTFail("Unexpected typing fallback")
            return false
        }
        inserter.executeAppleScript = { _ in
            XCTFail("Unexpected AppleScript")
            return ["NSAppleScriptErrorNumber": -1]
        }
        inserter.onRemoteInsertionFailure = { _, _ in XCTFail("Unexpected insertion failure") }
        return inserter
    }

    private func pressPaste(_ gate: UserPasteRestoreGate) -> UserPasteRestoreGate.Outcome {
        gate.handleKeyDown(type: .keyDown, keyCode: 9, flags: .maskCommand,
                           userData: 0, sourcePID: 0, isAutorepeat: false)
    }

    private func assertSkipped(_ outcome: UserPasteRestoreGate.Outcome,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .skipped = outcome else {
            return XCTFail("Uncertain receipt must leave the dictated text available; got \(outcome)",
                           file: file, line: line)
        }
    }

    func testImmediateUserPasteAfterTargetReadRestoresRichOriginalBeforeReturning() {
        let pb = board()
        let original = NSPasteboardItem()
        let rtf = Data("{\\rtf1 rich original}".utf8)
        original.setString("rich original", forType: .string)
        original.setData(rtf, forType: .rtf)
        XCTAssertTrue(pb.writeObjects([original]))
        let subject = inserter(pb)
        var targetRead: String?
        subject.postPasteShortcut = { targetRead = pb.string(forType: .string) }

        subject.pasteViaClipboard("dictation")
        let outcome = pressPaste(subject.userPasteGate)

        guard case .restored = outcome else { return XCTFail("Expected immediate restore, got \(outcome)") }
        XCTAssertEqual(targetRead, "dictation")
        XCTAssertEqual(pb.string(forType: .string), "rich original")
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
        // No main-queue callback or restore timer has been allowed to run at this point.
        XCTAssertFalse(subject.userPasteGate.isWatching)
    }

    func testUserPasteBeforeAnyReadCannotReplacePendingDictationWithPrivateOriginal() {
        let pb = board()
        write("private original", to: pb)
        let subject = inserter(pb)
        subject.pasteViaClipboard("dictation")

        assertSkipped(pressPaste(subject.userPasteGate))
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func testReaderBecomingUntrustedAfterWriteCannotAuthorizeUserPasteRestore() {
        let pb = board()
        write("private original", to: pb)
        let subject = inserter(pb)
        var reason: String?
        subject.clipboardTrustReason = { reason }
        subject.pasteViaClipboard("dictation")

        reason = "syncer:com.vmware.fusion"
        XCTAssertEqual(pb.string(forType: .string), "dictation", "the newly running syncer reads first")

        assertSkipped(pressPaste(subject.userPasteGate))
        XCTAssertEqual(pb.string(forType: .string), "dictation", "the target still needs this text")
    }

    func testUnknownFrontmostIdentityAtReadCannotAuthorizeUserPasteRestore() {
        let pb = board()
        write("private original", to: pb)
        let subject = inserter(pb)
        var pid: pid_t? = 999_991
        subject.frontmostPIDProvider = { pid }
        subject.pasteViaClipboard("dictation")

        pid = nil
        XCTAssertEqual(pb.string(forType: .string), "dictation")

        assertSkipped(pressPaste(subject.userPasteGate))
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func testUnknownTargetIdentityCannotAuthorizeUserPasteRestore() {
        let pb = board()
        write("private original", to: pb)
        let subject = inserter(pb)
        subject.frontmostPIDProvider = { nil }
        subject.pasteViaClipboard("dictation")
        XCTAssertEqual(pb.string(forType: .string), "dictation")

        assertSkipped(pressPaste(subject.userPasteGate))
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func testFocusDriftAtReadCannotAuthorizeUserPasteRestore() {
        let pb = board()
        write("private original", to: pb)
        let subject = inserter(pb)
        var pid: pid_t? = 999_991
        subject.frontmostPIDProvider = { pid }
        subject.pasteViaClipboard("dictation")
        pid = 999_992
        XCTAssertEqual(pb.string(forType: .string), "dictation")

        assertSkipped(pressPaste(subject.userPasteGate))
        XCTAssertEqual(pb.string(forType: .string), "dictation")
    }

    func testExplicitRichCopyAfterTrustedReadSupersedesBorrowAndStaleReceiptImmediately() throws {
        let pb = board()
        write("old original", to: pb)
        let subject = inserter(pb)
        subject.postPasteShortcut = { _ = pb.string(forType: .string) }
        subject.pasteViaClipboard("old dictation")
        let oldProvider = try XCTUnwrap(subject.pendingDictationProviderForTest)
        let item = NSPasteboardItem()
        let png = Data([137, 80, 78, 71, 0, 255])
        item.setData(png, forType: .png)

        XCTAssertFalse(subject.isWaitingForClipboardConsumption)
        XCTAssertTrue(subject.replaceClipboardForUser(with: [item]), "no after-read timer has fired")
        let generation = pb.changeCount
        oldProvider.onRead?() // queued callback from the obsolete borrow

        XCTAssertFalse(subject.hasPendingClipboardBorrow)
        XCTAssertFalse(subject.userPasteGate.isWatching)
        XCTAssertEqual(pressPaste(subject.userPasteGate), .idle)
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.data(forType: .png), png)
        XCTAssertNil(pb.string(forType: .string), "no old dictation or text normalization")
    }

    private func verifyBlockedReplacementKeepsBorrow(bundle: String = "com.microsoft.VSCode",
                                                     trustReason: String? = nil,
                                                     consume: Bool = false,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        subject.frontmostBundleIDProvider = { bundle }
        subject.clipboardTrustReason = { trustReason }
        subject.restoreTiming = { route in .init(backstop: 0.03, afterRead: route == .remote ? nil : 0.02) }
        // Remote paste runs later than this test's deliberately shortened backstop. Any late
        // recovery stays in this no-op seam; no AppleScript or real notification is allowed.
        subject.onRemoteInsertionFailure = { _, _ in }
        subject.executeAppleScript = { _ in nil }
        let restored = expectation(description: "original backstop still runs")
        subject.onClipboardRestore = { record in
            XCTAssertEqual(record.trigger, "backstop", file: file, line: line)
            XCTAssertTrue(record.restored, file: file, line: line)
            restored.fulfill()
        }
        subject.pasteViaClipboard("dictation")
        if consume { XCTAssertEqual(pb.string(forType: .string), "dictation", file: file, line: line) }
        let generation = pb.changeCount
        let provider = subject.pendingDictationProviderForTest
        let watching = subject.userPasteGate.isWatching
        let selected = NSPasteboardItem()
        selected.setString("selected item", forType: .string)

        XCTAssertTrue(subject.isWaitingForClipboardConsumption, file: file, line: line)
        XCTAssertFalse(subject.replaceClipboardForUser(with: [selected]), file: file, line: line)

        XCTAssertEqual(pb.changeCount, generation, file: file, line: line)
        XCTAssertTrue(subject.pendingDictationProviderForTest === provider, file: file, line: line)
        XCTAssertTrue(subject.hasPendingClipboardBorrow, file: file, line: line)
        XCTAssertEqual(subject.userPasteGate.isWatching, watching, file: file, line: line)
        XCTAssertEqual(TextInserter.withOwnPasteboardRead { pb.string(forType: .string) },
                       "dictation", file: file, line: line)
        wait(for: [restored], timeout: 10)
        XCTAssertEqual(pb.string(forType: .string), "original", file: file, line: line)
        XCTAssertFalse(subject.isWaitingForClipboardConsumption, file: file, line: line)
    }

    func testExplicitCopyBeforeDictationReadKeepsBytesGateAndBackstop() {
        verifyBlockedReplacementKeepsBorrow()
    }

    func testExplicitCopyAfterUntrustedReadKeepsBytesGateAndBackstop() {
        verifyBlockedReplacementKeepsBorrow(trustReason: "unknown-reader:test", consume: true)
    }

    func testExplicitCopyDuringRemoteBorrowKeepsBytesAndBackstop() {
        verifyBlockedReplacementKeepsBorrow(bundle: "com.splashtop.stp.macosx", consume: true)
    }

    func testExplicitCopyRechecksTrustAfterEarlierTrustedReceipt() {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        var trustReason: String?
        subject.clipboardTrustReason = { trustReason }
        subject.postPasteShortcut = { _ = pb.string(forType: .string) }
        subject.pasteViaClipboard("dictation")
        XCTAssertFalse(subject.isWaitingForClipboardConsumption)
        let generation = pb.changeCount
        trustReason = "new-reader:test"
        let selected = NSPasteboardItem()
        selected.setString("selected item", forType: .string)

        XCTAssertTrue(subject.isWaitingForClipboardConsumption)
        XCTAssertFalse(subject.replaceClipboardForUser(with: [selected]))

        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "dictation")
        XCTAssertTrue(subject.hasPendingClipboardBorrow)
        XCTAssertTrue(subject.userPasteGate.isWatching)
    }

    func testAcceptedExplicitCopyCancelsOldTimerBeforeAnotherBorrowStarts() {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        subject.restoreTiming = { _ in .init(backstop: 0.04, afterRead: 0.02) }
        subject.postPasteShortcut = { _ = pb.string(forType: .string) }
        subject.pasteViaClipboard("first dictation")
        let selected = NSPasteboardItem()
        selected.setString("selected item", forType: .string)
        XCTAssertTrue(subject.replaceClipboardForUser(with: [selected]))
        subject.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        subject.postPasteShortcut = {}
        subject.onClipboardRestore = { _ in XCTFail("The retired timer must not restore the newer borrow") }
        subject.pasteViaClipboard("second dictation")
        let oldDeadlinePassed = expectation(description: "retired timer deadline passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { oldDeadlinePassed.fulfill() }

        wait(for: [oldDeadlinePassed], timeout: 10)

        XCTAssertTrue(subject.hasPendingClipboardBorrow)
        XCTAssertTrue(subject.isWaitingForClipboardConsumption)
        XCTAssertEqual(TextInserter.withOwnPasteboardRead { pb.string(forType: .string) }, "second dictation")
    }

    func testExplicitCopyCannotOvertakeDeferredRefocusInsertion() {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        subject.refocusElement = { _ in true }
        let finished = expectation(description: "deferred insertion completed")
        subject.performInsertion = { text in
            XCTAssertEqual(text, "dictation")
            XCTAssertTrue(subject.hasDeferredInsertion)
            finished.fulfill()
        }
        let selected = NSPasteboardItem()
        selected.setString("selected item", forType: .string)
        let generation = pb.changeCount

        let target = AXUIElementCreateApplication(999_991)
        XCTAssertTrue(subject.insert(text: "dictation", refocusing: target))
        subject.focusedElementProvider = { target }
        XCTAssertTrue(subject.hasDeferredInsertion)
        XCTAssertTrue(subject.isWaitingForClipboardConsumption)
        XCTAssertFalse(subject.replaceClipboardForUser(with: [selected]))
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "original")

        wait(for: [finished], timeout: 10)

        XCTAssertFalse(subject.hasDeferredInsertion)
        XCTAssertFalse(subject.isWaitingForClipboardConsumption)
        XCTAssertTrue(subject.replaceClipboardForUser(with: [selected]))
        XCTAssertEqual(pb.string(forType: .string), "selected item")
        subject.performInsertion = nil
    }

    func testDeferredInsertionCountSurvivesOverlappingCallbacks() {
        let pb = board()
        let subject = inserter(pb)
        subject.refocusElement = { _ in true }
        let finished = expectation(description: "both deferred callbacks completed")
        finished.expectedFulfillmentCount = 2
        subject.performInsertion = { _ in
            XCTAssertTrue(subject.hasDeferredInsertion, "the first callback cannot clear the second's ownership")
            finished.fulfill()
        }
        let element = AXUIElementCreateApplication(999_991)

        XCTAssertTrue(subject.insert(text: "first", refocusing: element))
        XCTAssertTrue(subject.insert(text: "second", refocusing: element))
        subject.focusedElementProvider = { element }
        wait(for: [finished], timeout: 10)

        XCTAssertFalse(subject.hasDeferredInsertion)
        XCTAssertFalse(subject.isWaitingForClipboardConsumption)
        subject.performInsertion = nil
    }

    func testDeferredInsertionOwnershipClearsOnSecureInputEarlyReturn() {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        subject.refocusElement = { _ in true }
        var secure = false
        subject.isSecureInputActive = { secure }
        subject.performInsertion = { _ in XCTFail("Secure input must prevent insertion") }
        let finished = expectation(description: "secure fallback completed")
        subject.onSecureInputFallback = { _, _ in finished.fulfill() }
        XCTAssertTrue(subject.insert(text: "dictation", refocusing: AXUIElementCreateApplication(999_991)))
        XCTAssertTrue(subject.hasDeferredInsertion)
        secure = true

        wait(for: [finished], timeout: 10)

        XCTAssertFalse(subject.hasDeferredInsertion)
        XCTAssertFalse(subject.isWaitingForClipboardConsumption)
        XCTAssertEqual(pb.string(forType: .string), "dictation", "existing concealed fallback stays unchanged")
    }

    func testExternalRichCopyWinsEvenWhenTapOutcomeDeliveryIsDelayed() {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        subject.postPasteShortcut = { _ = pb.string(forType: .string) }
        subject.pasteViaClipboard("dictation")
        guard case .restored = pressPaste(subject.userPasteGate) else {
            return XCTFail("Expected synchronous gate restore")
        }
        let fresh = NSPasteboardItem()
        let payload = Data([0, 1, 255, 2])
        fresh.setData(payload, forType: .png)
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([fresh]))
        let generation = pb.changeCount
        let delivered = expectation(description: "queued tap outcome delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 10)

        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.data(forType: .png), payload)
        XCTAssertFalse(subject.hasPendingClipboardBorrow)
    }

    func testIncompleteRichClipboardFallsBackWithoutDestroyingAnyRepresentation() {
        final class MissingRepresentation: NSObject, NSPasteboardItemDataProvider {
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {}
        }
        let pb = board()
        let missing = MissingRepresentation()
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setDataProvider(missing, forTypes: [.rtf])
        XCTAssertTrue(pb.writeObjects([original]))
        let generation = pb.changeCount
        let subject = inserter(pb)
        var typed: [String] = []
        var pasted = false
        subject.performUnicodeInsertion = { typed.append($0); return true }
        subject.postPasteShortcut = { pasted = true }

        subject.pasteViaClipboard("dictation")

        XCTAssertEqual(typed, ["dictation"])
        XCTAssertFalse(pasted)
        XCTAssertFalse(subject.hasPendingClipboardBorrow)
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "original")
        XCTAssertTrue(pb.types?.contains(.rtf) == true)
        withExtendedLifetime(missing) {}
    }

    func testNewCopyDuringTrustEvaluationCannotBeOverwrittenByDictation() {
        let pb = board()
        write("old original", to: pb)
        let subject = inserter(pb)
        var typed: [String] = []
        var pasted = false
        var trustChecks = 0
        subject.performUnicodeInsertion = { typed.append($0); return true }
        subject.postPasteShortcut = { pasted = true }
        subject.onRemoteInsertionFailure = { _, _ in } // preserving text for recovery is also safe
        subject.clipboardTrustReason = {
            trustChecks += 1
            pb.clearContents()
            pb.setString("fresh user copy", forType: .string)
            return nil
        }

        subject.pasteViaClipboard("dictation")

        XCTAssertEqual(pb.string(forType: .string), "fresh user copy")
        XCTAssertFalse(pasted, "the snapshot became stale before speakfree's write")
        XCTAssertFalse(subject.hasPendingClipboardBorrow)
        XCTAssertEqual(trustChecks, 2, "only one retry, even when every attempt sees a newer copy")
        XCTAssertEqual(typed, ["dictation"], "exhausted retry still gets the safe single-line fallback")
    }

    func testChangedSnapshotRetriesOnceAndRestoresTheFreshCopy() {
        let pb = board()
        write("old original", to: pb)
        let subject = inserter(pb)
        var snapshots = 0
        subject.captureClipboardSnapshot = { pb, limit in
            snapshots += 1
            if snapshots == 1 {
                pb.clearContents()
                pb.setString("fresh user copy", forType: .string)
                throw PasteboardAccess.Failure.changed
            }
            return try PasteboardAccess.snapshot(pb, maximumBytes: limit)
        }
        var targetText: String?
        subject.postPasteShortcut = { targetText = pb.string(forType: .string) }

        subject.pasteViaClipboard("dictation")

        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(targetText, "dictation")
        guard case .restored = pressPaste(subject.userPasteGate) else { return XCTFail("Expected restore") }
        XCTAssertEqual(pb.string(forType: .string), "fresh user copy", "retry owns the newer snapshot")
    }

    func testOneLateGenerationChangeRetriesAndRestoresTheFreshCopy() {
        let pb = board()
        write("old original", to: pb)
        let subject = inserter(pb)
        var trustChecks = 0
        subject.clipboardTrustReason = {
            trustChecks += 1
            if trustChecks == 1 {
                pb.clearContents()
                pb.setString("fresh user copy", forType: .string)
            }
            return nil
        }
        var pastes = 0
        subject.postPasteShortcut = { pastes += 1 }

        subject.pasteViaClipboard("dictation")

        XCTAssertEqual(trustChecks, 2)
        XCTAssertEqual(pastes, 1, "the first attempt never posted a shortcut")
        XCTAssertEqual(pb.string(forType: .string), "dictation")
        guard case .restored = pressPaste(subject.userPasteGate) else { return XCTFail("Expected restore") }
        XCTAssertEqual(pb.string(forType: .string), "fresh user copy")
    }

    func testSnapshotAndLateChangesShareOneRetryBudget() {
        let pb = board()
        write("original", to: pb)
        let subject = inserter(pb)
        var snapshots = 0
        subject.captureClipboardSnapshot = { pb, limit in
            snapshots += 1
            if snapshots == 1 { throw PasteboardAccess.Failure.changed }
            return try PasteboardAccess.snapshot(pb, maximumBytes: limit)
        }
        subject.clipboardTrustReason = {
            pb.clearContents()
            pb.setString("fresh user copy", forType: .string)
            return nil
        }
        var typed: [String] = []
        subject.performUnicodeInsertion = { typed.append($0); return true }
        subject.postPasteShortcut = { XCTFail("No shortcut may precede a complete stable snapshot") }

        subject.pasteViaClipboard("dictation")

        XCTAssertEqual(snapshots, 2, "the late mismatch cannot obtain a second retry")
        XCTAssertEqual(typed, ["dictation"])
        XCTAssertEqual(pb.string(forType: .string), "fresh user copy")
        XCTAssertFalse(subject.hasPendingClipboardBorrow)
    }

    func testTwoChangedSnapshotsFallBackWithoutUnboundedRetry() {
        let pb = board()
        write("original", to: pb)
        let generation = pb.changeCount
        let subject = inserter(pb)
        var snapshots = 0
        subject.captureClipboardSnapshot = { _, _ in
            snapshots += 1
            throw PasteboardAccess.Failure.changed
        }
        var typed: [String] = []
        subject.performUnicodeInsertion = { typed.append($0); return true }
        subject.postPasteShortcut = { XCTFail("Unstable clipboard must not be borrowed") }

        subject.pasteViaClipboard("dictation")

        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(typed, ["dictation"])
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testUnsafeSnapshotFailuresNeverRetryOrDestroyClipboardButMayTypeSingleLine() {
        for failure in [PasteboardAccess.Failure.denied, .unreadable, .tooLarge] {
            let pb = board()
            write("original", to: pb)
            let generation = pb.changeCount
            let subject = inserter(pb)
            var snapshots = 0
            subject.captureClipboardSnapshot = { _, _ in snapshots += 1; throw failure }
            var typed: [String] = []
            subject.performUnicodeInsertion = { typed.append($0); return true }
            subject.postPasteShortcut = { XCTFail("Unsafe snapshot must never permit a paste") }

            subject.pasteViaClipboard("safe single line")

            XCTAssertEqual(snapshots, 1, "only a changing generation permits a retry")
            XCTAssertEqual(typed, ["safe single line"])
            XCTAssertEqual(pb.changeCount, generation)
            XCTAssertEqual(pb.string(forType: .string), "original")
            XCTAssertFalse(subject.hasPendingClipboardBorrow)
        }
    }

    func testUnsafeMultilineFallbackShowsTextWithoutTypingReturnOrChangingClipboard() {
        // Even a browser or an otherwise unknown native app can contain a terminal or submit
        // on Shift+Return. Our keystroke backend cannot promise text-only newline insertion.
        let bundles: [String?] = [nil, "org.example.UnknownApp", "com.apple.Terminal",
                                  "com.microsoft.VSCode", "com.apple.Safari", "com.apple.TextEdit"]
        for bundle in bundles {
            for failure in [PasteboardAccess.Failure.denied, .unreadable, .tooLarge] {
                let pb = board()
                write("original", to: pb)
                let generation = pb.changeCount
                let subject = inserter(pb)
                subject.frontmostBundleIDProvider = { bundle }
                subject.captureClipboardSnapshot = { _, _ in throw failure }
                subject.performUnicodeInsertion = { _ in XCTFail("Must not emit Return"); return false }
                subject.postPasteShortcut = { XCTFail("Must not borrow an unsafe clipboard") }
                var recovered: [String] = []
                subject.onRemoteInsertionFailure = { text, message in
                    recovered.append(text)
                    XCTAssertTrue(message.contains("Review the dictation below"))
                    XCTAssertFalse(message.contains("still available in speakfree"), "no saved history assumption")
                }

                subject.pasteViaClipboard("first line\nsecond line")

                XCTAssertEqual(recovered, ["first line\nsecond line"])
                XCTAssertEqual(pb.changeCount, generation)
                XCTAssertEqual(pb.string(forType: .string), "original")
                XCTAssertFalse(subject.hasPendingClipboardBorrow)
            }
        }
    }

    func testRemoteSnapshotFailureShowsSingleLineWithoutUnicodeOrAppleScript() {
        let pb = board()
        write("original", to: pb)
        let generation = pb.changeCount
        let subject = inserter(pb)
        subject.frontmostBundleIDProvider = { "com.splashtop.stp.macosx" }
        subject.captureClipboardSnapshot = { _, _ in throw PasteboardAccess.Failure.tooLarge }
        var recovered: [String] = []
        subject.onRemoteInsertionFailure = { text, _ in recovered.append(text) }

        subject.pasteViaClipboard("single line")

        XCTAssertEqual(recovered, ["single line"])
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testFailedSingleLineTypingShowsRecoveryWithoutReplacingClipboard() {
        let pb = board()
        write("original", to: pb)
        let generation = pb.changeCount
        let subject = inserter(pb)
        subject.captureClipboardSnapshot = { _, _ in throw PasteboardAccess.Failure.unreadable }
        var attempts = 0
        subject.performUnicodeInsertion = { _ in attempts += 1; return false }
        subject.postPasteShortcut = { XCTFail("Typing failure cannot justify a destructive paste") }
        var recovered: [String] = []
        subject.onRemoteInsertionFailure = { text, _ in recovered.append(text) }

        subject.pasteViaClipboard("single line")

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(recovered, ["single line"])
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testCanaryDoesNotOverwriteCopyArrivingAfterSnapshot() {
        let pb = board()
        write("old original", to: pb)
        let store = ClipboardTrustStore(fileURL: nil)
        var env = ClipboardCanary.Environment(pasteboard: pb, store: store)
        env.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        env.uptime = { 1000 }
        env.secondsSinceUserInput = { 1000 }
        env.isBusy = { false }
        env.isScreenLocked = { true }
        env.quietClipboardInterval = 0
        env.writeGate = { $0() }
        env.pasteGate = nil
        env.runningBundleIDs = {
            pb.clearContents()
            pb.setString("fresh user copy", forType: .string)
            return []
        }
        let canary = ClipboardCanary(environment: env)

        XCTAssertEqual(canary.startIfDue(mode: .lock), .skipped("changed-during-copy"))
        XCTAssertEqual(pb.string(forType: .string), "fresh user copy")
        XCTAssertFalse(canary.isRunning)
        XCTAssertNil(store.state.lastAttemptAt, "no canary was actually written")
    }

    func testAXSameVisibleWordsWithoutExactGrowthCannotProveConsumption() {
        let before = PasteFieldSnapshot(elementID: 7, characterCount: 9,
                                        selectionLocation: 9, selectionLength: 0, textBeforeCaret: nil)
        let unchanged = PasteFieldSnapshot(elementID: 7, characterCount: 9,
                                           selectionLocation: 9, selectionLength: 0, textBeforeCaret: "yes")
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: unchanged, text: "yes"), .notYet)
        let differentField = PasteFieldSnapshot(elementID: 8, characterCount: 12,
                                                selectionLocation: 12, selectionLength: 0, textBeforeCaret: "yes")
        XCTAssertEqual(PasteOutcome.verdict(before: before, after: differentField, text: "yes"), .unreadable)
    }

    func testDelayedAXBeforeSnapshotFailsSafeWhenPasteAlreadyLanded() {
        final class AlreadyPasted: PasteFieldReading {
            func read(pid: pid_t, precedingLength: Int) -> PasteFieldSnapshot? {
                .init(elementID: 7, characterCount: 12, selectionLocation: 12,
                      selectionLength: 0, textBeforeCaret: precedingLength == 0 ? nil : "yes")
            }
        }
        let queue = DispatchQueue(label: "speakfree.test.citizenship.delayed-ax")
        queue.suspend()
        let check = PasteOutcomeCheck(text: "yes", pid: 999_991, reader: AlreadyPasted(), queue: queue)
        let report = expectation(description: "uncertain outcome reported")
        check.captureBefore()
        check.start(delays: [0]) { verdict in
            XCTAssertEqual(verdict, .notYet, "a queued before read that misses insertion cannot confirm it")
            report.fulfill()
        }
        queue.resume()
        wait(for: [report], timeout: 10)
        check.cancel()
    }
}
