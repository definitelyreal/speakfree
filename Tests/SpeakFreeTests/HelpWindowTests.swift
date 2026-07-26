// Claude · 2026-07-26 · Session: ec24b5ef-be6a-4c4b-be38-a3b84ca63074
//
// Pins the Help window against STALE PROSE, which was the real 2026-07-26 audit finding
// (build/26-07-26-help-audit/AUDIT.ai.md): the help described Whisper-only models while the
// default engine is Parakeet, and named punctuation modes and a "Max Recordings" control that
// no longer exist. Help that names controls the user cannot find is worse than no help.
//
// It also pins the two REAL layout bugs hit while building this window: the sidebar rendering
// 0pt wide (setPosition() on zero-frame arranged subviews), and the topic list actually having
// to drive the content pane.
//
// NOT pinned, deliberately: "the content is fully scrollable". An earlier version of this file
// asserted document-height >= needed-height and claimed it guarded a clipping regression. That
// assertion is an AppKit invariant for any vertically-resizable text view after layout — the OLD
// implementation satisfies it too (measured: deficit 0.0), so the test could not fail and the
// regression it named never existed. See the CORRECTION block in HelpController.swift.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class HelpWindowTests: XCTestCase {

    /// Never let a Help test read (or a future change let it write) the developer's real config
    /// — the project's test-safety rule, after a test once overwrote it. `HelpFacts.live()` calls
    /// `Config.load()`, so any test that builds a HelpController touches this path.
    private var scratchConfigDir: URL!

    override func setUp() {
        super.setUp()
        scratchConfigDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-help-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchConfigDir,
                                                withIntermediateDirectories: true)
        Config.configDirOverride = scratchConfigDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        if let dir = scratchConfigDir { try? FileManager.default.removeItem(at: dir) }
        scratchConfigDir = nil
        super.tearDown()
    }

    private func facts() -> HelpFacts {
        HelpFacts(
            version: "9.9.9",
            buildDescription: "speakfree 9.9.9 Testing",
            devMode: false,
            hotkeyName: "the Globe / fn key",
            isToggleMode: false,
            engineID: "parakeet",
            whisperModel: "large-v3-turbo",
            parakeetModel: "parakeet-tdt-0.6b-v2",
            saveRecordings: false,
            recordingsPath: "/scratch/rec",
            vocabularyPath: "/scratch/vocab.txt",
            logsPath: "/scratch/logs"
        )
    }

    // MARK: - Layout (only bugs that actually happened)

    /// The sidebar rendered 0pt wide during development: NSSplitView divides by FRAME, and an
    /// arranged subview added with a zero frame stays at zero no matter what setPosition() says.
    /// The window looked content-only and navigation was simply absent. Measured 0.0 x 660.0.
    func test_sidebarHasUsableWidth() throws {
        let controller = HelpController()
        let window = try XCTUnwrap(controller.window)
        let split = try XCTUnwrap(Self.splitView(in: window))

        window.contentView?.layoutSubtreeIfNeeded()
        let sidebarAtDefault = split.arrangedSubviews[0].frame.width
        XCTAssertGreaterThanOrEqual(sidebarAtDefault, 150,
                                    "Sidebar is \(sidebarAtDefault)pt wide — navigation is gone")

        // And it must survive a resize rather than being squeezed out by the content pane.
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, sidebarAtDefault, accuracy: 1.0,
                       "Sidebar width drifted on resize; the content pane should absorb growth")

        window.setContentSize(window.minSize)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[0].frame.width, 100,
                                    "Sidebar collapses at the window's minimum size")
        XCTAssertGreaterThan(split.arrangedSubviews[1].frame.width, 200,
                             "Content pane collapses at the window's minimum size")
    }

    /// Selecting a topic must actually change the content. A no-op'd delegate method leaves a
    /// sidebar that navigates nowhere, and nothing else in this suite would notice.
    func test_selectingATopicRendersThatTopic() throws {
        let controller = HelpController()
        let window = try XCTUnwrap(controller.window)
        let table = try XCTUnwrap(Self.topicTable(in: window))
        let textView = try XCTUnwrap(Self.contentTextView(in: window))
        let topics = HelpContent.topics(HelpFacts.live())

        // Walk backwards so the first assertion is not the row already selected at build time.
        for index in stride(from: topics.count - 1, through: 0, by: -1) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let rendered = textView.string
            XCTAssertTrue(rendered.hasPrefix(topics[index].title),
                          "Selecting row \(index) (\(topics[index].title)) rendered "
                          + "\"\(rendered.prefix(40))…\" instead")
        }
    }

    /// The text must track the window width rather than being frozen at build-time size. This
    /// is an AppKit property rather than a regression guard, but it is the property the whole
    /// content pane depends on, and it is one line to check.
    func test_contentTracksWindowWidth() throws {
        let controller = HelpController()
        let window = try XCTUnwrap(controller.window)
        let textView = try XCTUnwrap(Self.contentTextView(in: window))

        window.setContentSize(NSSize(width: 900, height: 620))
        window.contentView?.layoutSubtreeIfNeeded()
        let wide = textView.frame.width

        window.setContentSize(NSSize(width: 600, height: 620))
        window.contentView?.layoutSubtreeIfNeeded()
        let narrow = textView.frame.width

        XCTAssertLessThan(narrow, wide,
                          "Text view width did not follow the window (\(wide) -> \(narrow))")
    }

    /// ⌘F on a window that is entirely prose. Located by POSITION, not by `usesFindBar` — an
    /// earlier version searched for the view by the very property it then asserted.
    func test_findBarIsEnabledOnTheContentPane() throws {
        let controller = HelpController()
        let window = try XCTUnwrap(controller.window)
        let textView = try XCTUnwrap(Self.contentTextView(in: window))
        XCTAssertTrue(textView.usesFindBar, "Help has no ⌘F find bar")
        XCTAssertTrue(textView.isIncrementalSearchingEnabled)
    }

    /// Every topic must be reachable from the sidebar. Asserted against an explicit expected
    /// list, not against `HelpContent.topics` — comparing the table to the same array it was
    /// built from proves only that reloadData ran.
    func test_sidebarListsTheExpectedTopics() throws {
        let expected = ["Getting Started", "Your Hotkey", "Engines & Models", "Languages",
                        "Punctuation", "Vocabulary", "Recordings & Privacy",
                        "Recovering a Lost Dictation", "Transcribing Audio Files", "Microphone",
                        "Experimental Features", "Speed & Memory", "When Something Goes Wrong",
                        "About speakfree"]
        XCTAssertEqual(HelpContent.topics(facts()).map(\.title), expected,
                       "Help topics changed — update this list deliberately, and check the "
                       + "sidebar width still fits the longest title")

        let controller = HelpController()
        let window = try XCTUnwrap(controller.window)
        let table = try XCTUnwrap(Self.topicTable(in: window))
        XCTAssertEqual(table.numberOfRows, expected.count)
    }

    // MARK: - Link integrity

    /// Every action a topic offers must be routable. An unrouted link looks like a bug in
    /// the app, not a gap in the help.
    func test_everyDeclaredActionRoundTripsThroughItsURL() {
        for action in HelpAction.allCases {
            XCTAssertEqual(HelpAction.from(url: action.url), action,
                           "\(action.rawValue) does not survive URL round-trip")
        }
        // Case-insensitive matching must not let two actions collide.
        let lowered = Set(HelpAction.allCases.map { $0.rawValue.lowercased() })
        XCTAssertEqual(lowered.count, HelpAction.allCases.count,
                       "Two actions collide when lowercased")
    }

    func test_nonHelpURLsAreNotTreatedAsActions() {
        XCTAssertNil(HelpAction.from(url: URL(string: "https://example.com/openSettings")!))
        XCTAssertNil(HelpAction.from(url: URL(string: "speakfree-help://notARealAction")!))
    }

    /// Rendered link attributes must carry a URL that routes. Also asserts links EXIST — an
    /// enumerate over zero matches would otherwise pass silently.
    func test_renderedLinksAllResolve() {
        var linkCount = 0
        for topic in HelpContent.topics(facts()) {
            let body = HelpController.attributedBody(for: topic)
            body.enumerateAttribute(.link,
                                    in: NSRange(location: 0, length: body.length)) { value, range, _ in
                guard let value else { return }
                linkCount += 1
                let url = (value as? URL) ?? URL(string: value as? String ?? "")
                XCTAssertNotNil(url, "Non-URL link in \(topic.title)")
                if let url {
                    XCTAssertNotNil(HelpAction.from(url: url),
                                    "Link \(url) in \(topic.title) routes nowhere")
                }
                XCTAssertGreaterThan(range.length, 0)
            }
        }
        XCTAssertGreaterThanOrEqual(linkCount, 10, "Help rendered almost no action links")
    }

    // MARK: - Content accuracy

    private func allText(_ f: HelpFacts) -> String {
        HelpContent.topics(f)
            .map { HelpController.attributedBody(for: $0).string }
            .joined(separator: "\n")
    }

    /// The exact strings that were wrong before. Each is a control name or claim that the
    /// Settings UI contradicts; naming a control the user cannot find is the failure.
    func test_helpDoesNotNameControlsThatDoNotExist() {
        let text = allText(facts())
        // "Max Recordings" was replaced by the opt-in "Save recordings and transcripts"
        // toggle plus a "Past Recordings" cap.
        XCTAssertFalse(text.contains("Max Recordings"))
        // The punctuation picker's labels are "Automatic & Spoken" / "Automatic Only" /
        // "Spoken Only" — never "Hybrid" or "Spoken words".
        XCTAssertFalse(text.contains("Hybrid"))
        XCTAssertFalse(text.contains("Spoken words"))
        XCTAssertTrue(text.contains("Automatic & Spoken"))
        XCTAssertTrue(text.contains("Automatic Only"))
        XCTAssertTrue(text.contains("Spoken Only"))
        // Settings section names as the GroupBoxes actually label them.
        for section in ["Settings \u{2192} General",
                        "Settings \u{2192} Transcription",
                        "Settings \u{2192} Performance",
                        "Settings \u{2192} Advanced"] {
            XCTAssertTrue(text.contains(section), "Help never points at \(section)")
        }
    }

    /// Help must describe the engine the app actually ships as default.
    func test_helpDocumentsBothEnginesAndTheDefault() {
        let text = allText(facts())
        XCTAssertEqual(Config.defaultEngine, "parakeet",
                       "Default engine changed — the Engines topic needs rewriting")
        for engine in EngineCatalog.engines {
            XCTAssertTrue(text.contains(engine.displayName),
                          "Engine \"\(engine.displayName)\" is not named as Settings labels it")
        }
        for model in EngineCatalog.parakeetModels {
            XCTAssertTrue(text.contains(model.displayName),
                          "Parakeet model \(model.displayName) is undocumented")
        }
    }

    /// Help listed a bare "large" (not selectable — the large row resolves to large-v3), omitted
    /// large-v3 and large-v3-turbo, and marked small.en "Recommended" when the recommendation is
    /// RAM-dependent. Both surfaces now read EngineCatalog, so assert against that.
    func test_whisperModelListMatchesThePicker() {
        // Each model must appear as its OWN row with its OWN figures, checked as a pair.
        // Substring-anywhere checks were too weak: "large-v3" is a substring of
        // "large-v3-turbo", so the large row could be deleted and still "pass", and unpaired
        // memory checks survived swapping two models' figures (2026-07-26 round-2 review).
        let rows: [(String, String)] = HelpContent.topics(facts())
            .flatMap(\.blocks)
            .compactMap { block in
                if case .row(let label, let detail) = block { return (label, detail) }
                return nil
            }
        for model in EngineCatalog.whisperModels {
            let expectedLabel = model.englishID == model.multilingualID
                ? model.englishID
                : "\(model.englishID) / \(model.multilingualID)"
            guard let row = rows.first(where: { $0.0 == expectedLabel }) else {
                XCTFail("Whisper model \"\(expectedLabel)\" is in the picker but has no Help row")
                continue
            }
            XCTAssertTrue(row.1.contains(model.memoryDescription),
                          "\(expectedLabel)'s memory figure disagrees with the picker: Help says "
                          + "\"\(row.1)\", picker says \(model.memoryDescription)")
            XCTAssertTrue(row.1.contains(model.loadTimeDescription),
                          "\(expectedLabel)'s load time disagrees with the picker")
        }
        // The bare "large" id is not selectable anywhere and must not be presented as a choice.
        XCTAssertFalse(EngineCatalog.whisperModels.contains { $0.multilingualID == "large" })
        // Exactly one model may be marked recommended, and it must be the one this Mac's RAM
        // selects. The assertion here used to be an always-true three-way conjunction whose last
        // term the very next line asserted to be false.
        let recommendedRows = rows.filter { $0.1.contains("Recommended on this Mac") }
        XCTAssertEqual(recommendedRows.count, 1, "expected exactly one recommended Whisper model")
        let expectedRecommended = EngineCatalog.whisperModels.first {
            $0.base == EngineCatalog.recommendedWhisperBase()
        }
        XCTAssertEqual(recommendedRows.first?.0.hasPrefix(expectedRecommended?.englishID ?? "?"),
                       true,
                       "Help recommends a different model than recommendedWhisperBase()")
        // The recommendation must be computed, not asserted in prose.
        XCTAssertEqual(EngineCatalog.recommendedWhisperBase(
            physicalMemoryBytes: 64 * 1024 * 1024 * 1024), "turbo")
        XCTAssertEqual(EngineCatalog.recommendedWhisperBase(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024), "turbo")
        XCTAssertEqual(EngineCatalog.recommendedWhisperBase(
            physicalMemoryBytes: 12 * 1024 * 1024 * 1024), "small")
        XCTAssertEqual(EngineCatalog.recommendedWhisperBase(
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024), "base")
    }

    /// Recordings are opt-in and off by default since 2026-07-14. Help must not imply they
    /// are being kept.
    func test_privacyTopicStatesRecordingsAreOptIn() {
        let text = allText(facts())
        XCTAssertTrue(text.contains("OFF by default"))
        XCTAssertTrue(text.contains("Save recordings and transcripts"))
        XCTAssertTrue(text.contains("NOT being saved"),
                      "With saving off, Help should say so rather than describe stored files")
    }

    /// Hold vs Toggle sits next to the hotkey picker and was entirely undocumented. Asserted on
    /// the hotkey topic's own rows, not as substrings of the whole document, where the words
    /// "Hold" and "Toggle" appear in ordinary prose anyway.
    func test_hotkeyTopicDocumentsBothModesAsRows() throws {
        let topic = try XCTUnwrap(HelpContent.topics(facts()).first { $0.id == "hotkey" })
        let rowLabels: [String] = topic.blocks.compactMap {
            if case .row(let label, _) = $0 { return label }
            return nil
        }
        XCTAssertTrue(rowLabels.contains("Hold"), "Hold mode has no row in the Hotkey topic")
        XCTAssertTrue(rowLabels.contains("Toggle"), "Toggle mode has no row in the Hotkey topic")
        XCTAssertTrue(rowLabels.contains { $0.contains("Right Option") },
                      "Right Option is not listed as a selectable hotkey")
    }

    /// Live facts must appear, so a user reading Help can see what they are running.
    func test_liveFactsAppearInTheText() {
        var f = facts()
        f.buildDescription = "speakfree 9.9.9 Testing"
        f.hotkeyName = "Right Command (\u{2318})"
        f.isToggleMode = true
        let text = allText(f)
        XCTAssertTrue(text.contains("speakfree 9.9.9 Testing"))
        XCTAssertTrue(text.contains("Right Command"))
        XCTAssertTrue(text.contains("Press Right Command (\u{2318}) once to start"),
                      "Getting Started must describe the mode the user actually has")

        // And the hold-mode wording must differ, or the fact is decorative.
        var hold = f
        hold.isToggleMode = false
        XCTAssertTrue(allText(hold).contains("Hold Right Command"))
    }

    /// The fn/emoji-drawer note is shown only when fn IS the hotkey — it is noise otherwise.
    func test_emojiDrawerNoteOnlyAppearsForTheFnHotkey() {
        var fn = facts()
        fn.hotkeyName = "the Globe / fn key"
        XCTAssertTrue(allText(fn).contains("emoji drawer"))

        var option = facts()
        option.hotkeyName = "Right Option (\u{2325})"
        XCTAssertFalse(allText(option).contains("emoji drawer"),
                       "The emoji-drawer caveat should not show when fn is not the hotkey")
    }

    /// Help states this mode-independently, because the suppression IS mode-independent. The
    /// Settings banner is scoped to toggle mode by product decision; Help must not inherit that
    /// scoping, or a hold-mode user has nowhere to find out why their emoji key is dead.
    func test_emojiDrawerNoteIsNotScopedToToggleMode() {
        var hold = facts()
        hold.hotkeyName = "the Globe / fn key"
        hold.isToggleMode = false
        let text = allText(hold)
        XCTAssertTrue(text.contains("emoji drawer"),
                      "Hold-mode fn users get no explanation for the dead emoji key")
        XCTAssertFalse(text.contains("in toggle mode disables"),
                       "Help must not blame toggle mode for a mode-independent behavior")
    }

    /// Dev mode changes real behavior, so Help must disclose it rather than describe stock
    /// behavior that does not apply on this machine.
    func test_devModeIsDisclosed() {
        var dev = facts()
        dev.devMode = true
        dev.saveRecordings = true
        let text = allText(dev)
        XCTAssertTrue(text.contains("developer mode is active")
                      || text.contains("Developer mode is active"))
        XCTAssertTrue(text.contains(".speakfree-dev"))

        var stock = facts()
        stock.devMode = false
        XCTAssertFalse(allText(stock).contains("developer mode is active"),
                       "Dev-mode disclosure leaks into stock installs")
    }

    /// The round-2 blockers, pinned against the code that contradicted them. Each of these
    /// sentences shipped in the first rewrite and was false.
    func test_correctedClaimsStayCorrected() {
        let text = allText(facts())

        // Recovery is automatic. There is no menu item to click and nothing touches the
        // clipboard: AppDelegate.autoRecoverOrphans runs at launch, and StatusBarController's
        // showCrashRecovery has no call site at all.
        XCTAssertFalse(text.contains("Recover Unsaved Recording"),
                       "Help names a menu item the app never builds")
        XCTAssertTrue(text.contains("There is nothing to click"))

        // File transcription has its OWN engine settings, not the dictation engine.
        XCTAssertNotEqual(FileTranscriptionSettings.default.engine, Config.defaultEngine,
                          "If these ever agree, the audio-files topic should be simplified")
        XCTAssertEqual(FileTranscriptionSettings.default.engine, "whisper")
        XCTAssertTrue(text.contains("its OWN settings"),
                      "Help must not imply file transcription reuses the dictation engine")

        // Without Accessibility, nothing runs — transcription does not "work but not type".
        XCTAssertFalse(text.contains("transcription works but nothing is typed"))
        XCTAssertTrue(text.contains("does not start at all"))

        // Parakeet ignores suppressRegex, so Spoken Only cannot suppress its punctuation.
        XCTAssertTrue(text.contains("only works on Whisper"))
    }

    /// The round-3 blocker and majors, pinned against CODE rather than against Help's own
    /// strings where that is possible. Round 3's criticism of the previous version of this suite
    /// was fair: string-only pins catch a rewrite reintroducing the same sentence, but go green
    /// if the underlying behavior changes and Help becomes false again.
    func test_claimsThatDependOnBehaviorArePinnedToTheBehavior() {
        let text = allText(facts())

        // Models do NOT auto-download. AppDelegate refuses to (it keeps the current transcriber
        // running), and both pickers render a Download button. If auto-download is ever
        // implemented, this fails and the Engines topic needs rewriting.
        XCTAssertTrue(text.contains("does NOT start a download on its own"),
                      "Help must not promise automatic downloads")

        // Both facts in the audio-files paragraph, not just the engine.
        XCTAssertEqual(FileTranscriptionSettings.default.engine, "whisper")
        XCTAssertEqual(FileTranscriptionSettings.default.modelSize, "large-v3-turbo")
        XCTAssertTrue(text.contains("Whisper large-v3-turbo"),
                      "Help names the file-transcription default model, so pin it")

        // Recordings are opt-in and default OFF — asserted on Config, not on Help's prose.
        XCTAssertFalse(DevMode.effectiveSaveRecordings({
            var c = Config.defaultConfig
            c.saveRecordings = nil
            setenv("SPEAKFREE_DEV_MODE", "0", 1)
            return c
        }()), "recordings must default off, or the Privacy topic is wrong")
        unsetenv("SPEAKFREE_DEV_MODE")

        // The vocabulary bullets describe real thresholds. A real word must survive even an
        // exact match — that is the "I will" -> "I Will" guard, and Help now says so.
        // `isRealWord` is injected rather than using NSSpellChecker, so this asserts the guard's
        // logic and not the system dictionary (the existing GlossaryCorrectorTests do the same).
        let isReal: (String) -> Bool = { ["will", "grace", "i", "send", "it"].contains($0.lowercased()) }
        XCTAssertEqual(GlossaryCorrector.correct("i will send it", glossary: ["Will"],
                                                 isRealWord: isReal),
                       "i will send it",
                       "a real word must not be rewritten even on an exact match")
        XCTAssertTrue(text.contains("nothing at all, even when you say exactly that word"))
        // A non-word matching an entry IS corrected, so the bullet is not vacuous.
        XCTAssertEqual(GlossaryCorrector.correct("maryna", glossary: ["Maryna"],
                                                 isRealWord: isReal),
                       "Maryna")
    }

    /// The catalog must resolve every id the app can hand it, including quantized and legacy ones,
    /// or the Settings Performance footnote reads "Unknown"/"unknown".
    func test_whisperModelLookupResolvesLegacyAndQuantizedIDs() {
        for id in ["tiny.en", "tiny", "base.en", "small.en", "medium.en",
                   "large-v3-turbo", "large-v3", "large", "large-v2", "base.en-q5_1"] {
            XCTAssertNotNil(EngineCatalog.whisperModel(forID: id),
                            "\(id) does not resolve, so Settings would show Unknown")
            XCTAssertNotEqual(SettingsViewModel.modelMemoryDescription(id), "Unknown", "\(id)")
            XCTAssertNotEqual(SettingsViewModel.modelLoadTimeDescription(id), "unknown", "\(id)")
        }
        XCTAssertEqual(EngineCatalog.whisperModel(forID: "large-v2")?.base, "large")
        XCTAssertEqual(EngineCatalog.whisperModel(forID: "base.en-q5_1")?.base, "base")
        XCTAssertEqual(EngineCatalog.whisperModel(forID: "large-v3-turbo")?.base, "turbo")
    }

    /// HelpFacts must resolve config defaults the way the RUNTIME does. Reporting a state the app
    /// is not in is the exact failure this file exists to prevent.
    func test_helpFactsResolveDefaultsLikeTheRuntime() {
        // A legacy config with no `engine` key: EngineFactory builds Whisper, so Help must say
        // Whisper, NOT Config.defaultEngine, which is the NEW-install default.
        var legacy = Config.defaultConfig
        legacy.engine = nil
        legacy.parakeetModel = nil
        let facts = HelpFacts.live(config: legacy)
        XCTAssertEqual(facts.engineID, "whisper",
                       "Help would announce Parakeet while the app runs Whisper")
        XCTAssertFalse(facts.engineIsParakeet)
    }

    func test_noEmDashesInHelpProse() {
        // Project-wide writing rule. Em-dash is U+2014; the renderer inserts " — " only as the
        // row separator, which is deliberate typography rather than prose. Assert the CONTENT
        // strings carry none.
        for topic in HelpContent.topics(facts()) {
            for block in topic.blocks {
                let strings: [String]
                switch block {
                case .paragraph(let s), .bullet(let s): strings = [s]
                case .row(let a, let b): strings = [a, b]
                case .action(let s, _): strings = [s]
                case .spacer: strings = []
                }
                for s in strings {
                    XCTAssertFalse(s.contains("\u{2014}"),
                                   "Em-dash in help prose (\(topic.title)): \(s)")
                }
            }
        }
    }

    // MARK: - View lookup helpers
    //
    // Located structurally (split view -> arranged subviews) rather than by searching for a
    // property under test, so a test cannot pass by finding the view it was looking for.

    private static func splitView(in window: NSWindow) -> NSSplitView? {
        window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first
    }

    private static func topicTable(in window: NSWindow) -> NSTableView? {
        guard let sidebar = splitView(in: window)?.arrangedSubviews.first else { return nil }
        return descendants(of: sidebar).compactMap { $0 as? NSTableView }.first
    }

    private static func contentTextView(in window: NSWindow) -> NSTextView? {
        guard let split = splitView(in: window), split.arrangedSubviews.count > 1 else { return nil }
        let pane = split.arrangedSubviews[1]
        return (pane as? NSScrollView)?.documentView as? NSTextView
            ?? descendants(of: pane).compactMap { $0 as? NSTextView }.first
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
