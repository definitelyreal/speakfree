// ai-suggestion:unverified · session:unknown · 2026-10-05
import AppKit
import XCTest
@testable import SpeakFreeLib

@MainActor
final class TraceOutputTests: XCTestCase {
    private typealias T = DictationTrace
    private var configDir: URL!

    override func setUp() async throws {
        configDir = FileManager.default.temporaryDirectory.appendingPathComponent("trace-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        Config.configDirOverride = configDir
    }

    override func tearDown() async throws {
        Config.configDirOverride = nil
        try FileManager.default.removeItem(at: configDir)
    }
    private let finished = "Ship the comma fix."
    private var payload: T.Payload {
        .make(engine: "whisper", heard: "ship the kama fix",
              unsure: [.init(word: "kama", score: 0.3)])
    }

    func testOutputModesCarryTheSameTakeWithoutLookup() throws {
        XCTAssertEqual(T.output(payload, mode: .off, text: finished), finished)
        for mode: T.OutputMode in [.tags, .tagsOnly, .selectors] {
            let output = T.output(payload, mode: mode, text: finished)
            let found = try XCTUnwrap(T.find(in: output).first)
            XCTAssertEqual(found.payload, payload)
            XCTAssertEqual(found.payload.heard, "ship the kama fix")
            XCTAssertEqual(found.payload.unsure, [.init(word: "kama", score: 0.3)])
            XCTAssertTrue(found.anchored)
            XCTAssertEqual(T.strip(output), mode == .tagsOnly ? "" : finished)
            if mode == .tagsOnly {
                XCTAssertEqual(output.unicodeScalars.first, "·")
                XCTAssertFalse(output.contains(finished))
            }
        }
    }

    func testExpandedHasReadableRawWordsScoresAndTruncationMarker() {
        let output = T.output(payload, mode: .expanded, text: finished)
        XCTAssertTrue(output.hasPrefix(finished + "\n\nDictation trace"))
        XCTAssertTrue(output.contains("\"heard\":\"ship the kama fix\""))
        XCTAssertTrue(output.contains("\"unsure\":[\"kama 0.30\"]"))
        XCTAssertTrue(T.mayContainTrace(output))
        XCTAssertEqual(T.strip(output), finished)
        let capped = T.Payload.make(engine: "parakeet", heard: String(repeating: "x", count: 2500), unsure: [])
        XCTAssertTrue(T.output(capped, mode: .expanded, text: finished).contains("\"truncated\":true"))
    }

    func testEmptyRawPayloadNeverReplacesFinishedTextWithADot() {
        let empty = T.Payload(engine: "whisper", heard: " \n ")
        for mode in T.OutputMode.allCases {
            XCTAssertEqual(T.output(empty, mode: mode, text: finished), finished)
        }
    }

    func testSecondDictationAfterExpandedUsesFinishedWordsForCaseSpacingAndHints() {
        let raw = T.Payload.make(engine: "whisper", heard: String(repeating: "Misrecognizedword ", count: 100),
                                 unsure: [.init(word: "Misrecognizedword", score: 0.2)])
        for prior in [finished, finished + " ", finished + "\n"] {
            let expanded = T.output(raw, mode: .expanded, text: prior)
            XCTAssertGreaterThan(expanded.count, 500)
            let context = T.cursorContext(expanded)
            XCTAssertEqual(context, prior, "Strip before the AX context bound loses the trace header")
            XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: context))
            let needsSpace = TextInserter.shouldPrependSpace(contextBefore: context)
            XCTAssertEqual(needsSpace, prior == finished)
            let result = TextPipeline.run(.init(raw: "Next sentence.", punctuationMode: .off,
                                               cursorContextText: context), isRealWord: { _ in true })
            XCTAssertEqual(result.finalText, "Next sentence.")
            let insertion = FinalizePipeline.composeInsertText(result.finalText, prependSpace: needsSpace)
            XCTAssertEqual(insertion, prior == finished ? " Next sentence." : "Next sentence.")
            let hints = result.promptHints ?? ""
            XCTAssertFalse(hints.contains("Misrecognizedword"))
            XCTAssertFalse(hints.contains("confidence"))
            XCTAssertFalse(hints.contains("speakfree_trace"))
            XCTAssertTrue(hints.contains("comma"))
        }
    }

    func testExpandedContextCleanupRequiresAnExactCompleteTrailingPayload() {
        let json = T.json(payload, asciiOnly: false)
        for text in [finished + T.expandedHeader + "{broken",
                     finished + T.expandedHeader + "{\"heard\":\"ordinary JSON\"}",
                     finished + T.expandedHeader + json + " User continuation",
                     finished + "\n\nDictation trace:\n" + json] {
            XCTAssertEqual(T.strip(text), text)
        }
        XCTAssertEqual(T.strip(T.output(payload, mode: .expanded, text: finished) + " \n"), finished + " \n")
    }

    func testRememberedTraceContextUsesPlainFinishedText() {
        // Presentation passes this plain text for every trace mode, including dot-only.
        let tail = AppDelegate.insertionTail(contextBefore: "Earlier words. ", inserted: finished)
        XCTAssertEqual(tail, "Earlier words. " + finished)
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: tail))
        XCTAssertFalse(tail.contains("kama"))
    }

    func testRepeatedExpandedDictationsNeverFeedEarlierRawWordsIntoLaterHints() {
        var field = ""
        var plain = ""
        let raw = T.Payload(engine: "whisper", heard: "Misrecognizedword with } and \\\" quoted braces {",
                            unsure: [.init(word: "Misrecognizedword", score: 0.1)])
        for words in ["First clean sentence.", " Second clean sentence.", " Third clean sentence."] {
            field += T.output(raw, mode: .expanded, text: words)
            plain += words
            let context = T.cursorContext(field)
            XCTAssertEqual(context, plain)
            XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: context))
            let hints = TextPipeline.assemblePromptHints(input: .init(
                raw: "Next sentence.", punctuationMode: .off, cursorContextText: context)) ?? ""
            XCTAssertFalse(hints.contains("Misrecognizedword"))
            XCTAssertFalse(hints.contains("confidence"))
            XCTAssertFalse(hints.contains("speakfree_trace"))
        }
        XCTAssertEqual(T.cursorContext(field + " User typed continuation"), plain + " User typed continuation")
        let unrelated = "\n\nDictation trace:\n" + T.json(raw, asciiOnly: false)
        XCTAssertEqual(T.cursorContext(unrelated), unrelated)
        let malformed = T.expandedHeader + "{\"heard\":\"ordinary JSON\"}"
        XCTAssertEqual(T.cursorContext(malformed), malformed)
    }

    func testUnicodeLineSeparatorsInRawWordsAreRemovedAcrossContinuedAndRepeatedTakes() {
        let raw = T.Payload(engine: "whisper", heard: "Misrecognizedword\u{2028}line\u{2029}paragraph } \\\"",
                            unsure: [.init(word: "uncertain\u{2028}word", score: 0.2)])
        var field = T.output(raw, mode: .expanded, text: finished)
        XCTAssertTrue(field.unicodeScalars.contains("\u{2028}"), "Exercise literal JSON scalars, not escaped substitutes")
        XCTAssertEqual(T.cursorContext(field + " User continuation."), finished + " User continuation.")
        field += T.output(raw, mode: .expanded, text: " Next clean sentence.")
        let context = T.cursorContext(field)
        XCTAssertEqual(context, finished + " Next clean sentence.")
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: context))
        let hints = TextPipeline.assemblePromptHints(input: .init(
            raw: "Another sentence.", punctuationMode: .off, cursorContextText: context)) ?? ""
        XCTAssertFalse(hints.contains("Misrecognizedword"))
        XCTAssertFalse(hints.contains("paragraph"))
        XCTAssertFalse(hints.contains("uncertain"))
    }

    func testOrdinaryHugeContextReturnsOnlyABoundedScalarTail() {
        let ordinary = String(repeating: "ordinary text ", count: 100_000) + "Final sentence."
        XCTAssertEqual(T.cursorContext(ordinary), String(ordinary.suffix(T.maxContextScalars)))
        let oneGrapheme = "a" + String(repeating: "\u{0301}", count: T.maxRawContextScalars * 2)
        XCTAssertEqual(oneGrapheme.count, 1)
        XCTAssertEqual(T.cursorContext(oneGrapheme).unicodeScalars.count, T.maxContextScalars)
    }

    func testRawWindowClippingFailsClosedForHugeAndPartialTracePayloads() {
        let raw = T.Payload(engine: "whisper", heard: String(repeating: "misrecognized ", count: T.maxRawContextScalars))
        let huge = T.output(raw, mode: .expanded, text: finished)
        XCTAssertEqual(T.cursorContext(huge), "")
        XCTAssertEqual(T.cursorContext(huge + " User continuation."), "")
        let partial = finished + T.expandedHeader + "{\"speakfree_trace\":1,\"engine\":\"whisper\",\"heard\":\"raw fragment"
        XCTAssertEqual(T.cursorContext(partial), "")
        let truncatedHeader = String(repeating: "ordinary ", count: T.maxRawContextScalars)
            + String(T.expandedHeader.dropFirst(8)) + T.json(payload, asciiOnly: false)
        XCTAssertEqual(T.cursorContext(truncatedHeader), "")
        let selectors = "·" + String(repeating: "\u{E0100}", count: T.maxRawContextScalars * 2)
        XCTAssertLessThan(selectors.count, 10)
        XCTAssertEqual(T.cursorContext(selectors), "")
        XCTAssertEqual(T.cursorContext("·" + String(repeating: "\u{E0100}", count: 30)), "")
    }

    func testUnrelatedHeaderBeforeAValidTraceRemainsContext() {
        let unrelated = T.expandedHeader + "ordinary user note"
        let field = unrelated + T.output(payload, mode: .expanded, text: " Finished sentence.")
        XCTAssertEqual(T.cursorContext(field), unrelated + " Finished sentence.")
    }

    func testTestingMenuHasFourReversibleChoicesAndIsHiddenInRelease() throws {
        var selected: T.OutputMode?
        XCTAssertNil(TraceOutputMenu.make(selected: .off, testingAvailable: false) { selected = $0 })
        let built = try XCTUnwrap(TraceOutputMenu.make(selected: .off, testingAvailable: true) { selected = $0 })
        let items = try XCTUnwrap(built.item.submenu).items
        XCTAssertEqual(items.prefix(4).map(\.title), TraceOutputMenu.options.map(\.title))
        XCTAssertEqual(items.prefix(4).map(\.state), [.on, .off, .off, .off])
        XCTAssertTrue(items.contains { !$0.isEnabled && $0.title.contains("editors/terminals") })
        XCTAssertTrue(items.contains { !$0.isEnabled && $0.title.contains("in a browser") })
        XCTAssertTrue(items.contains { !$0.isEnabled && $0.title.contains("terminal panes") })
        for (target, expected) in zip(built.targets, TraceOutputMenu.options) {
            target.invoke()
            XCTAssertEqual(selected, expected)
        }
        XCTAssertTrue(T.testingAvailable(buildChannel: "alpha", devMode: false))
        XCTAssertTrue(T.testingAvailable(buildChannel: nil, devMode: false))
        XCTAssertTrue(T.testingAvailable(buildChannel: "release", devMode: true))
        XCTAssertFalse(T.testingAvailable(buildChannel: "release", devMode: false))
        XCTAssertFalse(T.testingAvailable(buildChannel: "beta", devMode: false))
        XCTAssertNil(Config.defaultConfig.dictationTrace)
    }

    func testEveryOutputModeKeepsAllTargetAndPrivacyGates() {
        for mode: T.OutputMode in [.tags, .tagsOnly, .expanded, .selectors] {
            var input = TraceGate.Input(setting: mode.rawValue, targetBundleID: "com.openai.codex",
                frontmostBundleID: "com.openai.codex", secureInputActive: false,
                focusedFieldIsSecure: false, testingAvailable: true)
            XCTAssertEqual(TraceGate.decide(input), .append(mode))
            input.secureInputActive = true
            XCTAssertEqual(TraceGate.decide(input), .skip("secure input"))
            input.secureInputActive = false
            input.focusedFieldIsSecure = true
            XCTAssertEqual(TraceGate.decide(input), .skip("password field"))
            input.focusedFieldIsSecure = false
            input.frontmostBundleID = "com.apple.mail"
            XCTAssertEqual(TraceGate.decide(input), .skip("app changed"))
            input.targetBundleID = "com.apple.mail"
            XCTAssertEqual(TraceGate.decide(input), .skip("app not in list"))
            input.targetBundleID = "com.google.Chrome"
            input.frontmostBundleID = "com.google.Chrome"
            XCTAssertEqual(TraceGate.decide(input), .skip("browser page unknown"))
            input.webHost = "mail.google.com"
            XCTAssertEqual(TraceGate.decide(input), .skip("browser page not in list"))
            input.webHost = "chatgpt.com"
            XCTAssertEqual(TraceGate.decide(input), .append(mode))
            input.testingAvailable = false
            XCTAssertEqual(TraceGate.decide(input), mode.testingOnly ? .skip("testing build required") : .append(mode))
        }
    }

    func testNewOutputExperimentsNeverEnterShellOrEditorPanesEvenWhenUserListed() {
        let unsafeTargets = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                             "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                             "com.exafunction.windsurf", "dev.zed.Zed", "com.jetbrains.intellij",
                             "example.unknown-editor"]
        for mode: T.OutputMode in [.tagsOnly, .expanded] {
            for target in unsafeTargets {
                let settings = TraceSettings(setting: mode.rawValue, apps: [target], hosts: nil,
                                             testingAvailable: true)
                let pending = PendingTrace(settings: settings, payload: payload, targetBundleID: target,
                                           focusedFieldIsSecure: false, webHost: nil)
                let decision = pending.decide(frontmostBundleID: target, secureInputActive: false)
                XCTAssertEqual(decision, .skip("testing output requires an AI chat app or approved browser page"), target)
                XCTAssertEqual(pending.insertionText("printf safe", decision: decision), "printf safe")
            }
            // Known AI apps with a discovered terminal library also fail closed.
            let input = TraceGate.Input(setting: mode.rawValue, targetBundleID: "com.openai.codex",
                frontmostBundleID: "com.openai.codex", secureInputActive: false,
                focusedFieldIsSecure: false, testingAvailable: true, mayHostTerminal: true)
            XCTAssertEqual(TraceGate.decide(input), .skip("app may contain a terminal"))
        }
        let legacy = TraceGate.Input(setting: "tags", targetBundleID: "com.apple.Terminal",
            frontmostBundleID: "com.apple.Terminal", secureInputActive: false, focusedFieldIsSecure: false,
            testingAvailable: true, mayHostTerminal: true)
        XCTAssertEqual(TraceGate.decide(legacy), .append(.tags), "legacy compatibility remains explicit")
    }

    func testBlockedDotOnlyKeepsFinishedTextAndSnapshotSurvivesNextModeChoice() throws {
        var config = Config.defaultConfig
        config.dictationTrace = "tags-only"
        let snapshot = TraceSettings(config: config, testingAvailable: true)
        config.dictationTrace = "expanded"
        config.dictationTraceApps = []
        let pending = try XCTUnwrap(PendingTrace.prepare(settings: snapshot, engine: payload.engine,
            heard: payload.heard, unsure: payload.unsure, targetBundleID: "com.openai.codex", element: nil))
        let accepted = pending.decide(frontmostBundleID: "com.openai.codex", secureInputActive: false)
        XCTAssertEqual(accepted, .append(.tagsOnly))
        XCTAssertEqual(T.strip(pending.insertionText(finished, decision: accepted)), "")
        let blocked = pending.decide(frontmostBundleID: "com.apple.mail", secureInputActive: false)
        XCTAssertEqual(pending.insertionText(finished, decision: blocked), finished)
        let later = TraceSettings(config: config, testingAvailable: true)
        XCTAssertEqual(later.setting, "expanded")
        XCTAssertEqual(later.apps, [])
        XCTAssertTrue(snapshot.isOn)
        XCTAssertFalse(TraceSettings(config: config, testingAvailable: false).isOn)
    }

    func testSettingsRoundTripsNewModesAndAppliesMenuChangeWithoutSave() {
        let model = SettingsViewModel(config: Config.defaultConfig)
        var saves = 0
        model.onSave = { saves += 1 }
        for mode in T.OutputMode.allCases {
            model.applyDictationTraceSetting(mode.storedValue)
            XCTAssertEqual(model.dictationTrace, mode.rawValue)
            XCTAssertEqual(model.toConfig().dictationTrace, mode.storedValue)
        }
        XCTAssertEqual(saves, 0)
    }

    func testUnrelatedSettingsSaveKeepsCLIOffAndRefreshesOnlyTraceControl() throws {
        var initial = Config.defaultConfig
        initial.dictationTrace = "tags"
        try initial.save()
        let model = SettingsViewModel(config: initial)
        var cli = initial
        cli.dictationTrace = nil
        cli.dictationTraceApps = []
        cli.dictationTraceWebHosts = []
        try cli.save()

        model.punctuationMode = .off
        model.save()

        let persisted = Config.load()
        XCTAssertNil(persisted.dictationTrace)
        XCTAssertEqual(persisted.dictationTraceApps, [])
        XCTAssertEqual(persisted.dictationTraceWebHosts, [])
        XCTAssertEqual(persisted.effectivePunctuationMode, .off)
        XCTAssertEqual(model.dictationTrace, "off")
        model.save()
        XCTAssertNil(Config.load().dictationTrace)
    }

    func testExplicitTraceChoiceCanReplaceCLIOffEvenIfItMatchesStaleDisplay() throws {
        var initial = Config.defaultConfig
        initial.dictationTrace = "tags"
        try initial.save()
        let model = SettingsViewModel(config: initial)
        var cli = initial
        cli.dictationTrace = nil
        try cli.save()

        model.selectDictationTrace("tags")
        XCTAssertEqual(Config.load().dictationTrace, "tags")
        model.selectDictationTrace("off")
        XCTAssertNil(Config.load().dictationTrace)
        XCTAssertEqual(model.dictationTrace, "off")
    }

    func testMalformedConfigDoesNotResetTraceAllowlistsDuringAnUnrelatedSave() throws {
        var initial = Config.defaultConfig
        initial.dictationTrace = "tags"
        initial.dictationTraceApps = ["com.openai.chat"]
        initial.dictationTraceWebHosts = ["chatgpt.com"]
        let model = SettingsViewModel(config: initial)
        try Data("{broken".utf8).write(to: Config.configFile)
        XCTAssertNil(Config.loadValidWithoutCreating())

        model.punctuationMode = .off
        model.save()

        let saved = try XCTUnwrap(Config.loadValidWithoutCreating())
        XCTAssertNil(saved.dictationTrace, "An unreadable current setting must not silently re-enable trace")
        XCTAssertEqual(saved.dictationTraceApps, initial.dictationTraceApps)
        XCTAssertEqual(saved.dictationTraceWebHosts, initial.dictationTraceWebHosts)
    }

    func testNewModesFailClosedWhenTargetBundleCannotBeValidated() throws {
        let bundle = configDir.appendingPathComponent("Synthetic.app")
        let contents = bundle.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Info.plist")
        func profile(terminal: Bool = false) -> TextInserter.FrontmostProfile {
            .init(bundleID: "com.openai.chat", bundleURL: bundle,
                  classification: .init(appClass: .listedPaste, reason: "test", hasTerminalPane: terminal),
                  override: .automatic)
        }
        XCTAssertTrue(PendingTrace.experimentalTerminalRisk(profile()))
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("unreadable plist".utf8).write(to: plist)
        XCTAssertTrue(PendingTrace.experimentalTerminalRisk(profile()))
        for identity in ["com.other.app", "com.openai.chat"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identity],
                                                          format: .xml, options: 0)
            try data.write(to: plist)
            XCTAssertEqual(PendingTrace.experimentalTerminalRisk(profile()), identity != "com.openai.chat")
        }
        XCTAssertTrue(PendingTrace.experimentalTerminalRisk(profile(terminal: true)))
    }
}
