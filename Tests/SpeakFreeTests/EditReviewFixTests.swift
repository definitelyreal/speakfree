// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import XCTest
import AppKit
@testable import SpeakFreeLib

/// One test (or more) per finding the code-aware review raised. The controller runs with fake
/// hooks: no window is shown, the real frontmost app is never read, the pasteboard, keystrokes,
/// microphone and claude CLI are never touched.
@MainActor
final class EditReviewFixTests: XCTestCase {

    private var scratch: URL!
    private var cleaner: ScriptedCleaner!
    private var clipboard: FakeClipboard!
    private var config: Config!
    private var recording = false
    private var pendingTargets: [(sessionID: UUID, segmentID: UUID)?] = []
    private var starts = 0, stops = 0, aborts = 0

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        // Test-safety (2026-09-25 fix/test-real-config): makeController() builds a real
        // EditSessionController, whose openSession() sets `persistenceEnabled` from
        // `DevMode.effectiveSaveRecordings(config)` — and DevMode.isActive is true on any
        // machine with a `~/.speakfree-dev` marker (every dev machine), REGARDLESS of
        // config.saveRecordings. With persistence on, every `.open`-lifecycle dispatch
        // (beginSegment/startTake/etc., used throughout this file's flows) schedules a
        // debounced (0.5s) background write via EditSessionDraftStore — and tearDown used
        // to reset configDirOverride immediately, so a straggler write could fire afterward
        // and hit the real ~/.config/speakfree/edit-session-draft.json (or, post-guard,
        // fatalError the whole test process). Force dev-mode off here so persistence is
        // deterministically false and no debounced write is ever scheduled, independent of
        // which machine runs the suite.
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        cleaner = ScriptedCleaner()
        clipboard = FakeClipboard()
        config = Config.defaultConfig
        config.keyMode = .edit
        config.editModeCloudConsent = "2026-09-24T00:00:00Z"
        recording = false
        pendingTargets = []
        starts = 0; stops = 0; aborts = 0
    }

    override func tearDown() async throws {
        // Defense in depth: even with dev-mode forced off above, drain past the default
        // draft-write debounce interval before releasing the override, so any future test
        // added here that flips persistence on some other way can't race tearDown.
        Thread.sleep(forTimeInterval: 0.6)
        unsetenv("SPEAKFREE_DEV_MODE")
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeController() -> EditSessionController {
        var hooks = EditSessionController.Hooks(
            setPendingTarget: { [weak self] t in self?.pendingTargets.append(t) },
            startRecording: { [weak self] in
                guard let self else { return false }
                self.starts += 1
                self.recording = true
                return true
            },
            stopRecording: { [weak self] in self?.stops += 1; self?.recording = false },
            abortRecording: { [weak self] in self?.aborts += 1; self?.recording = false },
            isInPostBuffer: { false },
            inserter: { nil },
            isRemoteDesktop: { _ in false },
            onSessionClosed: {},
            saveConfig: { [weak self] mutate in if var c = self?.config { mutate(&c); self?.config = c } },
            loadConfig: { [weak self] in self?.config ?? Config.defaultConfig },
            noteRecents: {})
        hooks.isRecording = { [weak self] in self?.recording ?? false }
        hooks.presentWindow = false
        hooks.captureFrontmostApp = false
        hooks.cleaner = cleaner
        hooks.clipboard = clipboard
        return EditSessionController(hooks: hooks)
    }

    private func payload(_ c: EditSessionController, _ text: String) -> EditFinalizePayload? {
        guard let core = c.core, let seg = core.recordingSegmentID ?? core.transcribingSegmentIDs.last
        else { return nil }
        let meta = RecordingStore.RecordingMeta(appVersion: "test", engine: "parakeet", model: "m",
                                                inputDevice: nil, date: "2026-09-24T00:00:00Z",
                                                durationSeconds: 1, transcriptChars: text.count)
        return EditFinalizePayload(sessionID: core.state.id, segmentID: seg, raw: text.lowercased(),
                                   pipelineText: text, audioURL: scratch.appendingPathComponent("none.wav"),
                                   meta: meta)
    }

    // MARK: Controller wiring

    func testFnTapsOpenRecordStopAndDeliverAParagraph() {
        let c = makeController()
        c.handleFnTap()
        XCTAssertTrue(c.isOpen)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(pendingTargets.last??.sessionID, c.core?.state.id)
        c.handleFnTap()
        XCTAssertEqual(stops, 1)
        c.deliver(payload(c, "Hello there.")!, kept: false)
        XCTAssertEqual(c.core?.displayedSegments.map(\.currentText), ["Hello there."])
    }

    func testInvalidAudioArchiveKeepsEditTextWithoutAudioComponent() throws {
        let c = makeController()
        c.handleFnTap(); c.handleFnTap()
        let take = try XCTUnwrap(payload(c, "The captured words survived."))
        try AudioArchiveIntegrity.markInvalid(take.audioURL)
        defer { AudioRecorder.discardRecoveryArtifacts(for: take.audioURL) }
        c.deliver(take, kept: true)
        XCTAssertEqual(c.core?.displayedSegments.map(\.currentText), ["The captured words survived."])
        XCTAssertNil(c.core?.displayedSegments.first?.componentStems)
    }

    func testATakeThatProducesNothingNeverHangsTheSession() {
        let c = makeController()
        c.handleFnTap()
        let id = c.core!.recordingSegmentID!
        c.handleFnTap()
        c.deliverNothing(sessionID: c.core!.state.id, segmentID: id)
        XCTAssertTrue(c.core!.transcribingSegmentIDs.isEmpty)
        XCTAssertTrue(c.core!.displayedSegments.isEmpty)
    }

    /// a tap while some other take is recording must not be adopted.
    func testTapWhileAnotherRecordingRunsIsNotAdopted() {
        let c = makeController()
        c.handleFnTap()
        c.handleFnTap()                       // stops take 1
        recording = true                      // something else is recording now
        let before = c.core!.state.segments.count
        c.handleFnTap()
        XCTAssertEqual(c.core!.state.segments.count, before, "no new take begins")
        XCTAssertEqual(starts, 1)
    }

    /// closing a session while a take records aborts that take.
    func testClosingWhileRecordingAbortsTheTake() {
        let c = makeController()
        c.handleFnTap()
        c.handleFnTap()
        c.deliver(payload(c, "Keep.")!, kept: false)
        c.handleFnTap()                       // take 2 recording
        XCTAssertNotNil(c.core?.recordingSegmentID)
        c.windowController?.onEscape?()       // Esc while recording: discard that take
        XCTAssertEqual(aborts, 1)
        c.windowController?.onEscape?()       // arms
        c.windowController?.onEscape?()       // closes
        XCTAssertFalse(c.isOpen)
        XCTAssertFalse(recording)
    }

    /// turning cleanup off in Settings reaches an open session immediately.
    func testSettingsCloudOffReachesTheOpenSessionAtOnce() async {
        let c = makeController()
        c.handleFnTap()
        c.handleFnTap()
        c.deliver(payload(c, "Send nothing more.")!, kept: false)
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 1)
        config.editModeCleanup = FlexBool(false)
        c.configChanged()
        XCTAssertTrue(cleaner.calls[0].cancellation.isCancelled)
        c.handleFnTap()
        c.handleFnTap()
        c.deliver(payload(c, "Second.")!, kept: false)
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, 1, "nothing new is sent after Settings turned cleanup off")
    }

    func testReturnWithoutAConfirmedPlaceCopiesAndKeepsTheDraft() async {
        let c = makeController()
        c.handleFnTap()
        c.handleFnTap()
        c.deliver(payload(c, "Keep me safe.")!, kept: false)
        c.windowController?.onReturn?()
        await drainMainActor()
        XCTAssertTrue(c.isOpen)
        XCTAssertEqual(clipboard.copies, ["Keep me safe."])
        XCTAssertFalse(c.committing)
    }

    // MARK: input-method composition never deletes a take

    func testComposingWhileATakeArrivesKeepsBothTexts() async throws {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff, cleaner: cleaner,
                                   clipboard: clipboard)
        let wc = EditWindowController(core: core, targetName: nil)
        core.onEvent = { [weak wc] in wc?.handle($0) }
        let a = core.beginTake(); core.takeStopped(a)
        core.takeTranscribed(a, raw: "one", pipelineText: "One.")
        wc.textView.setSelectedRange(NSRange(location: 4, length: 0))
        wc.textView.setMarkedText(" か", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(wc.textView.hasMarkedText())
        let b = core.beginTake(); core.takeStopped(b)
        core.takeTranscribed(b, raw: "two", pipelineText: "Two.")   // arrives mid-composition
        wc.textView.insertText(" 家", replacementRange: wc.textView.markedRange())  // composition ends
        try await Task.sleep(nanoseconds: 600_000_000)
        await drainMainActor()
        XCTAssertNotNil(core.segment(b), "the take that arrived during composition survives")
        XCTAssertEqual(core.segment(a)?.currentText, "One. 家")
        XCTAssertEqual(core.segment(b)?.currentText, "Two.")
        XCTAssertEqual(wc.textView.string, "One. 家\nTwo.")
    }

    // MARK: an unconfirmed insert is uncertain (notice never invites a retry)

    func testUncertainInsertNoticeDoesNotInviteReturn() {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff, cleaner: cleaner,
                                   clipboard: clipboard)
        let id = core.beginTake(); core.takeStopped(id)
        core.takeTranscribed(id, raw: "x", pipelineText: "Maybe landed.")
        core.commitRetained(.insertionUncertain)
        XCTAssertTrue(core.isOpen)
        XCTAssertEqual(clipboard.copies, ["Maybe landed."])
        XCTAssertFalse(core.notice?.contains("Return") ?? true)
        XCTAssertTrue(core.notice?.contains("Check the app") ?? false)
    }

    // MARK: apps whose title does not name the conversation

    func testTitleThatIsJustTheAppNameCannotConfirmTheConversation() {
        let claude = EditTargetIdentity(pid: 3, bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
                                        windowTitle: "Claude", hasWindow: true, hasField: false)
        let untitled = EditTargetIdentity(pid: 3, bundleID: "x", appName: "X",
                                          windowTitle: nil, hasWindow: true, hasField: false)
        let ok = EditTargetObservation(targetStillRunning: true, frontmostPID: 3, sameWindow: true,
                                       sameTitle: true, sameField: nil, secureInputActive: false,
                                       activationTimedOut: false)
        XCTAssertEqual(EditDestination.verdict(target: claude, isRemoteDesktop: false, observed: ok),
                       .retain(.conversationUnknown))
        XCTAssertEqual(EditDestination.verdict(target: untitled, isRemoteDesktop: false, observed: ok),
                       .retain(.conversationUnknown))
        let slack = EditTargetIdentity(pid: 3, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                                       windowTitle: "design (Team) - Slack", hasWindow: true, hasField: false)
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: ok), .insert)
        // A native app with a captured field does not depend on the title.
        let notes = EditTargetIdentity(pid: 3, bundleID: "com.apple.Notes", appName: "Notes",
                                       windowTitle: "Notes", hasWindow: true, hasField: true)
        let okField = EditTargetObservation(targetStillRunning: true, frontmostPID: 3, sameWindow: true,
                                            sameTitle: true, sameField: true, secureInputActive: false,
                                            activationTimedOut: false)
        XCTAssertEqual(EditDestination.verdict(target: notes, isRemoteDesktop: false, observed: okField), .insert)
    }

    // MARK: numbers and deleted words

    func testClaudeCanInsertWhenOriginalComposerIsConfirmed() {
        let target = EditTargetIdentity(pid: 3, bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
                                        windowTitle: "Claude", hasWindow: true, hasField: true)
        func observation(field: Bool?, title: Bool? = true, secure: Bool = false) -> EditTargetObservation {
            .init(targetStillRunning: true, frontmostPID: 3, sameWindow: true,
                  sameTitle: title, sameField: field, secureInputActive: secure, activationTimedOut: false)
        }
        XCTAssertEqual(EditDestination.verdict(target: target, isRemoteDesktop: false,
                                               observed: observation(field: true)), .insert)
        XCTAssertEqual(EditDestination.verdict(target: target, isRemoteDesktop: false,
                                               observed: observation(field: false)), .retain(.differentField))
        XCTAssertEqual(EditDestination.verdict(target: target, isRemoteDesktop: false,
                                               observed: observation(field: nil)), .retain(.unknownField))
        XCTAssertEqual(EditDestination.verdict(target: target, isRemoteDesktop: false,
                                               observed: observation(field: true, title: false)), .retain(.differentWindow))
        XCTAssertEqual(EditDestination.verdict(target: target, isRemoteDesktop: false,
                                               observed: observation(field: true, secure: true)), .retain(.secureInput))
    }

    func testNumberChangesAndPureDeletionsAreRejected() {
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "eight", replace: "nine", reason: "x")),
                       .numberChanged)
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "at 5", replace: "at 6", reason: "x")),
                       .numberChanged)
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: " and a lemon", replace: "", reason: "x")),
                       .contentRemoved)
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "very important", replace: "important", reason: "x")),
                       .contentRemoved)
    }

    func testRealRepairsStillPass() {
        for edit in [
            SpanEdit(find: "nine thirty", replace: "9:30", reason: "time"),
            SpanEdit(find: " Kama", replace: ",", reason: "spoken comma"),
            SpanEdit(find: " paired", replace: ".", reason: "spoken period"),
            SpanEdit(find: "should Should", replace: "should", reason: "duplicate"),
            SpanEdit(find: "um ", replace: "", reason: "filler"),
            SpanEdit(find: "Jon", replace: "John", reason: "name"),
            SpanEdit(find: "Tuesday no wait Wednesday", replace: "Wednesday", reason: "self-correction"),
            SpanEdit(find: "five, sorry, six", replace: "six", reason: "self-correction"),
        ] {
            XCTAssertNil(CleanupFaithfulness.rejection(for: edit), "\(edit.find) -> \(edit.replace)")
        }
    }

    // MARK: Closing, composition, scheduled Return, meaning guard, Settings

    /// closing during a take's post-release buffer must leave the edit target in
    /// place, so finalize routes the take to the (closed) session and never to the inserter.
    func testClosingDuringThePostBufferKeepsTheEditTarget() {
        var postBuffer = false
        var hooks = EditSessionController.Hooks(
            setPendingTarget: { [weak self] t in self?.pendingTargets.append(t) },
            startRecording: { [weak self] in self?.recording = true; return true },
            stopRecording: { [weak self] in self?.recording = false },
            abortRecording: { [weak self] in self?.recording = false },
            isInPostBuffer: { postBuffer },
            inserter: { nil },
            isRemoteDesktop: { _ in false },
            onSessionClosed: {},
            saveConfig: { _ in },
            loadConfig: { [weak self] in self?.config ?? Config.defaultConfig },
            noteRecents: {})
        hooks.isRecording = { [weak self] in self?.recording ?? false }
        hooks.presentWindow = false
        hooks.captureFrontmostApp = false
        hooks.cleaner = cleaner
        hooks.clipboard = clipboard
        let c = EditSessionController(hooks: hooks)
        c.handleFnTap()
        c.handleFnTap()                       // stop: the take is now in its post-release buffer
        postBuffer = true
        c.windowController?.onEscape?()       // arms (a take is pending)
        c.windowController?.onEscape?()       // closes
        XCTAssertFalse(c.isOpen)
        XCTAssertNotNil(pendingTargets.last ?? nil,
                        "the target stays set so finalize still routes the take away from the inserter")
    }

    /// typing during composition beats a cleanup that arrived meanwhile.
    func testHandTypingDuringCompositionBeatsAWaitingCleanup() async throws {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOn, cleaner: cleaner,
                                   clipboard: clipboard)
        let wc = EditWindowController(core: core, targetName: nil)
        core.onEvent = { [weak wc] in wc?.handle($0) }
        let a = core.beginTake(); core.takeStopped(a)
        core.takeTranscribed(a, raw: "call jon", pipelineText: "Call Jon")
        await drainMainActor()
        let end = (wc.textView.string as NSString).length
        wc.textView.setSelectedRange(NSRange(location: end, length: 0))
        wc.textView.setMarkedText(" か", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        cleaner.finish(0, .success([SpanEdit(find: "Jon", replace: "John", reason: "name")]))
        await drainMainActor()
        wc.textView.insertText(" 家", replacementRange: wc.textView.markedRange())
        try await Task.sleep(nanoseconds: 600_000_000)
        await drainMainActor()
        XCTAssertEqual(core.segment(a)?.currentText, "Call Jon 家", "his typing wins")
        XCTAssertEqual(wc.textView.string, "Call Jon 家", "the waiting cleanup is not drawn over it")
        XCTAssertEqual(core.segment(a)?.state, .edited)
    }

    /// a Return scheduled for an earlier take does not stop a new take.
    func testNewTakeSupersedesAScheduledReturn() async throws {
        let c = makeController()
        c.handleFnTap()
        c.windowController?.onReturn?()       // Return while recording: stop and wait
        XCTAssertEqual(stops, 1)
        c.deliver(payload(c, "First.")!, kept: false)   // readyToCommit: insert in 0.35 s
        c.handleFnTap()                       // he keeps dictating
        XCTAssertTrue(recording)
        try await Task.sleep(nanoseconds: 600_000_000)
        await drainMainActor()
        XCTAssertTrue(recording, "the new take keeps recording")
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(c.isOpen)
    }

    func testMeaningGuardNumbersDatesAndCommands() {
        XCTAssertNil(CleanupFaithfulness.rejection(for: SpanEdit(find: "twenty five", replace: "25", reason: "x")))
        XCTAssertNil(CleanupFaithfulness.rejection(for: SpanEdit(find: "two hundred fifty", replace: "250", reason: "x")))
        XCTAssertNil(CleanupFaithfulness.rejection(for: SpanEdit(find: " question mark", replace: "?", reason: "x")))
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "rather meet at 3", replace: "rather meet at 4", reason: "x")),
                       .numberChanged, "a marker that stays in the text is not a self-correction")
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "on Thursday", replace: "on Friday", reason: "x")),
                       .dateChanged)
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "open the file", replace: "the file", reason: "x")),
                       .contentRemoved, "a command word is removable only inside its command")
        XCTAssertNil(CleanupFaithfulness.rejection(for: SpanEdit(find: "Thursday no wait Friday", replace: "Friday", reason: "x")))
    }

    /// A fixed title that is not the app's name ("Zoom Workplace") cannot tell chats apart: only
    /// apps known to title the current place may be typed into without a captured field.
    func testFieldlessAppsTypeOnlyWhenTheirTitleNamesThePlace() {
        let ok = EditTargetObservation(targetStillRunning: true, frontmostPID: 9, sameWindow: true,
                                       sameTitle: true, sameField: nil, secureInputActive: false,
                                       activationTimedOut: false)
        let zoom = EditTargetIdentity(pid: 9, bundleID: "us.zoom.xos", appName: "zoom.us",
                                      windowTitle: "Zoom Workplace", hasWindow: true, hasField: false)
        XCTAssertEqual(EditDestination.verdict(target: zoom, isRemoteDesktop: false, observed: ok),
                       .retain(.conversationUnknown))
        let vscode = EditTargetIdentity(pid: 9, bundleID: "com.microsoft.VSCode", appName: "Code",
                                        windowTitle: "notes.md - project", hasWindow: true, hasField: false)
        XCTAssertEqual(EditDestination.verdict(target: vscode, isRemoteDesktop: false, observed: ok), .insert)
    }

    func testMeaningGuardCorrectionsAndOrdinals() {
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "second draft", replace: "first draft", reason: "x")),
                       .numberChanged, "an ordinal appearing is a number change")
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "rather meet at 3", replace: "meet at 4", reason: "x")),
                       .numberChanged, "dropping 'rather' is not a self-correction")
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "at 3 wait at 4", replace: "at 5", reason: "x")),
                       .numberChanged, "a correction may not introduce a number he never said")
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "at 3 wait 4", replace: "at 3", reason: "x")),
                       .numberChanged, "a correction keeps the value after the marker, not the one taken back")
        XCTAssertNil(CleanupFaithfulness.rejection(for: SpanEdit(find: "at 3 wait at 4", replace: "at 4", reason: "x")))
        XCTAssertEqual(CleanupFaithfulness.rejection(for: SpanEdit(find: "new line the new contract", replace: "the contract", reason: "x")),
                       .contentRemoved, "one spoken command covers one set of command words")
        XCTAssertNil(CleanupFaithfulness.rejection(for: SpanEdit(find: "let's meet Tuesday no wait Wednesday",
                                                                  replace: "let's meet Wednesday", reason: "x")))
    }

    func testOpenSettingsWindowTakesTheWindowsEditModeChanges() {
        let vm = SettingsViewModel(config: config)
        XCTAssertTrue(vm.editModeCleanup)
        var changed = config!
        changed.editModeCleanup = FlexBool(false)
        changed.editModeCleanupModel = "opus"
        vm.applyEditModeSettings(from: changed)
        XCTAssertFalse(vm.editModeCleanup)
        XCTAssertEqual(vm.editModeModel, .opus)
        XCTAssertEqual(vm.toConfig().editModeCleanup?.value, false, "its next save keeps cleanup off")
    }

    // MARK: Minors

    func testANewTakeCancelsAWaitingReturn() {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOff, cleaner: cleaner,
                                   clipboard: clipboard)
        let a = core.beginTake()
        XCTAssertEqual(core.returnPressed(), .waitingForTake)
        core.takeStopped(a)
        _ = core.beginTake()                  // he keeps dictating
        XCTAssertFalse(core.pendingCommit)
    }

    func testQueuedExplicitRetryOfAnEditedParagraphStillRuns() async {
        let core = EditSessionCore(persistenceEnabled: false, settings: .cloudOn, cleaner: cleaner,
                                   clipboard: clipboard)
        var ids: [UUID] = []
        for t in ["One.", "Two.", "Three."] {
            let id = core.beginTake(); core.takeStopped(id)
            core.takeTranscribed(id, raw: t, pipelineText: t)
            ids.append(id)
        }
        await drainMainActor()
        cleaner.finish(cleaner.index(for: "One.")!, .success([]))
        await drainMainActor()
        core.applyUserEdits([.edit(ids[0], "One, typed.")])
        // Two slots are busy (Two, Three); the explicit retry of the edited paragraph queues.
        core.retryCleanup(ids[0])
        let before = cleaner.callCount
        cleaner.finish(cleaner.index(for: "Two.")!, .success([]))
        await drainMainActor()
        XCTAssertEqual(cleaner.callCount, before + 1, "the queued explicit retry starts")
        XCTAssertEqual(cleaner.calls.last?.pipelineText, "One, typed.")
    }
}
