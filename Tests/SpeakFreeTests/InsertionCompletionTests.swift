// Trace output experiment: ai-suggestion:unverified · session:unknown · 2026-10-04
// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_elegance_audit · 2026-10-01
// Named pasteboards, synthetic AX identities, and injected delivery only. No live windows or input.
import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

@MainActor
final class InsertionCompletionTests: XCTestCase {
    private var scratch: URL!
    private var previousDevMode: String?

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("insertion-completion-\(UUID().uuidString)")
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

    private func subject() -> TextInserter {
        let pb = NSPasteboard(name: .init("speakfree.test.completion.\(UUID().uuidString)"))
        pb.clearContents()
        XCTAssertTrue(pb.setString("original", forType: .string))
        addTeardownBlock { pb.releaseGlobally() }
        let s = TextInserter()
        s.pasteboard = pb
        s.userPasteGate = UserPasteRestoreGate()
        s.frontmostBundleIDProvider = { "com.anthropic.claudefordesktop" }
        s.frontmostBundleURLProvider = { nil }
        s.frontmostPIDProvider = { 999_991 }
        s.focusedElementProvider = { nil }
        s.isSecureInputActive = { false }
        s.layoutVKeyCodeProvider = { 9 }
        s.pasteFieldReader = nil
        s.clipboardTrustReason = { nil }
        s.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        s.postPasteShortcut = { XCTFail("Unexpected paste") }
        s.performUnicodeInsertion = { _ in XCTFail("Unexpected typing"); return false }
        s.executeAppleScript = { _ in XCTFail("Unexpected AppleScript"); return nil }
        s.onRemoteInsertionFailure = { _, _ in }
        return s
    }

