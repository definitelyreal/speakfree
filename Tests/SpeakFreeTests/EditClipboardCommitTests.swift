// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_elegance_audit · 2026-10-01
// Synthetic drafts and named pasteboards only: no general clipboard, UI, AX, CLI, or microphone.
import AppKit
import XCTest
@testable import SpeakFreeLib

@MainActor
final class EditClipboardCommitTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-copy-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
    }

    override func tearDown() async throws {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("speakfree.test.edit-copy.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func inserter(_ pb: NSPasteboard) -> TextInserter {
        let subject = TextInserter()
        subject.pasteboard = pb
        subject.userPasteGate = UserPasteRestoreGate()
        subject.frontmostBundleIDProvider = { "com.microsoft.VSCode" }
        subject.frontmostBundleURLProvider = { nil }
        subject.frontmostPIDProvider = { 999_991 }
        subject.focusedElementProvider = { nil }
        subject.isSecureInputActive = { false }
        subject.layoutVKeyCodeProvider = { 9 }
        subject.pasteFieldReader = nil
        subject.clipboardTrustReason = { nil }
        subject.restoreTiming = { _ in .init(backstop: 120, afterRead: 60) }
        subject.postPasteShortcut = {}
        subject.performUnicodeInsertion = { _ in XCTFail("Unexpected typing"); return false }
        subject.executeAppleScript = { _ in
            XCTFail("Unexpected AppleScript")
            return ["NSAppleScriptErrorNumber": -1]
        }
        return subject
    }

    @discardableResult
    private func dictate(_ text: String, to core: EditSessionCore) -> UUID {
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: text, pipelineText: text)
        return id
    }

    func testRetainedDraftDoesNotClaimCopyWithoutAClipboard() {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff,
                                   cleaner: ScriptedCleaner())
        dictate("Keep this draft.", to: core)

        core.commitRetained(.differentWindow)

        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(core.commitText, "Keep this draft.")
        XCTAssertTrue(core.notice?.contains("could not be copied") == true)
        XCTAssertFalse(core.notice?.contains("Press ⌘V") == true)
    }

    func testFailedCopyAfterUncertainInsertionKeepsDraftWithoutInvitingDuplicate() {
        let clipboard = FakeClipboard()
        clipboard.copySucceeds = false
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff,
                                   cleaner: ScriptedCleaner(), clipboard: clipboard)
        dictate("Might already be in the app.", to: core)

        core.commitRetained(.insertionUncertain)

        XCTAssertTrue(core.isOpen)
        XCTAssertTrue(clipboard.copies.isEmpty)
        XCTAssertTrue(core.notice?.contains("could not be copied") == true)
        XCTAssertTrue(core.notice?.contains("Check the app") == true)
        XCTAssertFalse(core.notice?.contains("Return") == true)
    }

    func testFailedVersionCopyReturnsFailureAndKeepsText() {
        let clipboard = FakeClipboard()
        clipboard.copySucceeds = false
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff,
                                   cleaner: ScriptedCleaner(), clipboard: clipboard)
        let id = dictate("Still here.", to: core)

        XCTAssertFalse(core.copyVersion(.current, segmentID: id))

        XCTAssertEqual(core.commitText, "Still here.")
        XCTAssertTrue(clipboard.copies.isEmpty)
        XCTAssertTrue(core.notice?.contains("Could not copy") == true)
    }

    func testRuntimeCopyFailsWhenInserterIsUnavailable() {
        XCTAssertFalse(PasteboardClipboard(inserter: { nil }).copy("Draft."))
    }

    func testRuntimeCopyPublishesTheSharedWriteReceipt() {
        let pb = board()
        let subject = inserter(pb)
        let boardName = pb.name.rawValue
        var receipt: Int?
        let observer = NotificationCenter.default.addObserver(
            forName: PasteboardWriteReceipt.notification, object: nil, queue: .main
        ) { note in
            if note.userInfo?["name"] as? String == boardName {
                receipt = note.userInfo?["changeCount"] as? Int
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(PasteboardClipboard(inserter: { subject }).copy("Chosen version."))

        XCTAssertEqual(pb.string(forType: .string), "Chosen version.")
        XCTAssertEqual(receipt, pb.changeCount)
    }

    func testRuntimeCopyFailureReturnsFalseAndRestoresPreviousRichClipboard() {
        let pb = board()
        let original = NSPasteboardItem()
        let rich = Data("{\\rtf1 original}".utf8)
        original.setString("original", forType: .string)
        original.setData(rich, forType: .rtf)
        XCTAssertTrue(pb.writeObjects([original]))
        let subject = inserter(pb)
        var writes = 0
        subject.pasteboardWriter.write = { board, items in
            writes += 1
            return writes == 1 ? false : board.writeObjects(items)
        }

        XCTAssertFalse(PasteboardClipboard(inserter: { subject }).copy("Not published."))

        XCTAssertEqual(writes, 2, "the shared writer attempts recovery after publication fails")
        XCTAssertEqual(pb.string(forType: .string), "original")
        XCTAssertEqual(pb.data(forType: .rtf), rich)
    }

    func testRuntimeCopyCannotReplaceAnUnreadDictationPromise() {
        let pb = board()
        XCTAssertTrue(pb.setString("original", forType: .string))
        let subject = inserter(pb)
        subject.pasteViaClipboard("pending dictation")
        let generation = pb.changeCount

        XCTAssertFalse(PasteboardClipboard(inserter: { subject }).copy("Another version."))

        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertTrue(subject.isWaitingForClipboardConsumption)
        XCTAssertEqual(TextInserter.withOwnPasteboardRead { pb.string(forType: .string) }, "pending dictation")
    }

    func testReturnCancelsCleanupBeforeInsertionAndKeepsThatSnapshot() async throws {
        let cleaner = ScriptedCleaner()
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOn, cleaner: cleaner)
        let id = dictate("Send teh draft.", to: core)
        await drainMainActor()
        let call = try XCTUnwrap(cleaner.calls.first)
        let revisions = try XCTUnwrap(core.segment(id)).revisions

        XCTAssertEqual(core.returnPressed(), .commit("Send teh draft."))
        XCTAssertTrue(call.cancellation.isCancelled, "Return freezes the text before target activation")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor() // the controller has not reported insertion success yet
        let artifact = core.commitSucceeded(targetApp: "com.example.editor")

        XCTAssertEqual(artifact.text, "Send teh draft.")
        XCTAssertEqual(artifact.paragraphs.map(\.text), ["Send teh draft."])
        XCTAssertEqual(artifact.paragraphs.first?.revisions, revisions)
    }

    func testArtifactUsesTheInsertedSnapshotInsteadOfRereadingTheModel() {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff,
                                   cleaner: ScriptedCleaner())
        let id = dictate("Inserted version.", to: core)
        XCTAssertEqual(core.returnPressed(), .commit("Inserted version."))
        // A direct model mutation proves the artifact does not depend on later live state.
        core.applyUserEdits([.edit(id, "Later model state.")])

        let artifact = core.commitSucceeded(targetApp: "com.example.editor")

        XCTAssertEqual(artifact.text, "Inserted version.")
        XCTAssertEqual(artifact.paragraphs.map(\.text), ["Inserted version."])
    }

    func testRetainedCommitCanBeEditedAndRetriedWithANewSnapshot() {
        let clipboard = FakeClipboard()
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff,
                                   cleaner: ScriptedCleaner(), clipboard: clipboard)
        let id = dictate("First version.", to: core)
        XCTAssertEqual(core.returnPressed(), .commit("First version."))
        core.commitRetained(.differentWindow)
        core.applyUserEdits([.edit(id, "Revised version.")])
        XCTAssertEqual(core.returnPressed(), .commit("Revised version."))

        let artifact = core.commitSucceeded(targetApp: "com.example.editor")

        XCTAssertEqual(clipboard.copies, ["First version."])
        XCTAssertEqual(artifact.text, "Revised version.")
        XCTAssertEqual(artifact.paragraphs.map(\.text), ["Revised version."])
    }
}
