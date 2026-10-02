// Claude · 2026-09-24 · Edit Mode V1
import XCTest
@testable import SpeakFreeLib

/// The Edit Mode session, headless: takes, instant paragraphs, background cleanup, Return, Esc,
/// cloud on/off, versions, restore, compare, retain. The cleaner and clipboard are fakes, so no
/// test touches the real CLI, keystrokes, or the pasteboard.
@MainActor
final class EditSessionCoreTests: XCTestCase {

    private var scratch: URL!
    private var cleaner: ScriptedCleaner!
    private var clipboard: FakeClipboard!
    private var events: [EditCoreEvent] = []

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        cleaner = ScriptedCleaner()
        clipboard = FakeClipboard()
        events = []
    }

    override func tearDown() async throws {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeCore(_ settings: EditModeSettings = .cloudOn,
                          shuffle: @escaping ([CleanupService.Model]) -> [CleanupService.Model] = { $0 })
        -> EditSessionCore {
        let core = EditSessionCore(persistenceEnabled: false, settings: settings, cleaner: cleaner,
                                   clipboard: clipboard, shuffle: shuffle)
        core.onEvent = { [weak self] in self?.events.append($0) }
        return core
    }

    @discardableResult
    private func dictate(_ core: EditSessionCore, raw: String? = nil, _ text: String) -> UUID {
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: raw ?? text.lowercased(), pipelineText: text)
        return id
    }

    // MARK: Instant paragraphs

    func testTakeTextAppearsAtOnceAsItsOwnParagraph() async {
        let core = makeCore()
        let a = dictate(core, "First thought.")
        XCTAssertEqual(core.displayedSegments.map(\.currentText), ["First thought."])
        XCTAssertTrue(events.contains(.appended(a)), "the on-device text is shown before any cleanup")
        let b = dictate(core, "Second thought.")
        XCTAssertEqual(core.displayedSegments.map(\.id), [a, b])
        XCTAssertEqual(core.commitText, "First thought.\n\nSecond thought.",
                       "each dictation is a paragraph; outside the window a paragraph break is a blank line")
    }

    func testCleanupReceivesRawAndPipelineTextAndSettlesInBackground() async {
        let core = makeCore()
        let id = dictate(core, raw: "the cat sat Kama down", "The cat sat Kama down.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 1)
        XCTAssertEqual(cleaner.calls[0].raw, "the cat sat Kama down")
        XCTAssertEqual(cleaner.calls[0].pipelineText, "The cat sat Kama down.")
        XCTAssertEqual(core.segment(id)?.state, .cleaning)
        cleaner.finish(0, .success([SpanEdit(find: " Kama", replace: ",", reason: "spoken comma")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "The cat sat, down.")
        XCTAssertTrue(events.contains(.replaced(id, animate: true)))
    }

    func testAtMostTwoCleanupsRunAtOnceAndTheRestQueue() async {
        let core = makeCore()
        dictate(core, "One.")
        dictate(core, "Two.")
        dictate(core, "Three.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 2)
        XCTAssertEqual(core.cleaningCount, 3, "two running plus one queued")
        cleaner.finish(0, .success([]))
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 3, "the queued paragraph starts when a slot frees")
    }

    // MARK: Consent and cloud-off

    func testNothingIsSentWithoutConsent() async {
        let core = makeCore(.noConsent)
        dictate(core, "Private words.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertTrue(core.cleanupStatusLine.contains("off"))
    }

    func testNothingIsSentWithCleanupOff() async {
        let core = makeCore(.cloudOff)
        dictate(core, "Private words.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertEqual(core.cleanupStatusLine, "Cleanup off (on-device only)")
    }

    func testTurningCleanupOffStopsRunningAndQueuedCallsImmediately() async {
        let core = makeCore()
        let a = dictate(core, "One.")
        let b = dictate(core, "Two.")
        let c = dictate(core, "Three.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 2)
        core.setCleanupEnabled(false)
        XCTAssertTrue(cleaner.calls[0].cancellation.isCancelled)
        XCTAssertTrue(cleaner.calls[1].cancellation.isCancelled)
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 2, "the queued third paragraph is never sent")
        for id in [a, b, c] {
            XCTAssertEqual(core.segment(id)?.state, .provisional, "back to on-device text, no failure mark")
        }
        XCTAssertEqual(core.failedCount, 0)
        XCTAssertEqual(core.commitText, "One.\n\nTwo.\n\nThree.")
    }

    func testLateResultAfterCloudOffChangesNothing() async {
        let core = makeCore()
        let id = dictate(core, "Keep this text.")
        await drainMainActor()
        let call = cleaner.calls[0]
        core.setCleanupEnabled(false)
        // A result that raced the cancel is dropped.
        cleaner.finish(0, .success([SpanEdit(find: "Keep", replace: "Drop", reason: "x")]))
        await drainMainActor()
        XCTAssertTrue(call.cancellation.isCancelled)
        XCTAssertEqual(core.segment(id)?.currentText, "Keep this text.")
    }

    func testTurningCleanupBackOnCleansParagraphsStillOnDeviceText() async {
        let core = makeCore(.cloudOff)
        dictate(core, "One.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 0)
        core.setCleanupEnabled(true)
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 1)
    }

    // MARK: Hand edits win

    func testHandEditDuringCleanupWinsAndCancelsTheCall() async {
        let core = makeCore()
        let id = dictate(core, "Meet on Tuesday.")
        await drainMainActor()
        core.applyUserEdits([.edit(id, "Meet on Thursday.")])
        XCTAssertTrue(cleaner.calls[0].cancellation.isCancelled)
        cleaner.finish(0, .success([SpanEdit(find: "Meet", replace: "Met", reason: "x")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Meet on Thursday.")
        XCTAssertEqual(core.segment(id)?.state, .edited)
    }

    func testEditingOneParagraphDoesNotBlockAnotherFromSettling() async {
        let core = makeCore()
        let a = dictate(core, "Alpha teh.")
        let b = dictate(core, "Beta teh.")
        await drainMainActor()
        core.applyUserEdits([.edit(a, "Alpha typed.")])
        cleaner.finish(cleaner.index(for: "Beta teh.")!, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(a)?.currentText, "Alpha typed.")
        XCTAssertEqual(core.segment(b)?.currentText, "Beta the.")
    }

    // MARK: Return

    func testReturnDuringRecordingFinishesTheTakeShowsItThenInserts() async {
        let core = makeCore(.cloudOff)
        dictate(core, "Earlier paragraph.")
        let id = core.beginTake()
        XCTAssertEqual(core.returnPressed(), .waitingForTake)
        XCTAssertTrue(core.pendingCommit)
        core.takeStopped(id)
        XCTAssertFalse(events.contains(.readyToCommit), "not before the take's text is in")
        core.takeTranscribed(id, raw: "last words", pipelineText: "Last words.")
        let appendedAt = events.firstIndex(of: .appended(id))
        let readyAt = events.firstIndex(of: .readyToCommit)
        XCTAssertNotNil(appendedAt)
        XCTAssertNotNil(readyAt)
        XCTAssertLessThan(appendedAt!, readyAt!, "the take is on screen before insertion is signalled")
        XCTAssertEqual(core.returnPressed(), .commit("Earlier paragraph.\n\nLast words."))
    }

    func testReturnWhileTranscribingWaits() {
        let core = makeCore(.cloudOff)
        let id = core.beginTake()
        core.takeStopped(id)
        XCTAssertEqual(core.returnPressed(), .waitingForTake)
    }

    func testReturnWaitingOnATakeThatProducedNothingStillCommitsTheRest() {
        let core = makeCore(.cloudOff)
        dictate(core, "Only paragraph.")
        let id = core.beginTake()
        XCTAssertEqual(core.returnPressed(), .waitingForTake)
        core.takeProducedNothing(id)
        XCTAssertTrue(events.contains(.readyToCommit))
        XCTAssertEqual(core.returnPressed(), .commit("Only paragraph."))
    }

    func testReturnDoesNotWaitForCleanupAndLateResultsAreIgnored() async {
        let core = makeCore()
        let id = dictate(core, "Ship it teh way it is.")
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.state, .cleaning)
        XCTAssertEqual(core.returnPressed(), .commit("Ship it teh way it is."))
        let artifact = core.commitSucceeded(targetApp: "com.example.app")
        XCTAssertEqual(artifact.text, "Ship it teh way it is.")
        cleaner.finish(0, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.state.lifecycle, .committed)
        XCTAssertEqual(core.segment(id)?.currentText, "Ship it teh way it is.")
    }

    func testEmptyWindowReturnInsertsNothing() {
        let core = makeCore()
        XCTAssertEqual(core.returnPressed(), .nothingToInsert)
    }

    // MARK: Esc

    func testEscWhileRecordingDiscardsOnlyThatTake() {
        let core = makeCore(.cloudOff)
        dictate(core, "Keep me.")
        _ = core.beginTake()
        XCTAssertEqual(core.escapePressed(), .discardedTake)
        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(core.commitText, "Keep me.")
    }

    func testEscOnAnyNonEmptyDraftNeedsASecondPress() {
        let core = makeCore(.cloudOff)
        dictate(core, "ok")   // short on purpose: short drafts are guarded too
        let t0 = Date()
        XCTAssertEqual(core.escapePressed(now: t0), .armed)
        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(core.escapePressed(now: t0.addingTimeInterval(1)), .closed)
        XCTAssertEqual(core.state.lifecycle, .cancelled)
    }

    func testSecondEscAfterTheWindowReArmsInsteadOfDiscarding() {
        let core = makeCore(.cloudOff)
        dictate(core, "Something.")
        let t0 = Date()
        XCTAssertEqual(core.escapePressed(now: t0), .armed)
        XCTAssertEqual(core.escapePressed(now: t0.addingTimeInterval(10)), .armed)
        XCTAssertTrue(core.isOpen)
    }

    func testEscOnEmptyWindowClosesAtOnce() {
        let core = makeCore()
        XCTAssertEqual(core.escapePressed(), .closed)
    }

    func testTypingDisarmsEsc() {
        let core = makeCore(.cloudOff)
        let id = dictate(core, "Draft.")
        XCTAssertEqual(core.escapePressed(), .armed)
        core.applyUserEdits([.edit(id, "Draft, edited.")])
        XCTAssertFalse(core.isEscArmed())
        XCTAssertEqual(core.escapePressed(), .armed, "a fresh first press after typing")
    }

    // MARK: Retain

    func testRetainCopiesTheTextAndKeepsTheDraftOpen() {
        let core = makeCore(.cloudOff)
        dictate(core, "Para one.")
        dictate(core, "Para two.")
        core.commitRetained(.differentWindow)
        XCTAssertEqual(clipboard.copies, ["Para one.\n\nPara two."])
        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(core.commitText, "Para one.\n\nPara two.")
        XCTAssertTrue(core.notice?.contains("copied") == true)
    }

    // MARK: Versions

    func testOriginalPreviousAndCurrentAfterCleanupEditAndRecleanup() async {
        let core = makeCore()
        let id = dictate(core, "Lunch is on Tuesday Kama bring snacks.")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: " Kama", replace: ",", reason: "spoken comma")]))
        await drainMainActor()
        core.applyUserEdits([.edit(id, "Lunch is on Tuesday, bring snacks please.")])
        core.retryCleanup(id)
        await drainMainActor()
        cleaner.finish(1, .success([SpanEdit(find: "snacks please", replace: "snacks, please", reason: "comma")]))
        await drainMainActor()
        let v = core.versions(for: id)!
        XCTAssertEqual(v.original, "Lunch is on Tuesday Kama bring snacks.")
        XCTAssertEqual(v.previous, "Lunch is on Tuesday, bring snacks please.",
                       "previous = the version right before the current one (his hand edit)")
        XCTAssertEqual(v.current, "Lunch is on Tuesday, bring snacks, please.")
    }

    func testRestoreOriginalAndPreviousAndCopy() async {
        let core = makeCore()
        let id = dictate(core, "Alpha beta.")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "beta", replace: "Beta", reason: "name")]))
        await drainMainActor()
        XCTAssertTrue(core.restore(.original, segmentID: id))
        XCTAssertEqual(core.segment(id)?.currentText, "Alpha beta.")
        XCTAssertTrue(core.restore(.previous, segmentID: id))
        XCTAssertEqual(core.segment(id)?.currentText, "Alpha Beta.", "restore is itself reversible")
        XCTAssertTrue(core.copyVersion(.original, segmentID: id))
        XCTAssertEqual(clipboard.copies.last, "Alpha beta.")
    }

    func testUndoOneChangeKeepsLaterHandEditsAndOtherChanges() async {
        let core = makeCore()
        let id = dictate(core, "We met Jon at teh park.")
        await drainMainActor()
        let jon = SpanEdit(find: "Jon", replace: "John", reason: "name")
        let teh = SpanEdit(find: "teh", replace: "the", reason: "typo")
        cleaner.finish(0, .success([jon, teh]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "We met John at the park.")
        core.applyUserEdits([.edit(id, "Yesterday we met John at the park.")])
        XCTAssertTrue(core.revertChange(jon, segmentID: id))
        XCTAssertEqual(core.segment(id)?.currentText, "Yesterday we met Jon at the park.",
                       "the one change is undone; the hand edit and the other fix stay")
    }

    func testUndoAChangeAfterAnotherParagraphSettles() async {
        let core = makeCore()
        let a = dictate(core, "Call Jon.")
        let b = dictate(core, "Bring teh file.")
        await drainMainActor()
        let jon = SpanEdit(find: "Jon", replace: "John", reason: "name")
        cleaner.finish(cleaner.index(for: "Call Jon.")!, .success([jon]))
        await drainMainActor()
        cleaner.finish(cleaner.index(for: "Bring teh file.")!, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertTrue(core.revertChange(jon, segmentID: a))
        XCTAssertEqual(core.segment(a)?.currentText, "Call Jon.")
        XCTAssertEqual(core.segment(b)?.currentText, "Bring the file.")
    }

    // MARK: Meaning (exact-match edits can still reverse meaning)

    func testNegationRemovingFixIsNotApplied() async {
        let core = makeCore()
        let id = dictate(core, "Do not approve the draft.")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "Do not approve", replace: "Approve", reason: "cleanup")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Do not approve the draft.")
        XCTAssertEqual(core.rejectedForMeaning, 1)
    }

    func testNegationAddingFixIsNotApplied() async {
        let core = makeCore()
        let id = dictate(core, "We can ship Friday.")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "can ship", replace: "can't ship", reason: "x")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "We can ship Friday.")
    }

    func testObviousSelfCorrectionIsRemoved() async {
        let core = makeCore()
        let id = dictate(core, "Let's meet Tuesday no wait Wednesday.")
        await drainMainActor()
        cleaner.finish(0, .success([SpanEdit(find: "Tuesday no wait Wednesday", replace: "Wednesday",
                                             reason: "self-correction")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Let's meet Wednesday.")
        XCTAssertEqual(core.versions(for: id)?.original, "Let's meet Tuesday no wait Wednesday.",
                       "the removed false start is still visible in the original")
    }

    // MARK: Failures are visible

    func testLoginFailureStopsFurtherCallsAndSaysWhy() async {
        let core = makeCore()
        let a = dictate(core, "One.")
        await drainMainActor()
        cleaner.finish(0, .failure(.notLoggedIn))
        await drainMainActor()
        XCTAssertEqual(core.segment(a)?.state, .failed)
        XCTAssertEqual(core.failureMessage(for: a), "not logged in to Claude")
        XCTAssertTrue(core.cleanupStatusLine.contains("not logged in"))
        dictate(core, "Two.")
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 1, "no doomed call per paragraph")
        XCTAssertEqual(core.returnPressed(), .commit("One.\n\nTwo."), "failed text is still insertable")
    }

    func testTimeoutMarksTheParagraphAndRetryCanSucceed() async {
        let core = makeCore()
        let id = dictate(core, "Fix teh typo.")
        await drainMainActor()
        cleaner.finish(0, .failure(.timedOut))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.state, .failed)
        XCTAssertEqual(core.progressLine, "cleanup failed on 1 paragraph")
        core.retryCleanup(id)
        await drainMainActor()
        cleaner.finish(1, .success([SpanEdit(find: "teh", replace: "the", reason: "typo")]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Fix the typo.")
        XCTAssertNil(core.failureMessage(for: id))
    }

    // MARK: Compare

    func testCompareRunsTheSameParagraphThroughTwoModelsAndAppliesOnlyTheChoice() async {
        let core = makeCore()
        let id = dictate(core, "Send it to Jon tomorrow.")
        await drainMainActor()
        cleaner.finish(0, .success([]))
        await drainMainActor()
        XCTAssertTrue(core.startCompare(segmentID: id, models: [.sonnet, .opus]))
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 3)
        XCTAssertEqual(cleaner.calls[1].pipelineText, "Send it to Jon tomorrow.")
        XCTAssertEqual(cleaner.calls[2].pipelineText, "Send it to Jon tomorrow.")
        XCTAssertEqual(Set([cleaner.calls[1].model, cleaner.calls[2].model]), [.sonnet, .opus])
        cleaner.finish(cleaner.lastIndex(model: .sonnet)!, .success([SpanEdit(find: "Jon", replace: "John", reason: "name")]))
        cleaner.finish(cleaner.lastIndex(model: .opus)!, .success([]))
        await drainMainActor()
        XCTAssertEqual(core.segment(id)?.currentText, "Send it to Jon tomorrow.", "nothing applied before a choice")
        XCTAssertEqual(core.comparison?.candidates.map(\.label), ["A", "B"])
        XCTAssertTrue(core.chooseCandidate("A"))
        XCTAssertEqual(core.segment(id)?.currentText, "Send it to John tomorrow.")
        XCTAssertTrue(core.notice?.contains("Sonnet") == true, "the models are revealed after the choice")
    }

    func testCompareIsInvalidatedByAnEdit() async {
        let core = makeCore()
        let id = dictate(core, "Alpha.")
        await drainMainActor()
        cleaner.finish(0, .success([]))
        await drainMainActor()
        core.startCompare(segmentID: id, models: [.sonnet, .haiku])
        await drainMainActor()
        cleaner.finish(cleaner.lastIndex(model: .sonnet)!, .success([SpanEdit(find: "Alpha", replace: "Alfa", reason: "x")]))
        cleaner.finish(cleaner.lastIndex(model: .haiku)!, .success([]))
        await drainMainActor()
        core.applyUserEdits([.edit(id, "Alpha, typed.")])
        XCTAssertTrue(core.comparison?.invalidated == true)
        XCTAssertFalse(core.chooseCandidate("A"))
        XCTAssertEqual(core.segment(id)?.currentText, "Alpha, typed.")
    }

    func testRoutineCleanupMakesOneCallPerParagraph() async {
        let core = makeCore()
        dictate(core, "One.")
        await drainMainActor()
        cleaner.finish(0, .success([]))
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 1, "no automatic duplicate calls")
    }

    func testCompareNeedsCloudOn() async {
        let core = makeCore(.cloudOff)
        let id = dictate(core, "One.")
        XCTAssertFalse(core.startCompare(segmentID: id, models: [.sonnet, .opus]))
        XCTAssertEqual(cleaner.callCount, 0)
    }

    // MARK: Merge, typed paragraphs, artifact

    func testMergedParagraphKeepsBothHistories() async {
        let core = makeCore(.cloudOff)
        let a = dictate(core, raw: "raw a", "First part.")
        let b = dictate(core, raw: "raw b", "Second part.")
        core.applyUserEdits([.merge(owner: a, absorbed: [b], text: "First part. Second part.")])
        XCTAssertEqual(core.displayedSegments.count, 1)
        let v = core.versions(for: a)!
        XCTAssertEqual(v.takes, 2)
        XCTAssertEqual(v.original, "First part. Second part.")
        XCTAssertEqual(core.segment(a)?.absorbed?.first?.id, b)
        XCTAssertTrue(events.contains(.restructured))
    }

    func testTypedParagraphWithNoDictation() {
        let core = makeCore(.cloudOff)
        core.applyUserEdits([.addTyped(UUID(), "Typed by hand.")])
        XCTAssertEqual(core.returnPressed(), .commit("Typed by hand."))
    }

    func testCommitArtifactHoldsEachParagraphAndItsRecordings() {
        let core = makeCore(.cloudOff)
        let a = core.beginTake()
        core.takeStopped(a)
        core.takeTranscribed(a, raw: "r1", pipelineText: "One.", componentStem: "recording-2026-09-24-100000-aaaa")
        let b = core.beginTake()
        core.takeStopped(b)
        core.takeTranscribed(b, raw: "r2", pipelineText: "Two.", componentStem: "recording-2026-09-24-100010-bbbb")
        let artifact = core.commitSucceeded(targetApp: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(artifact.text, "One.\n\nTwo.")
        XCTAssertEqual(artifact.paragraphs.map(\.text), ["One.", "Two."])
        XCTAssertEqual(artifact.paragraphs.map(\.componentStems),
                       [["recording-2026-09-24-100000-aaaa"], ["recording-2026-09-24-100010-bbbb"]])
    }

    func testTakeWithNoTextLeavesNoParagraph() {
        let core = makeCore()
        let id = core.beginTake()
        core.takeStopped(id)
        core.takeTranscribed(id, raw: "", pipelineText: "   ")
        XCTAssertTrue(core.displayedSegments.isEmpty)
        XCTAssertFalse(core.hasDraft)
    }
}
