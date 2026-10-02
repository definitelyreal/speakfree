// ai-suggestion:unverified · session:unknown/agent:alpha-product-fixes · 2026-10-01
import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

@MainActor
final class NonactivatingPanelInsertionTests: XCTestCase {
    private let owner: pid_t = 999_991
    private let foreground: pid_t = 999_992
    private var scratch: URL!
    private var previousDevMode: String?

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        previousDevMode = ProcessInfo.processInfo.environment["SPEAKFREE_DEV_MODE"]
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
    }

    override func tearDown() async throws {
        if let previousDevMode { setenv("SPEAKFREE_DEV_MODE", previousDevMode, 1) }
        else { unsetenv("SPEAKFREE_DEV_MODE") }
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func subject() -> (TextInserter, AXUIElement) {
        let field = AXUIElementCreateApplication(owner)
        let board = NSPasteboard(name: .init("speakfree.test.nonactivating.\(UUID().uuidString)"))
        board.clearContents()
        XCTAssertTrue(board.setString("Original clipboard", forType: .string))
        addTeardownBlock { board.releaseGlobally() }
        let s = TextInserter()
        s.pasteboard = board
        s.userPasteGate = UserPasteRestoreGate()
        s.frontmostBundleIDProvider = { "com.anthropic.claudefordesktop" }
        s.frontmostBundleURLProvider = { nil }
        s.frontmostPIDProvider = { 999_991 }
        s.elementPIDProvider = { _ in 999_991 }
        s.focusedElementProvider = { field }
        s.isSecureInputActive = { false }
        s.refocusElement = { _ in XCTFail("Already-focused panel must not be refocused"); return false }
        s.directAXInsert = { _, _ in XCTFail("Paste route must not use AX writes"); return false }
        s.layoutVKeyCodeProvider = { 9 }
        s.pasteFieldReader = nil
        s.clipboardTrustReason = { nil }
        s.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        s.performUnicodeInsertion = { _ in XCTFail("No real keyboard input"); return false }
        s.executeAppleScript = { _ in XCTFail("No AppleScript"); return nil }
        s.onRemoteInsertionFailure = { _, _ in }
        return (s, field)
    }

    private func assertPublication(_ mutate: ((TextInserter) -> Void)? = nil,
                                   startForeground: pid_t = 999_991, expected: InsertionOutcome) {
        let (s, field) = subject()
        s.frontmostPIDProvider = { startForeground }
        var shortcuts = 0
        s.postPasteShortcut = { shortcuts += 1 }
        if let mutate {
            s.pasteboardWriter.write = { [weak s] board, items in
                let published = board.writeObjects(items)
                if let s { mutate(s) }
                return published
            }
        }
        let done = expectation(description: "Final insertion outcome")
        let submitted = s.insert(text: "Synthetic panel text", refocusing: field, completion: {
            XCTAssertEqual($0, expected)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(submitted, expected == .pasted)
        XCTAssertEqual(shortcuts, expected == .pasted ? 1 : 0)
        if expected != .pasted {
            XCTAssertEqual(s.pasteboard.string(forType: .string), "Original clipboard")
            XCTAssertFalse(s.hasPendingClipboardBorrow)
        }
    }

    func testUnprovenCrossProcessPanelRetainsInsteadOfPasting() {
        assertPublication(startForeground: foreground, expected: .deliveryFailed)
    }

    func testNativeAXCannotWriteAReacquiredFieldEvenAfterInitialDestinationPassed() {
        let (s, original) = subject()
        let other = AXUIElementCreateApplication(999_993)
        s.frontmostPIDProvider = { 999_991 }
        s.setSelectedText = { _, _ in XCTFail("Must not reach AX write"); return .success }
        var attempted = false
        s.performLocalInsertion = { text in
            attempted = true
            s.focusedElementProvider = { other }
            XCTAssertNil(s.writeSelectedText(text, to: other))
        }
        _ = s.insert(text: "Synthetic native text", refocusing: original)
        XCTAssertTrue(attempted)
    }

    func testNativeAXFinalGateChecksSecureInputAndWritesOnlyTheCapturedField() {
        let (s, original) = subject()
        s.frontmostPIDProvider = { 999_991 }
        var writes = 0
        s.setSelectedText = { field, _ in XCTAssertTrue(CFEqual(field, original)); writes += 1; return .success }
        s.performLocalInsertion = { text in
            s.isSecureInputActive = { true }
            XCTAssertNil(s.writeSelectedText(text, to: original))
            s.isSecureInputActive = { false }
            XCTAssertEqual(s.writeSelectedText(text, to: original), .success)
        }
        _ = s.insert(text: "Synthetic native text", refocusing: original)
        XCTAssertEqual(writes, 1)
    }

    func testRecordedPIDPreventsNilAXCaptureFromAdoptingAnotherApp() {
        let (s, _) = subject()
        s.focusedElementProvider = { nil }
        s.frontmostPIDProvider = { 999_992 }
        s.postPasteShortcut = { XCTFail("Recording-start app changed") }
        let done = expectation(description: "Retained missing AX target")
        XCTAssertFalse(s.insert(text: "Synthetic text", handlesRecovery: true,
            destination: .recorded(999_991), completion: {
                XCTAssertEqual($0, .deliveryFailed); done.fulfill()
            }))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(s.pasteboard.string(forType: .string), "Original clipboard")
    }

    func testUnknownRecordedPIDDoesNotBecomeInsertionTimePermission() {
        let (s, _) = subject()
        s.focusedElementProvider = { nil }
        let done = expectation(description: "Unknown target retained")
        XCTAssertFalse(s.insert(text: "Synthetic text", handlesRecovery: true,
            destination: .recorded(nil), completion: {
                XCTAssertEqual($0, .deliveryFailed); done.fulfill()
            }))
        wait(for: [done], timeout: 2)
    }

    func testRemoteTypingCannotBypassOriginalOwnerMismatch() {
        let (s, field) = subject()
        s.frontmostPIDProvider = { 999_992 }
        s.frontmostBundleIDProvider = { "com.apple.ScreenSharing" }
        let done = expectation(description: "Remote mismatch retained")
        XCTAssertFalse(s.insert(text: "Synthetic remote text", refocusing: field,
            handlesRecovery: true, completion: {
                XCTAssertEqual($0, .deliveryFailed); done.fulfill()
            }))
        wait(for: [done], timeout: 2)
    }

    func testManualRecoveryPublicationFailureNeverQueuesNestedRecovery() {
        let (s, _) = subject()
        s.pasteboardWriter.clear = { board, _ in board.changeCount }
        s.onRemoteInsertionFailure = { _, _ in XCTFail("Existing dialog owns failure") }
        XCTAssertFalse(s.copyForManualRecovery("Synthetic recovery"))
        XCTAssertEqual(s.pasteboard.string(forType: .string), "Original clipboard")
    }

    func testStaleAXAfterAnAppSwitchBeforeInsertionCannotAuthorizeTheNewForeground() {
        // Recording began in the field owner's app. Before finalization the user switched
        // apps, but AX still reports that old field. These observations also describe a
        // non-activating panel; without a record-start pair they must fail safely.
        assertPublication(startForeground: foreground, expected: .deliveryFailed)
    }

    func testForegroundSwitchDuringPublicationCannotReuseStaleFieldIdentity() {
        assertPublication({ $0.frontmostPIDProvider = { 999_992 } }, expected: .deliveryFailed)
    }

    func testUnchangedOwnerForegroundAndFieldStillPaste() {
        assertPublication(expected: .pasted)
    }

    func testDifferentFocusedFieldCancelsPanelPaste() {
        let other = AXUIElementCreateApplication(999_993)
        assertPublication({ $0.focusedElementProvider = { other } }, expected: .deliveryFailed)
    }

    func testUnknownFocusedFieldCancelsPanelPaste() {
        assertPublication({ $0.focusedElementProvider = { nil } }, expected: .deliveryFailed)
    }

    func testChangedOwnerCannotReuseTheSameFieldIdentity() {
        assertPublication({ $0.elementPIDProvider = { _ in 999_994 } }, expected: .deliveryFailed)
    }

    func testUnknownOwnerCannotAuthorizePanelPaste() {
        assertPublication({ $0.elementPIDProvider = { _ in nil } }, expected: .deliveryFailed)
    }

    func testSecureInputStartingDuringPublicationCancelsPanelPaste() {
        assertPublication({ $0.isSecureInputActive = { true } }, expected: .deliveryFailed)
    }

    func testRefocusDoesNotCreateANewExceptionForAnInitiallyUnfocusedPanel() {
        checkRefocus(activateOwner: false, expected: .copiedFocusLost)
    }

    func testOrdinaryRefocusStillAcceptsTheRestoredOwnerAndField() {
        checkRefocus(activateOwner: true, expected: .pasted)
    }

    func testTypeRouteCannotBypassUnprovenCrossProcessDestination() {
        let (s, field) = subject()
        s.frontmostPIDProvider = { 999_992 }
        s.insertionOverrides = ["com.anthropic.claudefordesktop": .type]
        s.postPasteShortcut = { XCTFail("No paste into an unconfirmed app") }
        var recovered: [String] = []
        s.onRemoteInsertionFailure = { text, _ in recovered.append(text) }
        let done = expectation(description: "Typing mismatch retains")
        XCTAssertFalse(s.insert(text: "Synthetic retained text", refocusing: field, completion: {
            XCTAssertEqual($0, .deliveryFailed)
            done.fulfill()
        }))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(recovered, ["Synthetic retained text"])
        XCTAssertEqual(s.pasteboard.string(forType: .string), "Original clipboard")
    }

    func testSnapshotFailureAfterFocusMovesRetainsTextWithoutTyping() {
        let other = AXUIElementCreateApplication(999_993)
        assertSnapshotFallback({ $0.focusedElementProvider = { other } }, expected: .deliveryFailed)
    }

    func testSnapshotFailureAfterForegroundMovesRetainsTextWithoutTyping() {
        assertSnapshotFallback({ $0.frontmostPIDProvider = { 999_992 } }, expected: .deliveryFailed)
    }

    func testSnapshotFailureAfterSecureInputStartsRetainsTextWithoutTyping() {
        assertSnapshotFallback({ $0.isSecureInputActive = { true } }, expected: .deliveryFailed)
    }

    func testSnapshotFailureAfterFocusBecomesUnknownRetainsTextWithoutTyping() {
        assertSnapshotFallback({ $0.focusedElementProvider = { nil } }, expected: .deliveryFailed)
    }

    func testSnapshotFailureWithStableDestinationStillTypesSingleLine() {
        assertSnapshotFallback({ _ in }, expected: .typed)
    }

    private func assertSnapshotFallback(_ mutate: @escaping (TextInserter) -> Void,
                                        expected: InsertionOutcome) {
        let (s, field) = subject()
        let generation = s.pasteboard.changeCount
        var typed: [String] = []
        var recovered: [String] = []
        s.postPasteShortcut = { XCTFail("Snapshot failure must never paste") }
        s.performUnicodeInsertion = { typed.append($0); return true }
        s.onRemoteInsertionFailure = { text, _ in recovered.append(text) }
        s.captureClipboardSnapshot = { [weak s] _, _ in
            if let s { mutate(s) }
            throw PasteboardAccess.Failure.tooLarge
        }
        let done = expectation(description: "Snapshot fallback outcome")
        XCTAssertEqual(s.insert(text: "Synthetic retained text", refocusing: field, completion: {
            XCTAssertEqual($0, expected)
            done.fulfill()
        }), expected == .typed)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(typed, expected == .typed ? ["Synthetic retained text"] : [])
        XCTAssertEqual(recovered, expected == .typed ? [] : ["Synthetic retained text"])
        XCTAssertEqual(s.pasteboard.string(forType: .string), "Original clipboard")
        XCTAssertEqual(s.pasteboard.changeCount, generation)
        XCTAssertFalse(s.hasPendingClipboardBorrow)
    }

    private func checkRefocus(activateOwner: Bool, expected: InsertionOutcome) {
        let (s, field) = subject()
        s.focusedElementProvider = { nil }
        s.frontmostPIDProvider = { 999_992 }
        s.refocusElement = { _ in true }
        var shortcuts = 0
        s.postPasteShortcut = { shortcuts += 1 }
        let done = expectation(description: "Refocus settles")
        XCTAssertTrue(s.insert(text: "Synthetic panel text", refocusing: field, completion: {
            XCTAssertEqual($0, expected)
            done.fulfill()
        }))
        s.focusedElementProvider = { field }
        if activateOwner { s.frontmostPIDProvider = { 999_991 } }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(shortcuts, expected == .pasted ? 1 : 0)
    }
}
