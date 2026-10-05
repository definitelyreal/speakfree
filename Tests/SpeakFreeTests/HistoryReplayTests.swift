// ai-suggestion:unverified · session:unknown/agent:code_audio_bluetooth · 2026-10-03
// The real coordinator uses a named pasteboard, inert AX identities, and injected I/O.
// No native panel, Accessibility read, global event monitor, or system input is invoked.
import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

@MainActor
final class HistoryReplayTests: XCTestCase {
    private var scratch: URL!
    private var previousDevMode: String?

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("history-replay-\(UUID().uuidString)")
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
    private final class Harness {
        let board = NSPasteboard(name: .init("speakfree.test.history-replay.\(UUID().uuidString)"))
        let inserter = TextInserter()
        let store = HistoryStore()
        var subject: HistoryCoordinator!
        var frontmost: HistoryCoordinator.Application? = .init(pid: 999_991, bundleID: "com.anthropic.claudefordesktop")
        var busy = false
        var secure = false
        var running = true
        var now: TimeInterval = 100
        var presented = 0
        var hidden = 0
        var activations = 0
        var pastes = 0
        var trace: [String] = []
        var diagnoses: [String] = []
        var feedback: [String] = []
        var captures: [(HistoryCoordinator.Destination) -> Void] = []
        var validations: [(HistoryPastePolicy.Observation) -> Void] = []
        var scheduled: [() -> Void] = []
        let window = AXUIElementCreateApplication(999_992)
        let field = AXUIElementCreateApplication(999_993)

        init() {
            board.clearContents()
            board.setString("Original synthetic clipboard", forType: .string)
            store.addDictation("Synthetic history item", sourceAppBundleID: nil, linkedArchiveID: nil)
            inserter.pasteboard = board
            inserter.clipboardPreparation = PasteboardPreparation(executeRead: { $0() })
            inserter.frontmostBundleIDProvider = { [weak self] in self?.frontmost?.bundleID }
            inserter.frontmostPIDProvider = { [weak self] in self?.frontmost?.pid }
            inserter.focusedElementProvider = { nil }
            inserter.isSecureInputActive = { [weak self] in self?.secure ?? true }
            inserter.layoutVKeyCodeProvider = { 9 }
            inserter.postPasteShortcut = { [weak self] in self?.pastes += 1; self?.trace.append("paste") }
            inserter.performUnicodeInsertion = { _ in XCTFail("No typing expected"); return false }
            inserter.executeAppleScript = { _ in XCTFail("No AppleScript expected"); return nil }
            inserter.onRemoteInsertionFailure = { _, _ in XCTFail("No recovery UI expected") }
            var env = HistoryCoordinator.Environment()
            env.usesSystemServices = false
            env.frontmost = { [weak self] in self?.frontmost }
            env.isRunning = { [weak self] _ in self?.running ?? false }
            env.activate = { [weak self] _ in self?.activations += 1 }
            env.capture = { [weak self] _, done in self?.trace.append("capture"); self?.captures.append(done) }
            env.validate = { [weak self] _, done in self?.trace.append("validate"); self?.validations.append(done) }
            env.schedule = { [weak self] _, work in self?.scheduled.append(work) }
            env.uptime = { [weak self] in self?.now ?? 0 }
            env.present = { [weak self] in self?.presented += 1; self?.trace.append("present") }
            env.hide = { [weak self] in self?.hidden += 1 }
            env.diagnose = { [weak self] in self?.diagnoses.append($0) }
            subject = HistoryCoordinator(config: .defaultConfig, inserter: { [weak self] in self?.inserter },
                isBusy: { [weak self] in self?.busy ?? true }, environment: env, store: store, pasteboard: board)
            subject.model.pointerLocation = { .zero }
            subject.showCopyFeedback = { [weak self] in self?.feedback.append($0) }
        }

