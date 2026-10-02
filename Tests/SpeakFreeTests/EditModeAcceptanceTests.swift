// Claude · 2026-09-24 · Edit Mode V1 acceptance tests, written from the feature requirements
// alone, without reading the implementation.
import XCTest
@testable import SpeakFreeLib

@MainActor
final class EditModeAcceptanceTests: XCTestCase {

    private var tempDir: URL!
    private var cleaner: ScriptedCleaner!
    private var clipboard: FakeClipboard!
    private var events: [EditCoreEvent] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmode-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        Config.configDirOverride = tempDir
        cleaner = ScriptedCleaner()
        clipboard = FakeClipboard()
        events = []
    }

    override func tearDown() async throws {
        // Release any cleanup call a test left open so no continuation leaks.
        if let cleaner {
            for i in 0..<cleaner.callCount { cleaner.finish(i, .failure(.cancelled)) }
        }
        await drainMainActor()
        Config.configDirOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: helpers

    private func makeCore(_ settings: EditModeSettings = .cloudOn,
                          persistence: Bool = false) -> EditSessionCore {
        let core = EditSessionCore(persistenceEnabled: persistence, settings: settings,
                                   cleaner: cleaner, clipboard: clipboard, shuffle: { $0 })
        core.onEvent = { [weak self] e in self?.events.append(e) }
        return core
    }

    @discardableResult
    private func dictate(_ core: EditSessionCore, raw: String, pipeline: String? = nil,
                         stem: String? = nil) async -> UUID {
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: raw, pipelineText: pipeline ?? raw, componentStem: stem)
        await drainMainActor()
        return id
    }

    private func commitString(_ outcome: EditReturnOutcome) -> String? {
        if case .commit(let s) = outcome { return s }
        return nil
    }

    private let paragraphSeparators = ["\n\n", "\u{2029}", "\r\n\r\n"]

    private func isParagraphJoin(_ text: String, _ a: String, _ b: String) -> Bool {
        paragraphSeparators.contains { text == a + $0 + b }
    }

    private let target = EditTargetIdentity(pid: 4242, bundleID: "com.apple.Notes", appName: "Notes",
                                            windowTitle: "Groceries", hasWindow: true, hasField: true)

    private func confirmedObservation(pid: Int32 = 4242) -> EditTargetObservation {
        EditTargetObservation(targetStillRunning: true, frontmostPID: pid, sameWindow: true,
                              sameTitle: true, sameField: true, secureInputActive: false,
                              activationTimedOut: false)
    }

    private func isRetain(_ v: EditDestinationVerdict) -> Bool {
        if case .retain = v { return true }
        return false
    }

    // MARK: paragraphs and immediacy

    // Requirement: each dictation starts as its own paragraph.
    func testEachDictationBecomesItsOwnParagraph() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "First thought.")
        await dictate(core, raw: "Second thought.")
        XCTAssertEqual(core.displayedSegments.count, 2)
        XCTAssertEqual(core.displayedSegments.map(\.currentText), ["First thought.", "Second thought."])
    }

    // Requirement: a real paragraph break, which may become two line breaks once pasted.
    func testParagraphsLeaveTheWindowSeparatedByAParagraphBreak() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "First thought.")
        await dictate(core, raw: "Second thought.")
        let text = commitString(core.returnPressed()) ?? core.commitText
        XCTAssertTrue(isParagraphJoin(text, "First thought.", "Second thought."),
                      "expected a paragraph break between dictations, got \(text.debugDescription)")
    }

    // Requirement: dictated text shows right away.
    func testTextShowsBeforeCleanupFinishes() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "hello there friend")
        XCTAssertEqual(cleaner.callCount, 1, "cleanup should be running")
        XCTAssertEqual(core.segment(id)?.currentText, "hello there friend")
        XCTAssertTrue(events.contains { if case .appended(let x) = $0 { return x == id }; return false },
                      "an appended event should fire before cleanup returns")
    }

    // MARK: cleanup

    // Requirement: the model is fed the raw transcript to clean up.
    func testCleanupIsSentTheRawText() async {
        let core = makeCore(.cloudOn)
        await dictate(core, raw: "um so i went to teh store", pipeline: "So I went to teh store.")
        XCTAssertEqual(cleaner.callCount, 1)
        XCTAssertEqual(cleaner.calls.first?.raw, "um so i went to teh store")
    }

    // Requirement: cleanup runs in the background through an LLM.
    func testCleanupFixIsAppliedInBackground() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I went to the store.")
    }

    // Requirement: an obvious self-correction may be removed.
    func testObviousSelfCorrectionCanBeRemoved() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "Meet me Tuesday, no wait, Wednesday at noon.")
        cleaner.finish(0, .success([SpanEdit(find: "Tuesday, no wait, ", replace: "", reason: "self-correction")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Meet me Wednesday at noon.")
    }

    // Reviewer 7: "do not approve" becoming "approve" must not be applied.
    func testMeaningChangingRepairRemovingNegationIsRejected() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I do not approve the budget.")
        cleaner.finish(0, .success([SpanEdit(find: "do not approve", replace: "approve", reason: "cleanup")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I do not approve the budget.")
    }

    // Reviewer 7: meaning-changing repairs must not be applied (the reverse direction).
    func testMeaningChangingRepairAddingNegationIsRejected() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I approve the budget.")
        cleaner.finish(0, .success([SpanEdit(find: "approve", replace: "don't approve", reason: "cleanup")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I approve the budget.")
    }

    // MARK: versions

    // Requirement: the original and previous versions stay visible.
    func testOriginalAndPreviousVersionsVisibleAfterCleanup() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        guard let v = core.versions(for: id) else { return XCTFail("no versions") }
        XCTAssertEqual(v.original, "I went to teh store.")
        XCTAssertEqual(v.previous, "I went to teh store.")
        XCTAssertEqual(v.current, "I went to the store.")
        XCTAssertEqual(v.changes.count, 1)
        XCTAssertEqual(core.segment(id)?.originalText, "I went to teh store.")
    }

    // Reviewer 2: expose Original, Previous, and Current (previous after a hand edit is the cleaned text).
    func testPreviousVersionAfterHandEditIsTheCleanedText() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        core.applyUserEdits([.edit(id, "I went to the big store.")])
        await drainMainActor()
        let v = core.versions(for: id)
        XCTAssertEqual(v?.original, "I went to teh store.")
        XCTAssertEqual(v?.previous, "I went to the store.")
        XCTAssertEqual(v?.current, "I went to the big store.")
    }

    // Reviewer 2: with copy actions.
    func testCopyOriginalVersionPutsItOnClipboard() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertTrue(core.copyVersion(.original, segmentID: id))
        XCTAssertEqual(clipboard.copies.last, "I went to teh store.")
        XCTAssertTrue(core.copyVersion(.previous, segmentID: id))
        XCTAssertEqual(clipboard.copies.last, "I went to teh store.")
    }

    // Reviewer 2: with restore actions.
    func testRestoreOriginalReplacesCurrentText() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertTrue(core.restore(.original, segmentID: id))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I went to teh store.")
    }

    // Reviewer 2: restore Previous after a hand edit.
    func testRestorePreviousUndoesHandEdit() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        core.applyUserEdits([.edit(id, "I went to the big store.")])
        await drainMainActor()
        XCTAssertTrue(core.restore(.previous, segmentID: id))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I went to the store.")
    }

    // Reviewer 2: individual cleanup changes reversible without discarding subsequent hand edits.
    func testRevertingOneCleanupChangeKeepsLaterHandEdit() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store. It was closed.")
        let fix = SpanEdit(find: "teh", replace: "the", reason: "typo")
        cleaner.finish(0, .success([fix]))
        await drainMainActor()
        core.applyUserEdits([.edit(id, "I went to the store. It was closed today.")])
        await drainMainActor()
        XCTAssertTrue(core.revertChange(fix, segmentID: id))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I went to teh store. It was closed today.")
    }

    // Reviewer 7: undo after another paragraph settles.
    func testUndoAfterAnotherParagraphSettles() async {
        let core = makeCore(.cloudOn)
        let a = await dictate(core, raw: "I went to teh store.")
        let fixA = SpanEdit(find: "teh", replace: "the", reason: "typo")
        cleaner.finish(0, .success([fixA]))
        await drainMainActor()
        let b = await dictate(core, raw: "It was realy closed.")
        guard let bi = cleaner.index(for: "It was realy closed.") else { return XCTFail("no call for B") }
        cleaner.finish(bi, .success([SpanEdit(find: "realy", replace: "really", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(b)?.currentText, "It was really closed.")
        XCTAssertTrue(core.revertChange(fixA, segmentID: a))
        await drainMainActor()
        XCTAssertEqual(core.segment(a)?.currentText, "I went to teh store.")
        XCTAssertEqual(core.segment(b)?.currentText, "It was really closed.")
    }

    // Reviewer 7: merged-paragraph history.
    func testMergedParagraphKeepsHistoryOfBothTakes() async {
        let core = makeCore(.cloudOff)
        let a = await dictate(core, raw: "First part.", stem: "stemA")
        let b = await dictate(core, raw: "Second part.", stem: "stemB")
        core.applyUserEdits([.merge(owner: a, absorbed: [b], text: "First part. Second part.")])
        await drainMainActor()
        XCTAssertEqual(core.displayedSegments.count, 1)
        guard let v = core.versions(for: a) else { return XCTFail("no versions for merged paragraph") }
        XCTAssertEqual(v.takes, 2)
        let mergedOriginal = v.original ?? ""
        XCTAssertTrue(mergedOriginal.contains("First part.") && mergedOriginal.contains("Second part."),
                      "merged original should contain both takes, got \(mergedOriginal)")
        let outcome = core.returnPressed()
        XCTAssertEqual(commitString(outcome), "First part. Second part.")
        let artifact = core.commitSucceeded(targetApp: "Notes")
        XCTAssertEqual(artifact.paragraphs.count, 1)
        XCTAssertEqual(Set(artifact.paragraphs.first?.componentStems ?? []), ["stemA", "stemB"])
    }

    // MARK: hand edits and Return

    // Requirement: hand edits, then Return.
    func testHandEditWinsOverLateCleanup() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        core.applyUserEdits([.edit(id, "I walked to the shop.")])
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I walked to the shop.")
    }

    // Requirement: hand edits, then Return.
    func testReturnInsertsTheEditedText() async {
        let core = makeCore(.cloudOff)
        let id = await dictate(core, raw: "Draft text here.")
        core.applyUserEdits([.edit(id, "Final text here.")])
        await drainMainActor()
        XCTAssertEqual(commitString(core.returnPressed()), "Final text here.")
    }

    // Reviewer 4: Return during recording finishes the take and shows its text; never silently omit it.
    func testReturnDuringRecordingWaitsAndIncludesTheTake() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "Earlier paragraph.")
        let id = core.beginTake()
        let first = core.returnPressed()
        if case .commit = first { XCTFail("Return while recording must not insert before the take finishes") }
        core.takeStopped(id)
        core.takeTranscribed(id, raw: "Last words.", pipelineText: "Last words.")
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Last words.", "take text must be displayed")
        let committed = commitString(core.returnPressed()) ?? core.commitText
        XCTAssertTrue(committed.contains("Last words."), "the take must be in the inserted text, got \(committed)")
        XCTAssertTrue(committed.contains("Earlier paragraph."))
    }

    // Reviewer 4: Return during transcription.
    func testReturnDuringTranscriptionWaitsAndIncludesTheTake() async {
        let core = makeCore(.cloudOff)
        let id = core.beginTake()
        core.takeStopped(id)
        let first = core.returnPressed()
        if case .commit = first { XCTFail("Return while transcribing must not insert before the take finishes") }
        core.takeTranscribed(id, raw: "Only words.", pipelineText: "Only words.")
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Only words.")
        let committed = commitString(core.returnPressed()) ?? core.commitText
        XCTAssertTrue(committed.contains("Only words."))
    }

    // Requirement: optimize for speed. Return with cleanup still running inserts what is shown.
    func testReturnWithCleanupRunningInsertsShownText() async {
        let core = makeCore(.cloudOn)
        await dictate(core, raw: "Send it now.")
        XCTAssertEqual(cleaner.openCallCount, 1)
        XCTAssertEqual(commitString(core.returnPressed()), "Send it now.")
    }

    func testReturnOnEmptyDraftInsertsNothing() {
        let core = makeCore(.cloudOff)
        if case .nothingToInsert = core.returnPressed() {} else { XCTFail("expected nothingToInsert") }
    }

    // MARK: Esc

    // Reviewer 3: guard dismissal of every nonempty draft, including a short one.
    func testEscOnShortDraftAsksForConfirmation() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "Yes.")
        let outcome = core.escapePressed()
        if case .armed = outcome {} else { XCTFail("short draft must not close on one Esc, got \(outcome)") }
        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(core.displayedSegments.first?.currentText, "Yes.")
    }

    // Reviewer 3: typed-only drafts are also guarded (audio archives do not recover typing).
    func testEscOnTypedOnlyDraftAsksForConfirmation() async {
        let core = makeCore(.cloudOff)
        core.applyUserEdits([.addTyped(UUID(), "typed by hand")])
        await drainMainActor()
        let outcome = core.escapePressed()
        if case .armed = outcome {} else { XCTFail("typed draft must not close on one Esc, got \(outcome)") }
        XCTAssertTrue(core.isOpen)
    }

    // Reviewer 3: confirmed dismissal closes.
    func testSecondEscConfirmsDismissal() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "Throwaway.")
        let now = Date()
        _ = core.escapePressed(now: now)
        let second = core.escapePressed(now: now.addingTimeInterval(0.5))
        if case .closed = second {} else { XCTFail("expected close on confirmed Esc, got \(second)") }
        XCTAssertFalse(core.isOpen)
    }

    func testEscOnEmptyDraftCloses() {
        let core = makeCore(.cloudOff)
        if case .closed = core.escapePressed() {} else { XCTFail("empty draft should close on Esc") }
    }

    // Esc while recording discards only that take; the draft stays.
    func testEscWhileRecordingDiscardsOnlyTheTake() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "Keep me.")
        let id = core.beginTake()
        let outcome = core.escapePressed()
        if case .discardedTake = outcome {} else { XCTFail("expected discardedTake, got \(outcome)") }
        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(core.displayedSegments.map(\.currentText), ["Keep me."])
        _ = id
    }

    // MARK: cloud off and consent

    // Reviewer 6: cloud-off behavior immediate; nothing sent.
    func testCloudOffSendsNothing() async {
        let core = makeCore(.cloudOff)
        let id = await dictate(core, raw: "Private note.")
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertEqual(core.segment(id)?.currentText, "Private note.")
    }

    // Reviewer 6: no consent means nothing sent.
    func testNoConsentSendsNothing() async {
        let core = makeCore(.noConsent)
        await dictate(core, raw: "Private note.")
        XCTAssertEqual(cleaner.callCount, 0)
    }

    // Reviewer 6: running calls stopped when cloud is turned off, and their late results ignored.
    func testTurningCloudOffCancelsRunningCall() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        XCTAssertEqual(cleaner.callCount, 1)
        core.setCleanupEnabled(false)
        await drainMainActor()
        XCTAssertTrue(cleaner.calls[0].cancellation.isCancelled)
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "I went to teh store.")
    }

    // Reviewer 6: queued calls never sent after cloud off.
    func testQueuedCallsNeverSentAfterCloudOff() async {
        let core = makeCore(.cloudOn)
        for i in 0..<6 { await dictate(core, raw: "Paragraph number \(i).") }
        let before = cleaner.callCount
        core.setCleanupEnabled(false)
        await drainMainActor()
        for i in 0..<before { cleaner.finish(i, .failure(.timedOut)) }
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, before, "no queued or retried call may start after cloud off")
        for call in cleaner.calls { XCTAssertTrue(call.cancellation.isCancelled) }
    }

    // Reviewer 6: no retries while cloud is off.
    func testNoRetryWhileCloudOff() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "Retry me.")
        cleaner.finish(0, .failure(.timedOut))
        await drainMainActor()
        core.setCleanupEnabled(false)
        await drainMainActor()
        let before = cleaner.callCount
        core.retryCleanup(id)
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, before)
    }

    // Reviewer 6: revoking consent stops running calls immediately.
    func testRevokingConsentCancelsRunningCall() async {
        let core = makeCore(.cloudOn)
        await dictate(core, raw: "Something private.")
        core.setConsentGiven(false)
        await drainMainActor()
        XCTAssertTrue(cleaner.calls[0].cancellation.isCancelled)
    }

    // MARK: A/B compare

    // Requirement: an A/B mode comparing methods, for example Sonnet and Opus.
    func testCompareSonnetAndOpusOnSameParagraphAppliesNothingUntilChosen() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.")
        cleaner.finish(0, .failure(.timedOut))
        await drainMainActor()
        let base = core.segment(id)?.currentText
        XCTAssertTrue(core.startCompare(segmentID: id, models: [.sonnet, .opus]))
        await drainMainActor()
        guard let si = cleaner.lastIndex(model: .sonnet), let oi = cleaner.lastIndex(model: .opus), si != oi
        else { return XCTFail("expected one sonnet and one opus call") }
        XCTAssertEqual(cleaner.calls[si].raw, "I went to teh store.")
        XCTAssertEqual(cleaner.calls[oi].raw, "I went to teh store.")
        cleaner.finish(si, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        cleaner.finish(oi, .success([SpanEdit(find: "went", replace: "walked", reason: "style")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, base, "nothing applied before a choice")
        XCTAssertEqual(core.comparison?.candidates.count, 2)
        XCTAssertTrue(core.chooseCandidate("A"))
        await drainMainActor()
        // shuffle is identity, so A is the first model given (Sonnet).
        XCTAssertEqual(core.segment(id)?.currentText, "I went to the store.")
    }

    // Requirement: Haiku can be in the comparison too.
    func testCompareCanIncludeHaiku() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "Short one.")
        cleaner.finish(0, .success([]))
        await drainMainActor()
        XCTAssertTrue(core.startCompare(segmentID: id, models: [.haiku, .sonnet]))
        await drainMainActor()
        XCTAssertNotNil(cleaner.lastIndex(model: .haiku))
    }

    // Reviewer 1: on-demand comparison only; routine cleanup makes no duplicate calls.
    func testRoutineCleanupMakesExactlyOneCallPerDictation() async {
        let core = makeCore(.cloudOn)
        await dictate(core, raw: "One.")
        await dictate(core, raw: "Two.")
        XCTAssertEqual(cleaner.callCount, 2)
        XCTAssertTrue(cleaner.calls.allSatisfy { $0.model == .sonnet })
        XCTAssertNil(core.comparison)
    }

    // Reviewer 1: model selection from the options control.
    func testModelSelectionAppliesToNextCleanup() async {
        let core = makeCore(.cloudOn)
        core.setModel(.opus)
        await dictate(core, raw: "Use opus.")
        XCTAssertEqual(cleaner.calls.first?.model, .opus)
    }

    // Reviewer 6 plus 1: no comparison calls when cloud is off.
    func testCompareRefusedWhenCloudOff() async {
        let core = makeCore(.cloudOff)
        let id = await dictate(core, raw: "Private.")
        XCTAssertFalse(core.startCompare(segmentID: id, models: [.sonnet, .opus]))
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 0)
    }

    // MARK: destination (reviewer 5)

    func testConfirmedSamePlaceInserts() {
        let v = EditDestination.verdict(target: target, isRemoteDesktop: false, observed: confirmedObservation())
        if case .insert = v {} else { XCTFail("confirmed same window and field should insert, got \(v)") }
    }

    func testSameAppDifferentWindowRetains() {
        let o = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: false,
                                      sameTitle: true, sameField: true, secureInputActive: false,
                                      activationTimedOut: false)
        XCTAssertTrue(isRetain(EditDestination.verdict(target: target, isRemoteDesktop: false, observed: o)))
    }

    func testSameWindowDifferentConversationRetains() {
        let o = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: true,
                                      sameTitle: false, sameField: true, secureInputActive: false,
                                      activationTimedOut: false)
        XCTAssertTrue(isRetain(EditDestination.verdict(target: target, isRemoteDesktop: false, observed: o)))
    }

    func testDifferentFieldRetains() {
        let o = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: true,
                                      sameTitle: true, sameField: false, secureInputActive: false,
                                      activationTimedOut: false)
        XCTAssertTrue(isRetain(EditDestination.verdict(target: target, isRemoteDesktop: false, observed: o)))
    }

    func testTargetQuitRetains() {
        let o = EditTargetObservation(targetStillRunning: false, frontmostPID: nil, sameWindow: nil,
                                      sameTitle: nil, sameField: nil, secureInputActive: false,
                                      activationTimedOut: false)
        XCTAssertTrue(isRetain(EditDestination.verdict(target: target, isRemoteDesktop: false, observed: o)))
    }

    func testDifferentFrontmostAppRetains() {
        XCTAssertTrue(isRetain(EditDestination.verdict(target: target, isRemoteDesktop: false,
                                                       observed: confirmedObservation(pid: 999))))
    }

    func testUncertainWindowOrFieldRetains() {
        let unknownWindow = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: nil,
                                                  sameTitle: nil, sameField: true, secureInputActive: false,
                                                  activationTimedOut: false)
        let unknownField = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: true,
                                                 sameTitle: true, sameField: nil, secureInputActive: false,
                                                 activationTimedOut: false)
        let timedOut = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: true,
                                             sameTitle: true, sameField: true, secureInputActive: false,
                                             activationTimedOut: true)
        let secure = EditTargetObservation(targetStillRunning: true, frontmostPID: 4242, sameWindow: true,
                                           sameTitle: true, sameField: true, secureInputActive: true,
                                           activationTimedOut: false)
        for o in [unknownWindow, unknownField, timedOut, secure] {
            XCTAssertTrue(isRetain(EditDestination.verdict(target: target, isRemoteDesktop: false, observed: o)))
        }
    }

    func testUnknownOriginalDestinationRetains() {
        XCTAssertTrue(isRetain(EditDestination.verdict(target: nil, isRemoteDesktop: false,
                                                       observed: confirmedObservation())))
    }

    func testTerminalIsCopyOnly() {
        let term = EditTargetIdentity(pid: 4242, bundleID: "com.apple.Terminal", appName: "Terminal",
                                      windowTitle: "zsh", hasWindow: true, hasField: true)
        XCTAssertTrue(isRetain(EditDestination.verdict(target: term, isRemoteDesktop: false,
                                                       observed: confirmedObservation())))
    }

    // Reviewer 5: retain the draft on fallback and copy it.
    func testRetainedCommitCopiesAndKeepsDraft() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "Do not lose this.")
        let outcome = core.returnPressed()
        XCTAssertEqual(commitString(outcome), "Do not lose this.")
        let quit = EditTargetObservation(targetStillRunning: false, frontmostPID: nil, sameWindow: nil,
                                         sameTitle: nil, sameField: nil, secureInputActive: false,
                                         activationTimedOut: false)
        guard case .retain(let reason) = EditDestination.verdict(target: target, isRemoteDesktop: false,
                                                                  observed: quit)
        else { return XCTFail("expected retain") }
        core.commitRetained(reason)
        await drainMainActor()
        XCTAssertEqual(clipboard.copies.last, "Do not lose this.")
        XCTAssertTrue(core.displayedSegments.contains { $0.currentText == "Do not lose this." },
                      "draft must be retained, not discarded")
        if case .cancelled = core.state.lifecycle { XCTFail("retained draft must not be cancelled") }
    }

    // MARK: Recents

    // Requirement: the full dictation is one recent entry, with its component dictations
    // listed below it, each line starting with "⤷".
    func testRecentsStoreFullDictationWithComponents() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "First part.", stem: "stem-one")
        await dictate(core, raw: "Second part.", stem: "stem-two")
        guard let committed = commitString(core.returnPressed()) else { return XCTFail("no commit") }
        let artifact = core.commitSucceeded(targetApp: "Notes")
        XCTAssertEqual(artifact.text, committed)
        XCTAssertNotNil(EditRecents.write(artifact))
        let sessions = EditRecents.list(limit: 10)
        XCTAssertEqual(sessions.count, 1)
        guard let s = sessions.first else { return }
        XCTAssertEqual(s.text, committed)
        XCTAssertEqual(s.components.count, 2)
        for p in s.components {
            XCTAssertTrue(EditRecents.componentTitle(p).hasPrefix("⤷"),
                          "component line must start with the arrow, got \(EditRecents.componentTitle(p))")
        }
        XCTAssertFalse(EditRecents.parentTitle(s).hasPrefix("⤷"))
    }

    // Reviewer 7: final Recents content equals what was committed (hand edits included).
    func testRecentsContentIsTheFinalCommittedText() async {
        let core = makeCore(.cloudOn)
        let id = await dictate(core, raw: "I went to teh store.", stem: "s1")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        core.applyUserEdits([.edit(id, "I went to the corner store.")])
        await drainMainActor()
        XCTAssertEqual(commitString(core.returnPressed()), "I went to the corner store.")
        let artifact = core.commitSucceeded(targetApp: "Notes")
        _ = EditRecents.write(artifact)
        XCTAssertEqual(EditRecents.list(limit: 5).first?.text, "I went to the corner store.")
    }

    // Requirement: components are not separate top-level entries.
    func testMergedRecentsShowsSessionOnceNotItsComponentsSeparately() async {
        let core = makeCore(.cloudOff)
        await dictate(core, raw: "Alpha.", stem: "comp-a")
        await dictate(core, raw: "Beta.", stem: "comp-b")
        _ = core.returnPressed()
        let artifact = core.commitSucceeded(targetApp: "Notes")
        _ = EditRecents.write(artifact)
        let sessions = EditRecents.list(limit: 10)
        let now = Date()
        let recs = [
            Recording(url: tempDir.appendingPathComponent("comp-a.wav"), date: now, text: "Alpha."),
            Recording(url: tempDir.appendingPathComponent("comp-b.wav"), date: now, text: "Beta."),
            Recording(url: tempDir.appendingPathComponent("other.wav"), date: now.addingTimeInterval(-60), text: "Other."),
        ]
        let items = EditRecents.merge(recordings: recs, sessions: sessions)
        var sessionCount = 0
        var recordingNames: [String] = []
        for item in items {
            switch item {
            case .session: sessionCount += 1
            case .recording(let url): recordingNames.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(sessionCount, 1)
        XCTAssertEqual(recordingNames, ["other.wav"], "component recordings should sit under the session")
    }

    // MARK: hotkey modes

    // Requirement: a third hotkey option beside toggle and hold; tapping fn opens the editor.
    func testEditModeTapRoutesToEditSession() {
        if case .routeToEditSession = HotkeyRouting.keyDown(mode: .edit, isPressed: false, hasEditRouter: true) {}
        else { XCTFail("fn tap in edit mode should route to the edit session") }
        if case .startRecording = HotkeyRouting.keyUp(mode: .edit) { XCTFail("key up must not start recording") }
        if case .stopRecording = HotkeyRouting.keyUp(mode: .edit) { XCTFail("tap mode: key up must not stop") }
    }

    // Hold and toggle behave as before.
    func testHoldAndToggleUnchanged() {
        if case .startRecording = HotkeyRouting.keyDown(mode: .hold, isPressed: false, hasEditRouter: true) {}
        else { XCTFail("hold: key down starts recording") }
        if case .stopRecording = HotkeyRouting.keyUp(mode: .hold) {} else { XCTFail("hold: key up stops recording") }
        if case .routeToEditSession = HotkeyRouting.keyDown(mode: .toggle, isPressed: false, hasEditRouter: true) {
            XCTFail("toggle must not route to edit session")
        }
        if case .routeToEditSession = HotkeyRouting.keyDown(mode: .hold, isPressed: false, hasEditRouter: true) {
            XCTFail("hold must not route to edit session")
        }
        if case .stopRecording = HotkeyRouting.keyUp(mode: .toggle) { XCTFail("toggle: key up does not stop") }
    }
}
