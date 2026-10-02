// Claude · 2026-09-24 · Edit Mode V1
import XCTest
@testable import SpeakFreeLib

/// Edit Mode V1 pieces that need no session: the window-to-model reconciler, the destination
/// rules, the meaning guard, change marks, hotkey routing (Hold/Toggle regression), Recents,
/// the latency log, settings resolution and the CLI failure classification.
final class EditModeV1PureTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-pure-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: Hotkey routing: Hold and Toggle unchanged by Edit Mode

    func testHoldAndToggleRoutingIsUnchanged() {
        XCTAssertEqual(HotkeyRouting.keyDown(mode: .hold, isPressed: false, hasEditRouter: true), .startRecording)
        XCTAssertEqual(HotkeyRouting.keyDown(mode: .hold, isPressed: true, hasEditRouter: true), .ignore)
        XCTAssertEqual(HotkeyRouting.keyUp(mode: .hold), .stopRecording)
        XCTAssertEqual(HotkeyRouting.keyDown(mode: .toggle, isPressed: false, hasEditRouter: true), .startRecording)
        XCTAssertEqual(HotkeyRouting.keyDown(mode: .toggle, isPressed: true, hasEditRouter: true), .stopRecording)
        XCTAssertEqual(HotkeyRouting.keyUp(mode: .toggle), .ignore)
        // The installed Edit router never changes Hold or Toggle.
        for pressed in [false, true] {
            XCTAssertEqual(HotkeyRouting.keyDown(mode: .hold, isPressed: pressed, hasEditRouter: true),
                           HotkeyRouting.keyDown(mode: .hold, isPressed: pressed, hasEditRouter: false))
            XCTAssertEqual(HotkeyRouting.keyDown(mode: .toggle, isPressed: pressed, hasEditRouter: true),
                           HotkeyRouting.keyDown(mode: .toggle, isPressed: pressed, hasEditRouter: false))
        }
    }

    func testEditRoutesToTheSessionAndIgnoresKeyUp() {
        XCTAssertEqual(HotkeyRouting.keyDown(mode: .edit, isPressed: false, hasEditRouter: true), .routeToEditSession)
        XCTAssertEqual(HotkeyRouting.keyDown(mode: .edit, isPressed: true, hasEditRouter: true), .routeToEditSession)
        XCTAssertEqual(HotkeyRouting.keyUp(mode: .edit), .ignore)
    }

    func testDefaultConfigIsStillHold() {
        XCTAssertEqual(Config.defaultConfig.effectiveKeyMode, .hold)
        XCTAssertEqual(FinalizeDestination.resolve(editTarget: nil), .insertImmediately)
    }

    // MARK: Reconciler

    func testSameShapeTypingMapsByPosition() {
        let a = UUID(), b = UUID()
        let ops = EditDocumentReconciler.reconcile(
            paragraphs: [.init(text: "One!", ownerIDs: [a]), .init(text: "Two.", ownerIDs: [b])],
            displayed: [(a, "One."), (b, "Two.")])
        XCTAssertEqual(ops, [.edit(a, "One!")])
    }

    func testEmptiedParagraphMapsByPosition() {
        let a = UUID(), b = UUID()
        let ops = EditDocumentReconciler.reconcile(
            paragraphs: [.init(text: "One.", ownerIDs: [a]), .init(text: "", ownerIDs: [])],
            displayed: [(a, "One."), (b, "Two.")])
        XCTAssertEqual(ops, [.edit(b, "")])
    }

    func testBackspaceAcrossBoundaryMerges() {
        let a = UUID(), b = UUID(), c = UUID()
        let ops = EditDocumentReconciler.reconcile(
            paragraphs: [.init(text: "One.Two.", ownerIDs: [a, b]), .init(text: "Three.", ownerIDs: [c])],
            displayed: [(a, "One."), (b, "Two."), (c, "Three.")])
        XCTAssertEqual(ops, [.merge(owner: a, absorbed: [b], text: "One.Two.")])
    }

    func testDeletingAWholeParagraphRemovesIt() {
        let a = UUID(), b = UUID()
        let ops = EditDocumentReconciler.reconcile(
            paragraphs: [.init(text: "One.", ownerIDs: [a])],
            displayed: [(a, "One."), (b, "Two.")])
        XCTAssertEqual(ops, [.remove(b)])
    }

    func testTypingIntoAnEmptyWindowMakesATypedParagraph() {
        let fixed = UUID()
        let ops = EditDocumentReconciler.reconcile(
            paragraphs: [.init(text: "Hello", ownerIDs: [])], displayed: [], makeID: { fixed })
        XCTAssertEqual(ops, [.addTyped(fixed, "Hello")])
    }

    func testLineBreakAndCopyShape() {
        XCTAssertEqual(EditDocumentReconciler.displayText("a\nb"), "a\u{2028}b")
        XCTAssertEqual(EditDocumentReconciler.modelText("a\u{2028}b"), "a\nb")
        XCTAssertEqual(EditDocumentReconciler.exportText("One.\nTwo\u{2028}three"), "One.\n\nTwo\nthree",
                       "a paragraph boundary copies as a blank line; a line break stays one line")
    }

    // MARK: Destination

    private let slack = EditTargetIdentity(pid: 42, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                                           windowTitle: "general (Team) - Slack", hasWindow: true, hasField: false)
    private let textEdit = EditTargetIdentity(pid: 7, bundleID: "com.apple.TextEdit", appName: "TextEdit",
                                              windowTitle: "Notes.txt", hasWindow: true, hasField: true)

    private func observed(pid: Int32? = 42, running: Bool = true, window: Bool? = true, title: Bool? = true,
                          field: Bool? = true, secure: Bool = false, timedOut: Bool = false) -> EditTargetObservation {
        EditTargetObservation(targetStillRunning: running, frontmostPID: pid, sameWindow: window,
                              sameTitle: title, sameField: field, secureInputActive: secure,
                              activationTimedOut: timedOut)
    }

    func testSamePlaceInserts() {
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(field: nil)), .insert)
        XCTAssertEqual(EditDestination.verdict(target: textEdit, isRemoteDesktop: false, observed: observed(pid: 7)), .insert)
    }

    func testSameAppDifferentConversationRetains() {
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(title: false)),
                       .retain(.differentWindow), "switching Slack channel changes the title")
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(window: false)),
                       .retain(.differentWindow))
        XCTAssertEqual(EditDestination.verdict(target: textEdit, isRemoteDesktop: false, observed: observed(pid: 7, field: false)),
                       .retain(.differentField))
    }

    func testEveryUncertaintyRetains() {
        XCTAssertEqual(EditDestination.verdict(target: nil, isRemoteDesktop: false, observed: observed()), .retain(.noTarget))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(pid: 99)), .retain(.differentApp))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(running: false)), .retain(.targetQuit))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(timedOut: true)), .retain(.activationTimedOut))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(window: nil)), .retain(.unknownField))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(title: nil)), .retain(.unknownField))
        XCTAssertEqual(EditDestination.verdict(target: textEdit, isRemoteDesktop: false, observed: observed(pid: 7, field: nil)), .retain(.unknownField))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: false, observed: observed(secure: true)), .retain(.secureInput))
        XCTAssertEqual(EditDestination.verdict(target: slack, isRemoteDesktop: true, observed: observed()), .retain(.remoteDesktop))
        let noWindow = EditTargetIdentity(pid: 42, bundleID: "x", appName: "X", windowTitle: nil, hasWindow: false, hasField: false)
        XCTAssertEqual(EditDestination.precheck(noWindow, isRemoteDesktop: false), .retain(.unknownField))
    }

    func testTerminalIsCopyOnly() {
        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            let t = EditTargetIdentity(pid: 5, bundleID: bundle, appName: "T", windowTitle: "zsh", hasWindow: true, hasField: true)
            XCTAssertEqual(EditDestination.verdict(target: t, isRemoteDesktop: false, observed: observed(pid: 5)), .retain(.terminal))
        }
    }

    // MARK: Meaning guard

    func testNegationChangesAreRejected() {
        let s = CleanupFaithfulness.screen([
            SpanEdit(find: "do not approve", replace: "approve", reason: "x"),
            SpanEdit(find: "is ready", replace: "isn't ready", reason: "x"),
            SpanEdit(find: "never", replace: "ever", reason: "x"),
            SpanEdit(find: "teh", replace: "the", reason: "typo"),
        ])
        XCTAssertEqual(s.kept.map(\.find), ["teh"])
        XCTAssertEqual(s.rejected.count, 3)
    }

    func testSelfCorrectionNoIsNotANegation() {
        let s = CleanupFaithfulness.screen([
            SpanEdit(find: "Tuesday no wait Wednesday", replace: "Wednesday", reason: "self-correction"),
            SpanEdit(find: "five, sorry no, six", replace: "six", reason: "self-correction"),
        ])
        XCTAssertEqual(s.kept.count, 2)
    }

    // MARK: Change marks

    func testChangeMarksLandOnTheNewText() {
        let edits = [SpanEdit(find: "Jon", replace: "John", reason: "name"),
                     SpanEdit(find: " Kama", replace: ",", reason: "comma")]
        let marks = EditChangeMarks.ranges(parentText: "Tell Jon Kama now", edits: edits)
        let new = "Tell John, now" as NSString
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(new.substring(with: marks[0].range), "John")
        XCTAssertEqual(new.substring(with: marks[1].range), ",")
    }

    func testDeletionMarkIsZeroLengthAtTheRightPlace() {
        let marks = EditChangeMarks.ranges(parentText: "Ship um it", edits: [SpanEdit(find: "um ", replace: "", reason: "filler")])
        XCTAssertEqual(marks.first?.range, NSRange(location: 5, length: 0))
    }

    // MARK: Model additions

    func testRestoreMarksTheParagraphAsHisSoNoCleanupLands() {
        let seg = UUID()
        var s = EditSessionState(createdAt: Date(), updatedAt: Date())
        s = EditSessionReducer.reduce(s, .beginSegment(segmentID: seg)).state
        s = EditSessionReducer.reduce(s, .provisional(segmentID: seg, raw: "r", pipelineText: "text")).state
        s = EditSessionReducer.reduce(s, .restoreOriginal(segmentID: seg)).state
        XCTAssertEqual(s.segments[0].state, .edited)
        let auto = EditSessionReducer.reduce(s, .startCleaning(segmentID: seg, attemptID: UUID(), arm: "sonnet"))
        XCTAssertEqual(auto.outcome, .dropped(.invalidState), "automatic cleanup never touches it")
        let retry = EditSessionReducer.reduce(s, .retryCleaning(segmentID: seg, attemptID: UUID(), arm: "sonnet"))
        XCTAssertEqual(retry.outcome, .applied, "an explicit retry still can")
    }

    func testOldDraftWithoutNewFieldsStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","state":"provisional","raw":"r","revisions":[]}
        """
        let seg = try JSONDecoder().decode(EditSegment.self, from: Data(json.utf8))
        XCTAssertNil(seg.absorbed)
        XCTAssertNil(seg.componentStems)
    }

    // MARK: Settings

    func testEditSettingsDefaults() {
        let s = EditModeSettings.from(Config.defaultConfig)
        XCTAssertTrue(s.cleanupEnabled)
        XCTAssertFalse(s.consentGiven, "no consent recorded means nothing is sent")
        XCTAssertFalse(s.sendsToCloud)
        XCTAssertEqual(s.model, .sonnet)
        XCTAssertEqual(s.animation, .settle)
        XCTAssertEqual(CleanupService.Model.resolve("OPUS"), .opus)
        XCTAssertEqual(CleanupService.Model.resolve("gpt"), .sonnet)
        XCTAssertEqual(EditAnimationStyle.resolve("quiet"), .quiet)
    }

    func testViewModelRoundTripsEditSettingsWithoutTouchingUntouchedKeys() throws {
        var c = Config.defaultConfig
        try c.save()
        let vm = SettingsViewModel(config: c)
        XCTAssertNil(vm.toConfig().editModeCleanup, "never written until changed")
        vm.keyMode = .edit
        vm.editModeCleanup = false
        vm.editModeModel = .opus
        vm.editModeCloudConsent = "2026-09-24T12:00:00Z"
        let out = vm.toConfig()
        XCTAssertEqual(out.keyMode, .edit)
        XCTAssertEqual(out.editModeCleanup?.value, false)
        XCTAssertEqual(out.editModeCleanupModel, "opus")
        XCTAssertEqual(out.editModeCloudConsent, "2026-09-24T12:00:00Z")
        c = out
        let settings = EditModeSettings.from(c)
        XCTAssertFalse(settings.sendsToCloud, "unchecked cleanup sends nothing even with consent")
    }

    // MARK: Recents

    private func artifact(_ text: String, stems: [[String]], at date: Date) -> EditSessionArtifact {
        let paras = text.components(separatedBy: "\n\n")
        return EditSessionArtifact(
            sessionID: UUID(), committedAt: date, text: text,
            paragraphs: zip(paras, stems).map { EditSessionArtifact.Paragraph(text: $0, original: nil, componentStems: $1, revisions: []) },
            targetApp: nil)
    }

    func testSessionFileRoundTripsAndIsARecordingArtifact() throws {
        let a = artifact("One.\n\nTwo.", stems: [["recording-2026-09-24-100000-aaaa"], []], at: Date())
        let url = try XCTUnwrap(EditRecents.write(a))
        XCTAssertTrue(url.path.hasPrefix(scratch.path), "written under the test config dir only")
        XCTAssertTrue(RecordingStore.isRecordingArtifact(url.lastPathComponent), "Delete All and Clear cover it")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let listed = EditRecents.list(limit: 15)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].text, "One.\n\nTwo.")
        XCTAssertEqual(listed[0].components.map(\.text), ["One.", "Two."])
    }

    func testMenuShowsParentThenComponentsAndDoesNotRepeatComponents() {
        let now = Date()
        let session = EditRecentSession(url: scratch.appendingPathComponent("s.edit.json"), date: now,
                                        artifact: artifact("Alpha.\n\nBeta.", stems: [["recording-a"], ["recording-b"]], at: now))
        let recordings = [
            Recording(url: scratch.appendingPathComponent("recording-a.wav"), date: now.addingTimeInterval(-20), text: "Alpha."),
            Recording(url: scratch.appendingPathComponent("recording-b.wav"), date: now.addingTimeInterval(-10), text: "Beta."),
            Recording(url: scratch.appendingPathComponent("recording-c.wav"), date: now.addingTimeInterval(-60), text: "Other."),
        ]
        let items = EditRecents.merge(recordings: recordings, sessions: [session])
        XCTAssertEqual(items.count, 2)
        guard case .session(let s) = items[0] else { return XCTFail("the Edit session comes first") }
        XCTAssertEqual(EditRecents.parentTitle(s), "Edit · 2 paragraphs · Alpha. Beta.")
        XCTAssertEqual(s.components.map(EditRecents.componentTitle), ["⤷ Alpha.", "⤷ Beta."])
        XCTAssertEqual(items[1], .recording(recordings[2].url))
    }

    func testPruneDropsSessionsWhoseRecordingsAreGone() throws {
        let gone = artifact("Gone.", stems: [["recording-2026-01-01-000000-dead"]], at: Date(timeIntervalSinceNow: -100))
        let typed = artifact("Typed.", stems: [[]], at: Date())
        let goneURL = try XCTUnwrap(EditRecents.write(gone))
        let typedURL = try XCTUnwrap(EditRecents.write(typed))
        EditRecents.prune(maxCount: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: goneURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: typedURL.path))
    }

    // MARK: Latency log

    func testLatencyLogHoldsNumbersNeverText() throws {
        let log = EditLatencyLog()
        log.record(.init(event: "cleanup", model: "sonnet", ms: 6400, chars: 120, applied: 2, rejected: 0, outcome: "ok"))
        log.flush()
        XCTAssertTrue(log.fileURL.path.hasPrefix(scratch.path))
        let body = try String(contentsOf: log.fileURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(body.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(Set(obj?.keys.map { $0 } ?? []),
                       ["event", "model", "ms", "chars", "applied", "rejected", "outcome", "at"])
        for key in ["text", "raw", "prompt"] { XCTAssertNil(obj?[key]) }
        let attrs = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: CLI failures are named

    func testCLIMessagesAreClassified() {
        XCTAssertEqual(CleanupService.CleanupError.classifyFailure(stdout: "Not logged in · Please run /login"), .notLoggedIn)
        XCTAssertEqual(CleanupService.CleanupError.classifyFailure(stdout: "You've hit your weekly limit · resets Sep 30"),
                       .usageLimit("You've hit your weekly limit · resets Sep 30"))
        XCTAssertEqual(CleanupService.CleanupError.classifyFailure(stdout: "boom"), .cliError("boom"))
        XCTAssertTrue(CleanupService.CleanupError.notLoggedIn.isSessionWide)
        XCTAssertFalse(CleanupService.CleanupError.timedOut.isSessionWide)
    }

    func testPromptCarriesSelfCorrectionAndMeaningLines() {
        let prompt = CleanupService.buildPrompt(raw: "r", pipelineText: "p")
        XCTAssertTrue(prompt.contains("corrected themselves"))
        XCTAssertTrue(prompt.contains("NEVER change the meaning"))
    }
}