        func finishCapture(field: Bool = false, window: Bool = true, index: Int = 0) {
            captures.remove(at: index)(.init(app: .init(pid: 999_991, bundleID: frontmost?.bundleID),
                window: window ? self.window : nil, field: field ? self.field : nil, title: "Synthetic window"))
        }
        func open(field: Bool = false, window: Bool = true) {
            subject.show()
            finishCapture(field: field, window: window)
        }
        func startReplay() {
            subject.model.activate()
            XCTAssertFalse(subject.isPresented)
            XCTAssertEqual(scheduled.count, 1)
            scheduled.removeFirst()()
            XCTAssertEqual(validations.count, 1)
        }
        func finishValidation(window: Bool? = true, field: Bool? = nil, title: Bool? = true) {
            validations.removeFirst()(.init(sameWindow: window, sameField: field, sameTitle: title))
        }
        func input(_ type: NSEvent.EventType = .keyDown, timestamp: TimeInterval = 101,
                   pid: Int64? = 0, marker: Int64? = nil) {
            subject.hiddenInput(type: type, timestamp: timestamp, sourcePID: pid, userData: marker)
        }
        func dispose() {
            subject.close()
            subject = nil
            board.releaseGlobally()
        }
    }

    private func harness() -> Harness {
        let h = Harness()
        addTeardownBlock { @MainActor in h.dispose() }
        return h
    }

    func testOpaqueFieldPastesOnlyAfterCapturePresentationAndValidation() {
        let h = harness()
        h.subject.show()
        XCTAssertEqual(h.trace, ["capture"])
        XCTAssertFalse(h.subject.isPresented)
        h.finishCapture()
        XCTAssertEqual(h.trace, ["capture", "present"])
        h.startReplay()
        XCTAssertEqual(h.pastes, 0)
        h.finishValidation()
        XCTAssertEqual(h.pastes, 1)
        XCTAssertEqual(h.board.string(forType: .string), "Synthetic history item")
        XCTAssertFalse(h.subject.isPresented)
        XCTAssertEqual(h.presented, 1)
        XCTAssertEqual(h.trace, ["capture", "present", "validate", "paste"])
    }

    func testCapturedReadableFieldMustRemainTheSame() {
        for field in [true, false, nil] as [Bool?] {
            let h = harness()
            h.open(field: true)
            h.startReplay()
            h.finishValidation(field: field)
            XCTAssertEqual(h.pastes, field == true ? 1 : 0)
            if field != true {
                XCTAssertFalse(h.subject.isPresented)
                XCTAssertEqual(h.feedback.count, 1)
                XCTAssertEqual(h.presented, 1)
                XCTAssertTrue(h.diagnoses.contains("refused fieldChangedOrUnknown"))
            }
        }
    }

    func testChangedOrUnreadableWindowRefusesEvenWithOpaqueField() {
        for window in [false, nil] as [Bool?] {
            let h = harness()
            h.open(); h.startReplay(); h.finishValidation(window: window)
            XCTAssertEqual(h.pastes, 0)
            XCTAssertFalse(h.subject.isPresented)
            XCTAssertEqual(h.feedback.count, 1)
        }
    }

    func testAffirmativeTitleChangeRefusesButAbsentTitleAllowsConfirmedWindow() {
        for title in [false, nil] as [Bool?] {
            let h = harness()
            h.open(); h.startReplay(); h.finishValidation(title: title)
            XCTAssertEqual(h.pastes, title == false ? 0 : 1)
        }
    }

