// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Report a Problem: the try-another-method flow, "This works" and its follow-up suggestion,
// the report's privacy contract (no dictated text), and the prefilled GitHub issue link. No
// window, keystroke, clipboard or real config is touched: side effects are injected closures
// and config writes go to a scratch folder.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class AppProblemReportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree.problem.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        Config.configDirOverride = tempDir.appendingPathComponent("config")
        AppCompatibility.resetCache()
    }

    override func tearDown() {
        Config.configDirOverride = nil
        AppCompatibility.resetCache()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func target(_ appClass: AppClass, id: String = "com.example.app", name: String = "Example",
                        version: String? = "2.1") -> ProblemTarget {
        ProblemTarget(bundleID: id, appName: name, appVersion: version,
                      classification: AppClassification(appClass: appClass, reason: "test reason"))
    }

    private final class Effects {
        var applied: [InsertionMethod] = []
        var confirmations: [InsertionConfirmation] = []
    }

    private func model(_ appClass: AppClass, setting: InsertionMethod = .automatic,
                       name: String = "Example") -> (AppProblemModel, Effects) {
        let effects = Effects()
        let model = AppProblemModel(
            session: ProblemSession(target: target(appClass, name: name), setting: setting),
            speakfreeVersion: "9.9.9", macOSVersion: "Test 1",
            applySetting: { effects.applied.append($0) },
            recordConfirmation: { effects.confirmations.append($0) },
            now: { Date(timeIntervalSince1970: 1_790_000_000) })
        return (model, effects)
    }

    // MARK: - Preference order

    func test_preferenceOrderPutsSpeakfreesChoiceFirstAndSkipsImpossibleMethods() {
        XCTAssertEqual(ProblemSession(target: target(.native), setting: .automatic).preferenceOrder,
                       [.accessibility, .paste, .type])
        XCTAssertEqual(ProblemSession(target: target(.webRuntime), setting: .automatic).preferenceOrder,
                       [.paste, .accessibility, .type])
        XCTAssertEqual(ProblemSession(target: target(.terminal), setting: .automatic).preferenceOrder,
                       [.paste, .type])
        XCTAssertEqual(ProblemSession(target: target(.remoteDesktop), setting: .automatic).preferenceOrder,
                       [.type, .paste])
    }

    // MARK: - The "this works" flow

    /// A native app where Accessibility drops text: switch to Paste, it works, speakfree asks
    /// for one more try of Accessibility, that fails, and it goes back to Paste.
    func test_lessPreferredMethodWorksThenPreferredIsRetriedAndReverted() throws {
        let (model, effects) = model(.native)
        model.choose(.paste)
        XCTAssertEqual(effects.applied, [.paste], "a pick is saved right away")

        model.thisWorks()
        let confirmation = try XCTUnwrap(effects.confirmations.last)
        XCTAssertEqual(confirmation.method, "paste")
        XCTAssertEqual(confirmation.setting, "paste")
        XCTAssertEqual(confirmation.appVersion, "2.1")
        XCTAssertEqual(model.suggestion, .tryPreferred(.accessibility))
        XCTAssertNotNil(model.suggestionText)

        model.acceptSuggestion()
        XCTAssertEqual(effects.applied.last, .automatic,
                       "the preferred method is speakfree's own choice, so the setting goes back to Automatic")
        XCTAssertNil(model.suggestion)

        model.didNotWork()
        XCTAssertEqual(model.suggestion, .revert(to: .paste))
        model.acceptSuggestion()
        XCTAssertEqual(effects.applied.last, .paste)
        XCTAssertEqual(model.session.trials, [ProblemTrial(method: .paste, worked: true),
                                              ProblemTrial(method: .accessibility, worked: false)])
    }

    func test_preferredMethodWorkingOnRetryEndsTheFlow() {
        let (model, effects) = model(.terminal, setting: .type)
        model.thisWorks()
        XCTAssertEqual(model.suggestion, .tryPreferred(.paste))
        model.acceptSuggestion()
        XCTAssertEqual(effects.applied, [.automatic])
        model.thisWorks()
        XCTAssertNil(model.suggestion, "nothing better left to try")
        XCTAssertEqual(effects.confirmations.map(\.method), ["type", "paste"])
        XCTAssertEqual(effects.confirmations.last?.setting, "automatic")
    }

    func test_automaticWorkingAsksNothingMore() {
        let (model, effects) = model(.webRuntime)
        model.thisWorks()
        XCTAssertNil(model.suggestion)
        XCTAssertEqual(effects.confirmations.first?.method, "paste")
        XCTAssertEqual(effects.confirmations.first?.setting, "automatic")
        XCTAssertEqual(model.savedMessage, "Saved on this Mac: Paste works in Example.")
    }

    func test_failuresWalkThePreferenceOrderThenSayExhausted() {
        let (model, effects) = model(.remoteDesktop)
        model.didNotWork()
        XCTAssertEqual(model.suggestion, .tryNext(.paste))
        model.acceptSuggestion()
        XCTAssertEqual(effects.applied, [.paste])
        model.didNotWork()
        XCTAssertEqual(model.suggestion, .exhausted)
        XCTAssertNil(model.suggestionButton)
        XCTAssertTrue(effects.confirmations.isEmpty)
    }

    /// Review round 1: following "try the preferred method" and then closing the window without
    /// a verdict must not leave the app on the untested method.
    func test_closingMidSuggestionRestoresTheConfirmedMethod() {
        let (model, effects) = model(.native)
        model.choose(.paste)
        model.thisWorks()
        model.acceptSuggestion()
        XCTAssertEqual(effects.applied, [.paste, .automatic])
        model.finish()
        XCTAssertEqual(effects.applied.last, .paste)
        XCTAssertEqual(model.session.selected, .paste)
    }

    func test_closingKeepsAConfirmedOrUnprovenChoiceAlone() {
        let (confirmed, e1) = model(.native)
        confirmed.choose(.type)
        confirmed.thisWorks()
        confirmed.finish()
        XCTAssertEqual(e1.applied, [.type], "the current method worked: nothing to restore")

        let (untested, e2) = model(.native)
        untested.choose(.type)
        untested.finish()
        XCTAssertEqual(e2.applied, [.type], "nothing was confirmed: the person's pick stands")
    }

    /// Review round 2: a method the person picks from the picker after confirming another stays
    /// picked when the window closes; only a suggested trial is undone.
    func test_closingKeepsADeliberatePickAfterAConfirmation() {
        let (model, effects) = model(.native)
        model.choose(.paste)
        model.thisWorks()
        model.choose(.type)
        model.finish()
        XCTAssertEqual(effects.applied, [.paste, .type])
        XCTAssertEqual(model.session.selected, .type)
    }

    /// Review round 3: going back to a method that worked re-saves its record, because the
    /// preferred method's own "works" had replaced it before it failed.
    func test_revertingReSavesTheWorkingMethodsRecord() {
        let (model, effects) = model(.native)
        model.choose(.paste)
        model.thisWorks()                 // paste recorded
        model.acceptSuggestion()          // try accessibility (automatic)
        model.thisWorks()                 // accessibility recorded, replacing paste
        model.didNotWork()                // accessibility fails after all
        XCTAssertEqual(model.suggestion, .revert(to: .paste))
        model.acceptSuggestion()
        XCTAssertEqual(effects.confirmations.map(\.method), ["paste", "accessibility", "paste"])
        XCTAssertEqual(effects.applied.last, .paste)
    }

    func test_closingAfterATrialReSavesTheRestoredRecord() {
        let (model, effects) = model(.native)
        model.choose(.paste)
        model.thisWorks()
        model.acceptSuggestion()
        model.finish()
        XCTAssertEqual(effects.confirmations.map(\.method), ["paste", "paste"])
    }

    /// Review round 3: choosing the already-selected trial method yourself makes it yours.
    func test_choosingTheTrialMethodYourselfKeepsItOnClose() {
        let (model, effects) = model(.native)
        model.choose(.paste)
        model.thisWorks()
        model.acceptSuggestion()
        XCTAssertTrue(model.session.selectionIsSuggestedTrial)
        model.choose(.automatic)
        XCTAssertFalse(model.session.selectionIsSuggestedTrial)
        model.finish()
        XCTAssertEqual(effects.applied, [.paste, .automatic], "no restore, no extra write")
    }

    func test_previewSaysWhenTheLinkIsTrimmed() {
        let (model, _) = model(.native)
        XCTAssertFalse(model.linkIsTrimmed)
        model.note = String(repeating: "long note line\n", count: 800)
        XCTAssertTrue(model.linkIsTrimmed)
    }

    func test_finishIsIdempotent() {
        let (model, effects) = model(.native)
        model.choose(.paste)
        model.thisWorks()
        model.acceptSuggestion()
        model.finish()
        model.finish()
        XCTAssertEqual(effects.applied, [.paste, .automatic, .paste])
    }

    /// Review round 2: "Didn't Work" withdraws a saved "works" record for the same method.
    func test_didNotWorkForgetsTheSameMethodsConfirmation() {
        var forgotten: [InsertionMethod] = []
        let model = AppProblemModel(
            session: ProblemSession(target: target(.webRuntime), setting: .automatic),
            speakfreeVersion: "1", macOSVersion: "1", applySetting: { _ in }, recordConfirmation: { _ in },
            forgetConfirmation: { forgotten.append($0) })
        model.thisWorks()
        model.didNotWork()
        XCTAssertEqual(forgotten, [.paste], "the concrete method, not Automatic")
    }

    func test_removeConfirmationOnlyWhenTheMethodMatches() {
        var config = Config.defaultConfig
        config.recordInsertionConfirmation(
            InsertionConfirmation(method: .paste, setting: .paste, appVersion: nil, date: Date()), for: "com.A")
        XCTAssertFalse(config.removeInsertionConfirmation(for: "com.a", ifMethod: .type))
        XCTAssertNotNil(config.insertionConfirmations?["com.a"])
        XCTAssertTrue(config.removeInsertionConfirmation(for: "COM.A", ifMethod: .paste))
        XCTAssertNil(config.insertionConfirmations)
    }

    func test_retryResultsAreShownInPlainWords() {
        let (model, _) = model(.native)
        model.retryFinished(.skippedBusy)
        XCTAssertEqual(model.retryMessage, "Retry skipped: a dictation was in progress.")
        model.retryFinished(.appNotInFront)
        XCTAssertEqual(model.retryMessage, "Retry skipped: Example did not come to the front.")
        model.retryStarted()
        XCTAssertNil(model.retryMessage)
        model.retryFinished(.inserted)
        XCTAssertNil(model.retryMessage)
    }

    /// Review round 1: a method's latest verdict is what counts.
    func test_aMethodThatFailedThenWorkedCountsAsWorking() {
        let (model, _) = model(.native)
        model.choose(.paste)
        model.didNotWork()
        model.thisWorks()
        model.choose(.type)
        model.didNotWork()
        XCTAssertEqual(model.suggestion, .revert(to: .paste))
    }

    func test_retryGate() {
        XCTAssertTrue(AppDelegate.retryAllowed(hasText: true, isPressed: false, postBufferActive: false,
                                               editSessionOpen: false, busy: false, retryInFlight: false))
        XCTAssertFalse(AppDelegate.retryAllowed(hasText: false, isPressed: false, postBufferActive: false,
                                                editSessionOpen: false, busy: false, retryInFlight: false))
        XCTAssertFalse(AppDelegate.retryAllowed(hasText: true, isPressed: true, postBufferActive: false,
                                                editSessionOpen: false, busy: false, retryInFlight: false))
        XCTAssertFalse(AppDelegate.retryAllowed(hasText: true, isPressed: false, postBufferActive: true,
                                                editSessionOpen: false, busy: false, retryInFlight: false))
        XCTAssertFalse(AppDelegate.retryAllowed(hasText: true, isPressed: false, postBufferActive: false,
                                                editSessionOpen: true, busy: false, retryInFlight: false))
        XCTAssertFalse(AppDelegate.retryAllowed(hasText: true, isPressed: false, postBufferActive: false,
                                                editSessionOpen: false, busy: true, retryInFlight: false),
                       "not while recording or transcribing")
        XCTAssertFalse(AppDelegate.retryAllowed(hasText: true, isPressed: false, postBufferActive: false,
                                                editSessionOpen: false, busy: false, retryInFlight: true),
                       "a second click while the first is pending does nothing")
    }

    func test_canRetryFollowsTheInjectedGate() {
        var available = false
        let model = AppProblemModel(
            session: ProblemSession(target: target(.native), setting: .automatic),
            speakfreeVersion: "1", macOSVersion: "1", applySetting: { _ in }, recordConfirmation: { _ in },
            retryAvailable: { available })
        XCTAssertFalse(model.canRetry)
        available = true
        model.observe(CompatibilityEvent(date: Date(), bundleID: "com.other", appName: nil, appVersion: nil,
                                         appClass: .native, reason: "r", override: .automatic,
                                         outcome: .typed, multiLine: false))
        XCTAssertTrue(model.canRetry, "any new dictation makes a retry possible")
    }

    func test_choosingTheSameSettingDoesNothing() {
        let (model, effects) = model(.native, setting: .paste)
        model.choose(.paste)
        XCTAssertTrue(effects.applied.isEmpty)
    }

    func test_outcomesFromOtherAppsAreIgnored() {
        let (model, _) = model(.native)
        let other = CompatibilityEvent(date: Date(), bundleID: "com.other", appName: nil, appVersion: nil,
                                       appClass: .native, reason: "r", override: .automatic,
                                       outcome: .typed, multiLine: false)
        model.observe(other)
        XCTAssertNil(model.session.lastOutcome)
        let mine = CompatibilityEvent(date: Date(), bundleID: "COM.EXAMPLE.APP", appName: nil, appVersion: nil,
                                      appClass: .native, reason: "r", override: .automatic,
                                      outcome: .axDroppedThenPasted, multiLine: false)
        model.observe(mine)
        XCTAssertEqual(model.session.lastOutcome, .axDroppedThenPasted)
        model.choose(.type)
        XCTAssertNil(model.session.lastOutcome, "a new method starts a fresh result")
    }

    // MARK: - Privacy: the report never holds dictated text

    /// The window listens to insertions while it is open. Drive a real insertion (all output
    /// seams injected) with a distinctive text and check the report body never contains it,
    /// even with the stored compatibility report switched off.
    func test_reportBuiltFromARealInsertionContainsNoText() {
        let report = CompatibilityReport()
        XCTAssertFalse(report.isEnabled)
        let (model, _) = model(.terminal)
        let secret = "zebra quartz 90210 secret"
        report.listener = { model.observe($0) }

        let inserter = TextInserter()
        inserter.frontmostBundleIDProvider = { "com.example.app" }
        inserter.frontmostBundleURLProvider = { nil }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.compatibilityReport = report
        var pasted: [String] = []
        inserter.performPaste = { pasted.append($0) }
        inserter.performUnicodeInsertion = { _ in true }
        inserter.insertionOverrides = ["com.example.app": .paste]
        inserter.pasteboard = NSPasteboard(name: .init("speakfree.test.problem.\(UUID().uuidString)"))
        addTeardownBlock { inserter.pasteboard.releaseGlobally() }
        inserter.insert(text: secret)

        XCTAssertEqual(pasted, [secret])
        XCTAssertEqual(model.session.lastOutcome, .pasted)
        XCTAssertTrue(report.snapshot.isEmpty, "the stored report stays off; the listener keeps nothing")

        model.thisWorks()
        let body = model.reportBody
        for word in ["zebra", "quartz", "90210", "secret"] {
            XCTAssertFalse(body.contains(word), "report must never contain dictated text: \(word)")
        }
        let url = model.issueURL?.absoluteString ?? ""
        XCTAssertFalse(url.contains("zebra"))
        XCTAssertTrue(body.contains("com.example.app"))
        XCTAssertTrue(body.contains("Detected as: Terminal (test reason)"))
        XCTAssertTrue(body.contains("- Paste: works"))
        XCTAssertTrue(body.contains("Last result speakfree saw in this app: pasted"))
        XCTAssertTrue(body.contains("speakfree 9.9.9"))
        XCTAssertTrue(body.contains("No dictated text is included"))
    }

    func test_noteAppearsOnlyWhenTyped() {
        let (model, _) = model(.native)
        XCTAssertFalse(model.reportBody.contains("What goes wrong"))
        model.note = "  Text vanishes after the first word.  "
        XCTAssertTrue(model.reportBody.hasSuffix("**What goes wrong**\n\nText vanishes after the first word."))
        XCTAssertTrue(model.reportBody.hasPrefix("**App**"))
    }

    // MARK: - Issue link

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func test_issueURLEncodesEverythingThatCouldChangeItsMeaning() throws {
        let title = "App compatibility: A+B & C #1 = 100% (com.example.app)"
        let body = "line one\nline two & more\n+plus #hash =eq %pct ü 🎤 \"quoted\"?"
        let url = try XCTUnwrap(ProblemSession.issueURL(title: title, body: body))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/definitelyreal/speakfree/issues/new?title="))
        XCTAssertEqual(queryValue(url, "title"), title)
        XCTAssertEqual(queryValue(url, "body"), body)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 2,
                       "an & in the text must not create extra parameters")
        XCTAssertFalse(url.absoluteString.contains("+"), "+ would read as a space")
        XCTAssertNil(url.fragment, "# must not start a fragment")
    }

    func test_longReportIsTrimmedAtALineToFitTheLinkLimit() throws {
        let (model, _) = model(.native, name: "Long")
        model.note = (1...600).map { "Line \($0) of a long note about what happens." }.joined(separator: "\n")
        let url = try XCTUnwrap(model.issueURL)
        XCTAssertLessThanOrEqual(url.absoluteString.count, ProblemSession.maxIssueURLLength)
        let body = try XCTUnwrap(queryValue(url, "body"))
        XCTAssertTrue(body.hasSuffix(ProblemSession.trimmedNotice), "says it was trimmed")
        XCTAssertTrue(body.hasPrefix("**App**"))
        XCTAssertTrue(body.contains("- Bundle ID: com.example.app"), "app details survive the trim")
        XCTAssertTrue(body.contains("speakfree 9.9.9"))
        XCTAssertEqual(queryValue(url, "title"), model.session.issueTitle, "title always kept")
        // Cut at a line boundary: every kept note line is whole.
        let kept = body.replacingOccurrences(of: ProblemSession.trimmedNotice, with: "")
            .components(separatedBy: "\n").filter { $0.hasPrefix("Line ") }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(kept.allSatisfy { $0.hasSuffix("happens.") })
    }

    func test_shortReportIsNotTrimmed() throws {
        let (model, _) = model(.native)
        let url = try XCTUnwrap(model.issueURL)
        XCTAssertEqual(queryValue(url, "body"), model.reportBody)
    }

    func test_hugeSingleLineStillProducesAValidShortLink() throws {
        let url = try XCTUnwrap(ProblemSession.issueURL(title: "T", body: String(repeating: "é", count: 20_000)))
        XCTAssertLessThanOrEqual(url.absoluteString.count, ProblemSession.maxIssueURLLength)
        XCTAssertEqual(queryValue(url, "title"), "T")
    }

    func test_veryLongAppNameKeepsTheTitleShort() {
        let session = ProblemSession(target: target(.native, name: String(repeating: "N", count: 500)),
                                     setting: .automatic)
        XCTAssertLessThanOrEqual(session.issueTitle.count, 160)
    }

    // MARK: - Config (scratch folder only)

    func test_confirmationsRoundTripAndReplacePerApp() throws {
        var config = Config.defaultConfig
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        config.recordInsertionConfirmation(
            InsertionConfirmation(method: .paste, setting: .paste, appVersion: "1", date: date), for: "com.Example.App")
        config.recordInsertionConfirmation(
            InsertionConfirmation(method: .type, setting: .type, appVersion: "2", date: date), for: "com.example.app")
        try config.save()
        XCTAssertTrue(Config.configFile.path.hasPrefix(tempDir.path))
        let loaded = Config.load()
        XCTAssertEqual(loaded.insertionConfirmations?.values.count, 1, "one entry per app, any letter case")
        XCTAssertEqual(loaded.insertionConfirmations?["COM.EXAMPLE.APP"]?.method, "type")
        XCTAssertEqual(loaded.insertionConfirmations?["com.example.app"]?.confirmedAt, "2026-09-21T14:13:20Z")
        XCTAssertEqual(SettingsViewModel().insertionConfirmations["com.example.app"]?.method, "type")
    }

    func test_malformedConfirmationsNeverBreakTheConfig() throws {
        let json = """
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base","language":"en",
         "insertionOverrides":{"com.a":"paste"},
         "insertionConfirmations":{"com.good":{"method":"paste","setting":"automatic","confirmedAt":"x"},
                                   "com.bad":"nonsense", "com.worse":{"method":3}}}
        """
        let config = try Config.decode(from: Data(json.utf8))
        XCTAssertEqual(config.insertionConfirmations?.values.keys.sorted(), ["com.good"])
        XCTAssertEqual(config.effectiveInsertionOverrides, ["com.a": .paste])
        let wrongShape = try Config.decode(from: Data("""
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base","language":"en","insertionConfirmations":[1,2]}
        """.utf8))
        XCTAssertEqual(wrongShape.insertionConfirmations?.values, [:])
    }

    func test_configSetInsertionOverrideMatchesTheSettingsRules() throws {
        let json = """
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base","language":"en",
         "insertionOverrides":{"com.future":"telepathy","com.A":"paste"}}
        """
        var config = try Config.decode(from: Data(json.utf8))
        config.setInsertionOverride(.type, for: "com.a")
        XCTAssertEqual(config.effectiveInsertionOverrides, ["com.a": .type], "replaces regardless of case")
        XCTAssertEqual(config.insertionOverrides?.unknown, ["com.future": "telepathy"], "newer builds' entries kept")
        config.setInsertionOverride(.automatic, for: "COM.A")
        XCTAssertEqual(config.effectiveInsertionOverrides, [:])
        config.setInsertionOverride(.paste, for: "com.future")
        XCTAssertEqual(config.effectiveInsertionOverrides, ["com.future": .paste])
        XCTAssertNil(config.insertionOverrides?.unknown["com.future"])
        config.setInsertionOverride(.paste, for: "   ")
        XCTAssertEqual(config.effectiveInsertionOverrides, ["com.future": .paste], "blank IDs are ignored")
    }

    // MARK: - Listener plumbing

    func test_listenerSeesEventsWhileTheStoredReportStaysEmpty() {
        let report = CompatibilityReport()
        XCTAssertFalse(report.wantsEvents)
        var seen = 0
        report.listener = { _ in seen += 1 }
        XCTAssertTrue(report.wantsEvents)
        let event = CompatibilityEvent(date: Date(), bundleID: "a", appName: nil, appVersion: nil,
                                       appClass: .native, reason: "r", override: .automatic,
                                       outcome: .typed, multiLine: false)
        report.record(event)
        XCTAssertEqual(seen, 1)
        XCTAssertTrue(report.snapshot.isEmpty)
        report.listener = nil
        report.record(event)
        XCTAssertEqual(seen, 1)
        XCTAssertFalse(report.wantsEvents)
    }
}