    func testSynchronousPublicationFailureReturnsFalseAndCompletesOnce() {
        let s = subject()
        s.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        var legacyFailures = 0
        s.onRemoteInsertionFailure = { _, _ in legacyFailures += 1 }
        var outcomes: [InsertionOutcome] = []
        let complete = expectation(description: "publication failure")

        XCTAssertFalse(s.insert(text: "Draft.", completion: {
            outcomes.append($0)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(legacyFailures, 1)
        XCTAssertEqual(outcomes, [.deliveryFailed])
        XCTAssertEqual(s.pasteboard.string(forType: .string), "original")
    }

    func testTraceOnlyAndExpandedSecureFallbackCopyFinishedText() {
        let s = subject()
        s.isSecureInputActive = { true }
        let payload = DictationTrace.Payload.make(engine: "whisper", heard: "raw kama",
                                                  unsure: [.init(word: "kama", score: 0.2)])
        for mode: DictationTrace.OutputMode in [.tagsOnly, .expanded, .tags] {
            let output = DictationTrace.output(payload, mode: mode, text: "Finished comma.")
            var notified: String?
            s.onSecureInputFallback = { text, _ in notified = text }
            XCTAssertFalse(s.insert(text: output, recoveryText: "Finished comma.", completion: nil))
            XCTAssertEqual(s.pasteboard.string(forType: .string), "Finished comma.")
            XCTAssertEqual(notified, "Finished comma.")
        }
    }

    func testDeferredTraceFallbackKeepsItsOwnFinishedTextAfterNewerInsertion() {
        let s = subject()
        let target = AXUIElementCreateApplication(999_991)
        s.refocusElement = { _ in true }
        var secure = false
        s.isSecureInputActive = { secure }
        let payload = DictationTrace.Payload.make(engine: "whisper", heard: "first raw kama", unsure: [])
        let onlyDot = DictationTrace.output(payload, mode: .tagsOnly, text: "First finished comma.")
        let complete = expectation(description: "first trace-only fallback")
        XCTAssertTrue(s.insert(text: onlyDot, refocusing: target, recoveryText: "First finished comma.", completion: {
            XCTAssertEqual($0, .secureInput)
            complete.fulfill()
        }))
        secure = true
        XCTAssertFalse(s.insert(text: "Second finished.", recoveryText: "Second finished.", completion: nil))
        XCTAssertEqual(s.pasteboard.string(forType: .string), "Second finished.")

        wait(for: [complete], timeout: 2)

        XCTAssertEqual(s.pasteboard.string(forType: .string), "First finished comma.")
    }

    func testDeferredPublicationFailureCompletesAfterRefocusOwnershipEnds() {
        let s = subject()
        let target = AXUIElementCreateApplication(999_991)
        s.refocusElement = { _ in true }
        s.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        var outcomes: [InsertionOutcome] = []
        let complete = expectation(description: "deferred publication failure")

        XCTAssertTrue(s.insert(text: "Draft.", refocusing: target, completion: {
            XCTAssertFalse(s.hasDeferredInsertion)
            outcomes.append($0)
            complete.fulfill()
        }))
        s.focusedElementProvider = { target }
        XCTAssertTrue(outcomes.isEmpty)
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(outcomes, [.deliveryFailed])
    }

    func testFailedSecureCopyReportsFailureEvenWithoutLegacyCopyCallbacks() {
        let s = subject()
        s.isSecureInputActive = { true }
        s.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        s.onSecureInputFallback = { _, _ in XCTFail("No concealed copy was published") }
        let complete = expectation(description: "secure publication failure")
        var outcomes: [InsertionOutcome] = []

        XCTAssertFalse(s.insert(text: "Draft.", onFocusLost: { XCTFail("No copy to announce") }, completion: {
            outcomes.append($0)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(outcomes, [.deliveryFailed])
    }

    func testDeferredSecureCopyFailureCompletesOnce() {
        let s = subject()
        let target = AXUIElementCreateApplication(999_991)
        s.refocusElement = { _ in true }
        var secure = false
        s.isSecureInputActive = { secure }
        s.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        let complete = expectation(description: "secure input during refocus")
        var outcomes: [InsertionOutcome] = []

        XCTAssertTrue(s.insert(text: "Draft.", refocusing: target, completion: {
            outcomes.append($0)
            complete.fulfill()
        }))
        secure = true
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(outcomes, [.deliveryFailed])
    }

    func testSuccessfulSubmissionCompletesOnceWithoutWaitingForAHeuristicTimer() {
        let s = subject()
        var pastes = 0
        s.postPasteShortcut = { pastes += 1 }
        let complete = expectation(description: "local submission")
        var outcomes: [InsertionOutcome] = []

        XCTAssertTrue(s.insert(text: "Draft.", completion: {
            outcomes.append($0)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(outcomes, [.pasted])
    }

    func testSuccessfulDeferredSubmissionCompletesOnlyAfterSending() {
        let s = subject()
        let target = AXUIElementCreateApplication(999_991)
        s.refocusElement = { _ in true }
        var sent = false
        s.postPasteShortcut = { sent = true }
        let complete = expectation(description: "submission after refocus")
        var outcomes: [InsertionOutcome] = []

        XCTAssertTrue(s.insert(text: "Draft.", refocusing: target, completion: {
            XCTAssertTrue(sent)
            XCTAssertFalse(s.hasDeferredInsertion)
            outcomes.append($0)
            complete.fulfill()
        }))
        s.focusedElementProvider = { target }
        XCTAssertFalse(sent)
        XCTAssertTrue(outcomes.isEmpty)
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(outcomes, [.pasted])
    }

    func testPerCallRecoveryDoesNotReplaceOrTriggerNormalDictationRetry() {
        let s = subject()
        s.isSecureInputActive = { true }
        var legacyCopies = 0
        s.onSecureInputFallback = { _, _ in legacyCopies += 1 }
        let complete = expectation(description: "Edit owns this fallback")

        XCTAssertFalse(s.insert(text: "Edit draft.", handlesRecovery: true, completion: {
            XCTAssertEqual($0, .secureInput)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)
        XCTAssertEqual(legacyCopies, 0)

        XCTAssertFalse(s.insert(text: "Next ordinary dictation."))
        XCTAssertEqual(legacyCopies, 1, "the existing callback remains installed for its owner")
    }

    func testFocusChangingDuringPublicationPreventsPasteAndRestoresClipboard() {
        let s = subject()
        let target = AXUIElementCreateApplication(999_991)
        let other = AXUIElementCreateApplication(999_992)
        var field = target
        s.focusedElementProvider = { field }
        s.pasteboardWriter.write = { pb, items in
            let published = pb.writeObjects(items)
            field = other
            return published
        }
        let complete = expectation(description: "final field check")

        XCTAssertFalse(s.insert(text: "Draft.", refocusing: target, completion: {
            XCTAssertEqual($0, .deliveryFailed)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(s.pasteboard.string(forType: .string), "original")
        XCTAssertFalse(s.hasPendingClipboardBorrow)
    }

    func testPIDChangingDuringPublicationCannotReuseTheSameFieldIdentity() {
        let s = subject()
        let target = AXUIElementCreateApplication(999_991)
        s.focusedElementProvider = { target }
        var pid: pid_t = 999_991
        s.frontmostPIDProvider = { pid }
        s.pasteboardWriter.write = { pb, items in
            let published = pb.writeObjects(items)
            pid = 999_992
            return published
        }
        let complete = expectation(description: "final pid check")

        XCTAssertFalse(s.insert(text: "Draft.", refocusing: target, completion: {
            XCTAssertEqual($0, .deliveryFailed)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(s.pasteboard.string(forType: .string), "original")
    }

    func testSecureInputStartingDuringPublicationPreventsPaste() {
        let s = subject()
        var secure = false
        s.isSecureInputActive = { secure }
        s.pasteboardWriter.write = { pb, items in
            let published = pb.writeObjects(items)
            secure = true
            return published
        }
        let complete = expectation(description: "final secure-input check")

        XCTAssertFalse(s.insert(text: "Draft.", completion: {
            XCTAssertEqual($0, .deliveryFailed)
            complete.fulfill()
        }))
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(s.pasteboard.string(forType: .string), "original")
    }

    func testLateRemoteFailureCompletesItsOwnAttemptAfterANewerSuccess() {
        let s = subject()
        s.frontmostBundleIDProvider = { "com.apple.ScreenSharing" }
        s.executeAppleScript = { _ in ["NSAppleScriptErrorNumber": -1743] }
        let remoteComplete = expectation(description: "remote failed later")
        let localComplete = expectation(description: "newer local submission")
        var remoteOutcomes: [InsertionOutcome] = []
        var localOutcomes: [InsertionOutcome] = []
        XCTAssertTrue(s.insert(text: "First\nremote", completion: {
            remoteOutcomes.append($0)
            remoteComplete.fulfill()
        }))
        XCTAssertTrue(remoteOutcomes.isEmpty)

        s.frontmostBundleIDProvider = { "com.anthropic.claudefordesktop" }
        s.postPasteShortcut = {}
        XCTAssertTrue(s.insert(text: "Second local", completion: {
            localOutcomes.append($0)
            localComplete.fulfill()
        }))
        wait(for: [remoteComplete, localComplete], timeout: 2)

        XCTAssertEqual(remoteOutcomes, [.deliveryFailed])
        XCTAssertEqual(localOutcomes, [.pasted])
    }

    func testRemoteSuccessCompletesOnceAfterTheDelayedShortcut() {
        let s = subject()
        s.frontmostBundleIDProvider = { "com.apple.ScreenSharing" }
        var shortcuts = 0
        s.executeAppleScript = { _ in shortcuts += 1; return nil }
        let complete = expectation(description: "delayed remote submission")
        var outcomes: [InsertionOutcome] = []

        XCTAssertTrue(s.insert(text: "Remote\ndraft", completion: {
            XCTAssertEqual(shortcuts, 1)
            outcomes.append($0)
            complete.fulfill()
        }))
        XCTAssertEqual(shortcuts, 0)
        XCTAssertTrue(outcomes.isEmpty)
        wait(for: [complete], timeout: 2)

        XCTAssertEqual(outcomes, [.remotePasted])
    }

    private func makeController(_ inserter: TextInserter, committed: @escaping (String) -> Void) -> EditSessionController {
        var config = Config.defaultConfig
        config.editModeCleanup = FlexBool(false)
        let hooks = EditSessionController.Hooks(
            setPendingTarget: { _ in }, startRecording: { false }, stopRecording: {},
            abortRecording: {}, isInPostBuffer: { false }, inserter: { inserter },
            isRemoteDesktop: { _ in false }, onSessionClosed: {}, saveConfig: { _ in },
            loadConfig: { config }, noteRecents: {},
            noteCommittedText: { text, _, _ in committed(text) },
            presentWindow: false, captureFrontmostApp: false,
            cleaner: ScriptedCleaner(), clipboard: FakeClipboard())
        let controller = EditSessionController(hooks: hooks)
        controller.openSession()
        return controller
    }

    func testEditKeepsItsDraftAfterPublicationFailure() async throws {
        let s = subject()
        s.pasteboardWriter.clear = { pb, _ in pb.changeCount }
        let controller = makeController(s) { _ in XCTFail("Failed insertion must not reach History/Recents") }
        let core = try XCTUnwrap(controller.core)
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: "Draft.", pipelineText: "Draft.")
        XCTAssertEqual(core.returnPressed(), .commit("Draft."))

        controller.submitPreparedText("Draft.", using: s, refocusing: nil)
        await drainMainActor()

        XCTAssertTrue(controller.isOpen)
        XCTAssertEqual(core.commitText, "Draft.")
        XCTAssertTrue(core.notice?.contains("Check the app") == true)
        controller.terminate()
    }

    func testEditClosesAndRecordsExactlyOnceAfterSuccessfulSubmission() async throws {
        let s = subject()
        s.postPasteShortcut = {}
        var commits: [String] = []
        let controller = makeController(s) { commits.append($0) }
        let core = try XCTUnwrap(controller.core)
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: "Draft.", pipelineText: "Draft.")
        XCTAssertEqual(core.returnPressed(), .commit("Draft."))

        controller.submitPreparedText("Draft.", using: s, refocusing: nil)
        await drainMainActor()

        XCTAssertFalse(controller.isOpen)
        XCTAssertEqual(commits, ["Draft."])
    }
}