    func testMissingCapturedWindowIsCopyOnlyWithoutActivation() {
        let h = harness()
        h.open(window: false)
        h.subject.model.activate()
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.activations, 0)
        XCTAssertFalse(h.subject.isPresented)
        XCTAssertEqual(h.presented, 1)
        XCTAssertEqual(h.feedback.count, 1)
        XCTAssertEqual(h.board.string(forType: .string), "Synthetic history item")
    }

    func testTerminalAndRemoteAppsStillOnlyCopy() {
        for bundle in ["com.apple.Terminal", "com.splashtop.Splashtop-Streamer"] {
            let h = harness()
            h.frontmost = .init(pid: 999_991, bundleID: bundle)
            h.open()
            h.subject.model.activate()
            XCTAssertEqual(h.activations, 0, bundle)
            XCTAssertEqual(h.pastes, 0, bundle)
            XCTAssertFalse(h.subject.isPresented, bundle)
            XCTAssertEqual(h.presented, 1, bundle)
            XCTAssertEqual(h.feedback.count, 1, bundle)
        }
    }

    func testExplicitCopyDoesNotActivateOrValidate() {
        let h = harness()
        h.open(field: true)
        h.subject.model.activate(copyOnly: true)
        XCTAssertEqual(h.activations, 0)
        XCTAssertTrue(h.validations.isEmpty)
        XCTAssertEqual(h.pastes, 0)
        XCTAssertFalse(h.subject.isPresented)
    }

    func testSecondShortcutAndEscapeCancelPendingCapture() {
        for shortcut in [true, false] {
            let h = harness()
            h.subject.show()
            if shortcut { h.subject.show() } else { h.input() }
            h.finishCapture()
            XCTAssertEqual(h.presented, 0)
            XCTAssertFalse(h.subject.isPresented)
        }
    }

    func testStaleCaptureCannotPresentOverNewRequest() {
        let h = harness()
        h.subject.show(); h.subject.show(); h.subject.show()
        XCTAssertEqual(h.captures.count, 2)
        h.finishCapture()
        XCTAssertEqual(h.presented, 0)
        h.finishCapture()
        XCTAssertEqual(h.presented, 1)
    }

    func testCaptureChecksForegroundAndBusyAgainBeforePresenting() {
        for busy in [false, true] {
            let h = harness()
            h.subject.show()
            if busy { h.busy = true } else { h.frontmost = .init(pid: 999_994, bundleID: "test.other") }
            h.finishCapture()
            XCTAssertEqual(h.presented, 0)
        }
    }

    func testAppSwitchAwayAndBackCancelsCaptureAndReplay() {
        for duringCapture in [false, true] {
            let h = harness()
            if duringCapture { h.subject.show() } else { h.open(); h.startReplay() }
            h.subject.applicationDidActivate(pid: 999_994)
            h.subject.applicationDidActivate(pid: 999_991)
            if duringCapture { h.finishCapture() } else { h.finishValidation() }
            XCTAssertEqual(h.presented, duringCapture ? 0 : 1)
            XCTAssertEqual(h.pastes, 0)
            XCTAssertFalse(h.subject.isPresented)
        }
    }

    func testFinalPIDChangeWithoutNotificationCancelsInsteadOfReopening() {
        let h = harness()
        h.open(); h.startReplay()
        h.frontmost = .init(pid: 999_994, bundleID: "test.other")
        h.finishValidation(window: false)
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.presented, 1)
        XCTAssertFalse(h.subject.isPresented)
        XCTAssertTrue(h.diagnoses.contains("cancelled appChanged"))
    }

    func testPIDChangeDuringSettleDoesNotStartValidationOrReopen() {
        let h = harness()
        h.open(); h.subject.model.activate()
        h.frontmost = .init(pid: 999_994, bundleID: "test.other")
        h.scheduled.removeFirst()()
        XCTAssertTrue(h.validations.isEmpty)
        XCTAssertEqual(h.presented, 1)
        XCTAssertEqual(h.pastes, 0)
    }

    func testNewPressOrScrollCancelsHiddenReplayWithoutReopening() {
        for type in [NSEvent.EventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            let h = harness()
            h.open(); h.startReplay(); h.input(type); h.finishValidation()
            XCTAssertEqual(h.pastes, 0)
            XCTAssertEqual(h.presented, 1)
            XCTAssertFalse(h.subject.isPresented)
        }
    }

    func testUnrelatedAutomationCancelsLikePhysicalInput() {
        let h = harness()
        h.open(); h.startReplay()
        h.input(pid: 999_995)
        h.finishValidation()
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.presented, 1)
    }

    func testOpeningEventReleasesAndOurSyntheticEventsDoNotCancel() {
        let h = harness()
        h.subject.show()
        h.input(timestamp: 100)
        h.finishCapture()
        h.startReplay()
        for type in [NSEvent.EventType.keyUp, .leftMouseUp, .rightMouseUp, .flagsChanged] { h.input(type) }
        h.input(pid: Int64(getpid()))
        h.input(marker: HistoryPastePolicy.syntheticPasteMarker)
        h.finishValidation()
        XCTAssertEqual(h.pastes, 1)
    }

    func testBusyAtFinalValidationClosesWithoutReopening() {
        let h = harness()
        h.open(); h.startReplay(); h.busy = true; h.finishValidation()
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.presented, 1)
        XCTAssertFalse(h.subject.isPresented)
    }

    func testSecureInputAndNewClipboardPreventShortcut() {
        for secure in [false, true] {
            let h = harness()
            h.open(); h.startReplay()
            if secure { h.secure = true }
            else { h.board.clearContents(); h.board.setString("New synthetic copy", forType: .string) }
            h.finishValidation()
            XCTAssertEqual(h.pastes, 0)
            XCTAssertEqual(h.subject.model.pasteBehavior, .copyOnly)
            if secure {
                XCTAssertEqual(h.subject.model.status,
                    "Secure Input is on. Copy this item, then paste where you want it.")
                XCTAssertTrue(h.diagnoses.contains("refused secureInput"))
            } else {
                XCTAssertEqual(h.board.string(forType: .string), "New synthetic copy")
                XCTAssertEqual(h.subject.model.status,
                    "The clipboard or destination changed. Choose Copy, then paste where you want it.")
            }
        }
    }

    func testRepeatedActivationDuringReplayPublishesAndPastesOnce() {
        let h = harness()
        h.open(); h.startReplay()
        let generation = h.board.changeCount
        h.subject.model.activate(); h.subject.model.activate()
        XCTAssertEqual(h.board.changeCount, generation)
        XCTAssertEqual(h.activations, 1)
        h.finishValidation()
        XCTAssertEqual(h.pastes, 1)
    }

    func testRefusedReplayCopiesOnceAndLeavesDestinationAvailableForManualPaste() {
        let h = harness()
        h.open(field: true); h.startReplay(); h.finishValidation(field: false)
        h.subject.model.activate()
        XCTAssertEqual(h.activations, 1)
        XCTAssertEqual(h.pastes, 0)
        XCTAssertFalse(h.subject.isPresented)
    }

    func testClosingWhileValidationPendingCannotReopenOrPaste() {
        let h = harness()
        h.open(); h.startReplay(); h.subject.model.handle(.close); h.finishValidation()
        XCTAssertEqual(h.presented, 1)
        XCTAssertEqual(h.pastes, 0)
    }

    func testClipboardPublicationFailureLeavesPickerAndOriginalClipboard() {
        let h = harness()
        h.open()
        h.inserter.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        h.startReplay()
        h.finishValidation()
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.activations, 1)
        XCTAssertTrue(h.subject.isPresented)
        XCTAssertEqual(h.board.string(forType: .string), "Original synthetic clipboard")
    }

    func testBusyBeforeOpeningOrSelectionDoesNotTouchClipboard() {
        let h = harness()
        h.busy = true; h.subject.show()
        XCTAssertTrue(h.captures.isEmpty)
        h.busy = false; h.open(); h.busy = true; h.subject.model.activate()
        XCTAssertEqual(h.board.string(forType: .string), "Original synthetic clipboard")
        XCTAssertEqual(h.activations, 0)
    }
    func testEachShortcutOpensItsExplicitFilterAndNilRemembersSelection() {
        for (action, filter) in [(HistorySettings.Action.dictation, HistoryPickerModel.Filter.dictation),
                                 (.clipboard, .clipboard), (.all, .all)] {
            let h = harness()
            h.subject.model.filter = .all
            h.subject.show(action: action)
            h.finishCapture()
            XCTAssertEqual(h.subject.model.filter, filter)
            h.subject.close()
            h.subject.show()
            h.finishCapture()
            XCTAssertEqual(h.subject.model.filter, filter)
        }
    }

    func testClosingPickerCancelsBulkDeleteConfirmation() {
        let h = Harness()
        h.open()
        h.subject.model.clickBulkDelete()
        XCTAssertNotNil(h.subject.model.armedDeletion)
        h.subject.close()
        XCTAssertNil(h.subject.model.armedDeletion)
        XCTAssertEqual(h.store.entries.count, 1)
        h.open()
        h.subject.model.clickBulkDelete()
        XCTAssertNotNil(h.subject.model.armedDeletion)
        XCTAssertEqual(h.store.entries.count, 1)
    }

    func testDifferentShortcutSwitchesVisiblePickerSameShortcutCloses() {
        let h = harness()
        h.subject.show(filter: .dictation); h.finishCapture()
        h.subject.model.query = "synthetic"
        h.subject.show(filter: .clipboard)
        XCTAssertTrue(h.subject.isPresented)
        XCTAssertEqual(h.subject.model.filter, .clipboard)
        XCTAssertEqual(h.subject.model.query, "")
        XCTAssertEqual(h.presented, 1)
        XCTAssertTrue(h.captures.isEmpty, "Switching a shown picker must preserve its original destination")
        h.subject.show(filter: .clipboard)
        XCTAssertFalse(h.subject.isPresented)
    }

    func testDifferentShortcutRestartsCaptureAndDiscardsOlderReply() {
        let h = harness()
        h.subject.show(filter: .dictation)
        h.subject.show(filter: .clipboard)
        XCTAssertEqual(h.captures.count, 2)
        h.finishCapture()
        XCTAssertFalse(h.subject.isPresented)
        h.finishCapture()
        XCTAssertTrue(h.subject.isPresented)
        XCTAssertEqual(h.subject.model.filter, .clipboard)
        XCTAssertEqual(h.presented, 1)
    }

    func testExplicitShortcutDuringHiddenReplayOnlyCancels() {
        let h = harness()
        h.open(); h.startReplay()
        h.subject.show(filter: .clipboard)
        h.finishValidation()
        XCTAssertTrue(h.captures.isEmpty)
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.presented, 1)
        XCTAssertFalse(h.subject.isPresented)
    }

    func testDeferredDictationBlocksFinalReplayWithoutReopening() {
        let h = harness()
        h.open(); h.startReplay()
        let target = AXUIElementCreateApplication(999_991)
        h.inserter.refocusElement = { _ in true }
        let complete = expectation(description: "injected deferred dictation")
        h.inserter.directAXInsert = { _, _ in complete.fulfill(); return true }
        XCTAssertTrue(h.inserter.insert(text: "Synthetic pending dictation", refocusing: target))
        h.inserter.focusedElementProvider = { target }
        XCTAssertTrue(h.inserter.hasDeferredInsertion)
        h.finishValidation()
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.presented, 1)
        XCTAssertFalse(h.subject.isPresented)
        wait(for: [complete], timeout: 2)
    }

    func testSecureInputIsRecheckedAtShortcutSubmission() {
        let h = harness()
        h.open(); h.startReplay()
        var reads = 0
        h.inserter.isSecureInputActive = { reads += 1; return reads > 2 }
        h.finishValidation()
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(h.pastes, 0)
        XCTAssertTrue(h.diagnoses.contains("refused shortcut_not_submitted"))
    }

    func testSecondExplicitSameFilterShortcutCancelsPendingCapture() {
        let h = harness()
        h.subject.show(filter: .dictation)
        h.subject.show(filter: .dictation)
        h.finishCapture()
        XCTAssertEqual(h.presented, 0)
    }

    func testDifferentFilterDoesNotRefocusPickerOverNewDictation() {
        let h = harness()
        h.subject.show(filter: .dictation); h.finishCapture()
        h.busy = true
        h.subject.show(filter: .clipboard)
        XCTAssertFalse(h.subject.isPresented)
        XCTAssertEqual(h.subject.model.filter, .dictation)
        XCTAssertEqual(h.presented, 1)
        XCTAssertTrue(h.captures.isEmpty)
    }

    func testPreparationLateReplyCannotPublishAfterCancelInputAppChangeBusyOrNewCopy() {
        for boundary in ["close", "input", "app", "busy", "clipboard"] {
            let h = harness()
            let worker = DispatchQueue(label: "test.history.preparation.\(boundary)")
            let release = DispatchSemaphore(value: 0)
            let entered = expectation(description: "snapshot reader entered")
            h.inserter.clipboardPreparation = PasteboardPreparation(executeRead: { worker.async(execute: $0) },
                scheduleTimeout: { _ in }, read: { board, limit, cancelled in
                    XCTAssertFalse(Thread.isMainThread)
                    entered.fulfill()
                    release.wait()
                    return try PasteboardAccess.snapshot(board, maximumBytes: limit, cancelled: cancelled)
                })
            h.open()
            let originalGeneration = h.board.changeCount
            h.subject.model.activate()
            wait(for: [entered], timeout: 2)
            XCTAssertFalse(h.subject.isPresented)
            XCTAssertEqual(h.board.changeCount, originalGeneration, "Preparation never clears the board")
            switch boundary {
            case "close": h.subject.close()
            case "input": h.input()
            case "app": h.frontmost = .init(pid: 999_994, bundleID: "example.other")
            case "busy": h.busy = true
            default:
                h.board.clearContents()
                h.board.setString("new external copy", forType: .string)
            }
            let protectedGeneration = h.board.changeCount
            release.signal()
            let drained = expectation(description: "late response delivered")
            worker.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 2)
            XCTAssertEqual(h.board.changeCount, protectedGeneration, boundary)
            XCTAssertEqual(h.board.string(forType: .string),
                boundary == "clipboard" ? "new external copy" : "Original synthetic clipboard", boundary)
            XCTAssertEqual(h.pastes, 0)
            XCTAssertTrue(h.validations.isEmpty)
            XCTAssertTrue(h.scheduled.isEmpty)
        }
    }

    func testPreparationTimeoutStillValidatesDestinationAndLateReadCannotPasteTwice() throws {
        let h = harness()
        var readWork: (() -> Void)?
        var timeout: DispatchWorkItem?
        h.inserter.clipboardPreparation = PasteboardPreparation(executeRead: { readWork = $0 },
                                                               scheduleTimeout: { timeout = $0 })
        h.open()
        let generation = h.board.changeCount
        h.subject.model.activate()
        try XCTUnwrap(timeout).perform()
        XCTAssertFalse(h.subject.isPresented)
        XCTAssertEqual(h.scheduled.count, 1)
        XCTAssertEqual(h.board.changeCount, generation, "A timeout alone never publishes before destination validation")
        readWork?()
        XCTAssertEqual(h.board.changeCount, generation)
        XCTAssertEqual(h.pastes, 0)
        XCTAssertEqual(h.scheduled.count, 1, "The late read must not schedule a second replay")
        h.scheduled.removeFirst()()
        h.finishValidation()
        XCTAssertEqual(h.pastes, 1)
        XCTAssertEqual(h.board.string(forType: .string), "Synthetic history item")
        XCTAssertTrue(h.scheduled.isEmpty)
    }

}
