// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// App compatibility: detection of app classes for apps nobody listed, the routing table, the
// per-app override, and the opt-in compatibility report. Every inserter here has all of its
// output seams injected, so no test posts a key event, touches the real clipboard, performs
// AX IPC, or reads/writes the real config.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class AppCompatibilityTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree.appcompat.\(UUID().uuidString)")
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

    // MARK: - Helpers

    private func info(id: String, schemes: [String] = [], html: Bool = false) -> [String: Any] {
        var dict: [String: Any] = ["CFBundleIdentifier": id]
        if !schemes.isEmpty {
            dict["CFBundleURLTypes"] = [["CFBundleURLSchemes": schemes]]
        }
        if html {
            dict["CFBundleDocumentTypes"] = [["LSItemContentTypes": ["public.html"]]]
        }
        return dict
    }

    private func classOf(_ id: String, schemes: [String] = [], html: Bool = false,
                         frameworks: Set<String>? = nil, chromium: Set<String>? = nil) -> AppClass {
        AppCompatibility.classify(bundleID: id, info: info(id: id, schemes: schemes, html: html),
                                  frameworks: frameworks, chromiumFrameworks: chromium).appClass
    }

    /// A synthetic .app with a real Info.plist and optional frameworks.
    private func makeBundle(id: String, schemes: [String] = [], html: Bool = false,
                            frameworks: [String] = [], chromiumMarkerIn: String? = nil) throws -> URL {
        let app = tempDir.appendingPathComponent("\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks"),
                                                withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info(id: id, schemes: schemes, html: html), format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        for name in frameworks {
            let fw = contents.appendingPathComponent("Frameworks/\(name)/Resources")
            try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
            if name == chromiumMarkerIn {
                try Data().write(to: fw.appendingPathComponent(AppCompatibility.chromiumMarkerResource))
            }
        }
        return app
    }

    // MARK: - Existing routes are preserved

    func test_everyPreviouslyListedRemoteViewerIsStillRemote() {
        for id in ["com.apple.ScreenSharing", "com.splashtop.stp.macosx", "com.splashtop.Splashtop-Streamer",
                   "com.splashtop.PersonalBusiness", "com.splashtop.streamer", "com.microsoft.rdc.macos",
                   "com.microsoft.rdc.osx", "com.teamviewer.TeamViewer", "com.parallels.desktop.console",
                   "com.vmware.fusion", "com.realvnc.vncviewer", "com.citrix.receiver.icaviewer",
                   "com.parsec-cloud.parsec", "com.moonlight-stream.Moonlight"] {
            XCTAssertEqual(classOf(id), .remoteDesktop, id)
        }
    }

    func test_everyPreviouslyListedPasteAppStillPastes() {
        for id in ["org.whispersystems.signal-desktop", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode",
                   "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.hnc.Discord",
                   "notion.id", "com.linear", "com.figma.Desktop", "com.spotify.client",
                   "com.github.GitHubClient", "com.1password.1password", "md.obsidian",
                   "com.superhuman.superhuman", "com.superhuman.electron", "com.microsoft.teams2",
                   "us.zoom.xos", "com.loom.desktop", "com.openai.codex", "com.openai.chat",
                   "com.anthropic.claudefordesktop"] {
            let cls = classOf(id)
            XCTAssertEqual(cls, .listedPaste, id)
            XCTAssertEqual(AppCompatibility.route(for: cls, override: .automatic, textHasLineBreak: false), .paste, id)
            XCTAssertTrue(cls.cursorContextUntrusted, id)
        }
    }

    func test_everyPreviouslyListedBrowserIsStillABrowser() {
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "org.mozilla.firefox",
                   "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
                   "com.microsoft.edgemac.Dev", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
                   "com.kagi.kagimacos"] {
            XCTAssertEqual(classOf(id), .browser, id)
            XCTAssertTrue(TextInserter.isBrowser(bundleID: id), id)
        }
    }

    func test_ordinaryNativeAppsStayOnTheAccessibilityChain() {
        for id in ["com.apple.TextEdit", "com.apple.Notes", "com.apple.mail", "com.example.someapp"] {
            let cls = classOf(id)
            XCTAssertEqual(cls, .native, id)
            XCTAssertEqual(AppCompatibility.route(for: cls, override: .automatic, textHasLineBreak: true),
                           .accessibilityChain, id)
        }
    }

    // MARK: - Detection of apps nobody listed

    func test_unknownViewerIsRemoteByTheURLSchemesItRegisters() {
        for scheme in ["vnc", "rdp", "ms-rd", "VNC"] {
            let result = AppCompatibility.classify(bundleID: "com.example.viewer",
                                                   info: info(id: "com.example.viewer", schemes: [scheme]),
                                                   frameworks: nil)
            XCTAssertEqual(result.appClass, .remoteDesktop, scheme)
            XCTAssertTrue(result.reason.contains(scheme.lowercased()), result.reason)
        }
    }

    func test_newlyListedRemoteViewers() {
        for id in ["com.p5sys.jump.mac.viewer", "com.p5sys.jump.mac.viewer.web", "com.edovia.screens5.mac",
                   "com.philandro.anydesk", "com.carriez.rustdesk", "com.nomachine.nxplayer",
                   "com.amazon.workspaces", "com.teradici.pcoip-client", "tv.parsec.www",
                   "com.utmapp.UTM", "org.virtualbox.app.VirtualBoxVM"] {
            XCTAssertEqual(classOf(id), .remoteDesktop, id)
        }
    }

    func test_terminalsAreDetected() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                   "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "org.tabby", "co.zeit.hyper"] {
            XCTAssertEqual(classOf(id), .terminal, id)
        }
        // Unknown terminal: registers ssh links.
        XCTAssertEqual(classOf("com.example.newterm", schemes: ["ssh"]), .terminal)
    }

    /// iTerm2 registers http(s) links and HTML documents too. It must stay a terminal.
    func test_terminalThatAlsoOpensWebLinksIsATerminal() {
        XCTAssertEqual(classOf("com.googlecode.iterm2", schemes: ["ssh", "http", "https"], html: true), .terminal)
        XCTAssertEqual(classOf("com.example.term2", schemes: ["ssh", "http"], html: true), .terminal)
    }

    /// Hyper and Tabby are Electron; they are still terminals.
    func test_electronTerminalIsATerminal() {
        XCTAssertEqual(classOf("co.zeit.hyper", frameworks: ["Electron Framework.framework"]), .terminal)
    }

    func test_unknownBrowserNeedsWebLinksAndHTMLFiles() {
        XCTAssertEqual(classOf("com.example.newbrowser", schemes: ["http", "https"], html: true), .browser)
        // Cyberduck, VLC, mpv: claim http but do not open HTML files. Not browsers.
        XCTAssertEqual(classOf("ch.sudo.cyberduck", schemes: ["http", "https", "ftp"]), .native)
    }

    func test_webRuntimeDetectedByFramework() {
        for fw in ["Electron Framework.framework", "Chromium Embedded Framework.framework",
                   "nwjs Framework.framework"] {
            XCTAssertEqual(classOf("com.example.webapp", frameworks: [fw, "Sparkle.framework"]), .webRuntime, fw)
        }
    }

    /// ChatGPT ships "Codex Framework.framework": a renamed Chromium only the marker finds.
    func test_renamedChromiumFrameworkDetectedByMarker() {
        XCTAssertEqual(classOf("com.example.renamed", frameworks: ["Codex Framework.framework"],
                               chromium: ["Codex Framework.framework"]), .webRuntime)
    }

    /// Qt apps ship Qt WebEngine for side panels; their text fields are native widgets.
    func test_qtWebEngineIsNotAWebRuntime() {
        XCTAssertEqual(classOf("com.example.qt", frameworks: ["QtWebEngineCore.framework"]), .native)
    }

    func test_editorsWithTerminalPanesPaste() {
        for id in ["dev.zed.Zed", "dev.zed.Zed-Preview", "com.jetbrains.intellij", "com.jetbrains.pycharm.ce",
                   "com.panic.Nova"] {
            let cls = classOf(id)
            XCTAssertEqual(cls, .terminalHost, id)
            XCTAssertEqual(AppCompatibility.route(for: cls, override: .automatic, textHasLineBreak: true), .paste, id)
            XCTAssertFalse(cls.cursorContextUntrusted, "editor context stays trusted: \(id)")
        }
    }

    func test_malformedURLTypesAreTolerated() {
        let bad: [String: Any] = [
            "CFBundleIdentifier": "com.example.bad",
            "CFBundleURLTypes": ["not-a-dict", ["CFBundleURLSchemes": ["vnc", 42]]],
        ]
        XCTAssertEqual(AppCompatibility.urlSchemes(infoDictionary: bad), ["vnc"])
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.bad", info: bad, frameworks: nil).appClass,
                       .remoteDesktop)
    }

    func test_missingBundleIDIsNative() {
        XCTAssertEqual(AppCompatibility.classify(bundleID: nil, info: nil, frameworks: nil).appClass, .native)
        XCTAssertEqual(AppCompatibility.classify(bundleID: "", bundleURL: nil).appClass, .native)
    }

    // MARK: - Filesystem probe

    func test_bundleProbeFindsRenamedChromiumOnDisk() throws {
        let url = try makeBundle(id: "com.example.disk", frameworks: ["Codex Framework.framework", "Sparkle.framework"],
                                 chromiumMarkerIn: "Codex Framework.framework")
        let result = AppCompatibility.classify(bundleID: "com.example.disk", bundleURL: url)
        XCTAssertEqual(result.appClass, .webRuntime)
        XCTAssertTrue(result.reason.contains("Codex Framework"), result.reason)
    }

    func test_bundleProbeReadsURLSchemesOnDisk() throws {
        let url = try makeBundle(id: "com.example.newviewer", schemes: ["rdp"])
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.newviewer", bundleURL: url).appClass,
                       .remoteDesktop)
    }

    /// A bundle whose Info.plist names another app is ignored, so a mismatched URL can never
    /// reclassify an app.
    func test_bundleOfADifferentAppIsIgnored() throws {
        let url = try makeBundle(id: "com.example.other", schemes: ["vnc"])
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.asked", bundleURL: url).appClass, .native)
    }

    // MARK: - Routing table

    func test_noRouteEverTypesALineBreakIntoATerminal() {
        for method in InsertionMethod.allCases {
            let route = AppCompatibility.route(for: .terminal, override: method, textHasLineBreak: true)
            XCTAssertNotEqual(route, .keystrokes, method.rawValue)
            // Accessibility's chain ends in typing only after the typing guard; covered below.
        }
    }

    func test_overrideRoutes() {
        XCTAssertEqual(AppCompatibility.route(for: .native, override: .paste, textHasLineBreak: false), .paste)
        XCTAssertEqual(AppCompatibility.route(for: .native, override: .type, textHasLineBreak: true), .keystrokes)
        XCTAssertEqual(AppCompatibility.route(for: .webRuntime, override: .type, textHasLineBreak: false), .keystrokes)
        XCTAssertEqual(AppCompatibility.route(for: .browser, override: .accessibility, textHasLineBreak: false),
                       .accessibilityChain)
        XCTAssertEqual(AppCompatibility.route(for: .terminal, override: .type, textHasLineBreak: false), .keystrokes)
        XCTAssertEqual(AppCompatibility.route(for: .remoteDesktop, override: .paste, textHasLineBreak: false), .remotePaste)
        XCTAssertEqual(AppCompatibility.route(for: .remoteDesktop, override: .type, textHasLineBreak: false),
                       .remoteKeystroke)
        XCTAssertEqual(AppCompatibility.route(for: .remoteDesktop, override: .automatic, textHasLineBreak: true),
                       .remoteKeystroke)
    }

    func test_accessibilityOverrideOnAViewerRunsTheChainButStaysRemoteSafe() {
        XCTAssertEqual(AppCompatibility.route(for: .remoteDesktop, override: .accessibility, textHasLineBreak: false),
                       .accessibilityChain)
        XCTAssertTrue(AppCompatibility.typedLineBreaksUnsafe(appClass: .remoteDesktop, bundleID: nil))
    }

    func test_restoreBackstopForTerminalsIsTheLongOne() {
        XCTAssertEqual(AppCompatibility.pasteRestoreRoute(for: .terminal), .electron)
        XCTAssertEqual(AppCompatibility.pasteRestoreRoute(for: .native), .native)
        XCTAssertEqual(AppCompatibility.pasteRestoreRoute(for: .remoteDesktop), .remote)
    }

    func test_overrideLookupIsCaseInsensitive() {
        let overrides: [String: InsertionMethod] = ["Com.Example.App": .paste]
        XCTAssertEqual(AppCompatibility.override(for: "com.example.app", in: overrides), .paste)
        XCTAssertEqual(AppCompatibility.override(for: "com.example.other", in: overrides), .automatic)
        XCTAssertEqual(AppCompatibility.override(for: nil, in: overrides), .automatic)
    }

    // MARK: - Inserter behavior through seams

    private final class Recorder {
        var pasted: [String] = []
        var typed: [String] = []
        var remote: [String] = []
    }

    private func makeInserter(bundleID: String, overrides: [String: InsertionMethod] = [:],
                              report: CompatibilityReport? = nil) -> (TextInserter, Recorder) {
        let recorder = Recorder()
        let inserter = TextInserter()
        inserter.frontmostBundleIDProvider = { bundleID }
        inserter.frontmostBundleURLProvider = { nil }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.insertionOverrides = overrides
        inserter.compatibilityReport = report ?? CompatibilityReport()
        inserter.performPaste = { recorder.pasted.append($0) }
        inserter.performUnicodeInsertion = { recorder.typed.append($0); return true }
        inserter.performRemoteInsertion = { recorder.remote.append($0) }
        inserter.executeAppleScript = { _ in XCTFail("Unexpected AppleScript"); return nil }
        inserter.onRemoteInsertionFailure = { _, message in XCTFail(message) }
        inserter.pasteboard = NSPasteboard(name: .init("speakfree.test.appcompat.\(UUID().uuidString)"))
        addTeardownBlock { inserter.pasteboard.releaseGlobally() }
        return (inserter, recorder)
    }

    func test_terminalGetsPasteForMultiLineDictation() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.Terminal")
        XCTAssertTrue(inserter.insert(text: "git status\nls"))
        XCTAssertEqual(rec.pasted, ["git status\nls"])
        XCTAssertTrue(rec.typed.isEmpty)
    }

    func test_terminalTypeOverrideStillNeverTypesALineBreak() {
        let (inserter, rec) = makeInserter(bundleID: "com.mitchellh.ghostty",
                                           overrides: ["com.mitchellh.ghostty": .type])
        inserter.insert(text: "first line\nsecond line")
        XCTAssertEqual(rec.pasted, ["first line\nsecond line"])
        XCTAssertTrue(rec.typed.isEmpty, "a line break must never be typed into a terminal")
        inserter.insert(text: "one line")
        XCTAssertEqual(rec.typed, ["one line"])
    }

    /// The Accessibility chain ends in typing when AX is unavailable. In a terminal that final
    /// step must refuse a line break and paste instead.
    func test_terminalAccessibilityOverrideFallsBackToPasteForLineBreaks() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.Terminal",
                                           overrides: ["com.apple.terminal": .accessibility])
        inserter.insert(text: "echo hi\necho bye")
        XCTAssertTrue(rec.typed.isEmpty)
        XCTAssertEqual(rec.pasted, ["echo hi\necho bye"])
    }

    func test_pasteOverrideOnANativeApp() {
        let (inserter, rec) = makeInserter(bundleID: "com.example.native",
                                           overrides: ["com.example.native": .paste])
        inserter.insert(text: "hello")
        XCTAssertEqual(rec.pasted, ["hello"])
        XCTAssertTrue(rec.typed.isEmpty)
    }

    func test_typeOverrideOnAPasteApp() {
        let (inserter, rec) = makeInserter(bundleID: "com.tinyspeck.slackmacgap",
                                           overrides: ["com.tinyspeck.slackmacgap": .type])
        inserter.insert(text: "hello")
        XCTAssertEqual(rec.typed, ["hello"])
        XCTAssertTrue(rec.pasted.isEmpty)
    }

    func test_nativeAppWithoutAXFallsToTyping() {
        let (inserter, rec) = makeInserter(bundleID: "com.example.native")
        inserter.insert(text: "hello")
        XCTAssertEqual(rec.typed, ["hello"])
    }

    func test_newRemoteViewerUsesTheRemoteRoute() {
        let (inserter, rec) = makeInserter(bundleID: "com.philandro.anydesk")
        inserter.insert(text: "hello")
        XCTAssertEqual(rec.remote, ["hello"])
        XCTAssertTrue(rec.typed.isEmpty && rec.pasted.isEmpty)
    }

    func test_accessibilityOverrideTurnsAKeywordFalsePositiveLocal() {
        let (inserter, rec) = makeInserter(bundleID: "com.example.vncnotes",
                                           overrides: ["com.example.vncnotes": .accessibility])
        // Still recognized as remote for safety; Accessibility runs the chain, and when AX is
        // unavailable the chain pastes instead of sending Unicode key events ("aaa").
        XCTAssertTrue(inserter.isRemoteDesktopFrontmost())
        inserter.insert(text: "hello")
        XCTAssertTrue(rec.remote.isEmpty)
        XCTAssertTrue(rec.typed.isEmpty, "no Unicode key events into a detected viewer")
        XCTAssertEqual(rec.pasted, ["hello"])
    }

    func test_remotePasteOverrideUsesRemoteRoute() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.ScreenSharing",
                                           overrides: ["com.apple.ScreenSharing": .paste])
        inserter.insert(text: "hello")
        XCTAssertEqual(rec.remote, ["hello"])
    }

    /// Refocus path: a paste-routed app must not get the unverified direct AX write (the
    /// Claude for Desktop silent drop), it must get its paste.
    private func simulateSuccessfulRefocus(_ inserter: TextInserter) -> AXUIElement {
        let target = AXUIElementCreateApplication(999_999)
        var refocused = false
        inserter.focusedElementProvider = { refocused ? target : nil }
        inserter.refocusElement = { _ in refocused = true; return true }
        return target
    }

    func test_refocusIntoPasteAppSkipsTheUnverifiedAXWrite() {
        let (inserter, rec) = makeInserter(bundleID: "com.anthropic.claudefordesktop")
        let target = simulateSuccessfulRefocus(inserter)
        inserter.directAXInsert = { _, _ in XCTFail("paste-routed app got a direct AX write"); return true }
        let done = expectation(description: "paste after refocus")
        inserter.performPaste = { text in
            rec.pasted.append(text)
            done.fulfill()
        }
        XCTAssertTrue(inserter.insert(text: "hello claude", refocusing: target))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(rec.pasted, ["hello claude"])
    }

    func test_refocusIntoNativeAppStillTriesAXFirst() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.TextEdit")
        let target = simulateSuccessfulRefocus(inserter)
        let axTried = expectation(description: "direct AX write")
        inserter.directAXInsert = { _, _ in axTried.fulfill(); return true }
        XCTAssertTrue(inserter.insert(text: "hello", refocusing: target))
        wait(for: [axTried], timeout: 2)
        XCTAssertTrue(rec.pasted.isEmpty)
    }

    func test_refocusIntoTerminalPastes() {
        let (inserter, rec) = makeInserter(bundleID: "com.googlecode.iterm2")
        let target = simulateSuccessfulRefocus(inserter)
        inserter.directAXInsert = { _, _ in XCTFail("terminal got a direct AX write"); return true }
        let done = expectation(description: "paste after refocus")
        inserter.performPaste = { rec.pasted.append($0); done.fulfill() }
        inserter.insert(text: "ls\npwd", refocusing: target)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(rec.pasted, ["ls\npwd"])
    }

    // MARK: - Compatibility report

    func test_reportRecordsRouteWithoutText() {
        let report = CompatibilityReport()
        report.isEnabled = true
        let (inserter, _) = makeInserter(bundleID: "com.apple.Terminal", report: report)
        let secret = "my secret dictation 4417"
        inserter.insert(text: secret + "\nnext")
        let events = report.snapshot
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.bundleID, "com.apple.Terminal")
        XCTAssertEqual(events.first?.appClass, .terminal)
        XCTAssertEqual(events.first?.outcome, .pasted)
        XCTAssertEqual(events.first?.multiLine, true)

        let text = CompatibilityReport.render(events: events, speakfreeVersion: "9.9.9", macOSVersion: "Test")
        XCTAssertTrue(text.contains("com.apple.Terminal"))
        XCTAssertTrue(text.contains("Terminal"))
        XCTAssertTrue(text.contains("pasted"))
        XCTAssertFalse(text.contains("secret"), "report must never contain dictated text")
        XCTAssertFalse(text.contains("4417"))
    }

    func test_reportIsOffByDefaultAndClearsWhenTurnedOff() {
        let report = CompatibilityReport()
        let (inserter, _) = makeInserter(bundleID: "com.example.native", report: report)
        inserter.insert(text: "hello")
        XCTAssertTrue(report.snapshot.isEmpty, "off by default")
        report.isEnabled = true
        inserter.insert(text: "hello")
        XCTAssertEqual(report.snapshot.count, 1)
        XCTAssertEqual(report.snapshot.first?.outcome, .typed)
        report.isEnabled = false
        XCTAssertTrue(report.snapshot.isEmpty, "turning it off discards what was recorded")
    }

    func test_reportRecordsSecureInput() {
        let report = CompatibilityReport()
        report.isEnabled = true
        let (inserter, _) = makeInserter(bundleID: "com.example.native", report: report)
        inserter.isSecureInputActive = { true }
        inserter.insert(text: "password-ish")
        XCTAssertEqual(report.snapshot.first?.outcome, .secureInput)
    }

    func test_reportIsBounded() {
        let report = CompatibilityReport()
        report.isEnabled = true
        let event = CompatibilityEvent(date: Date(), bundleID: "a", appName: nil, appVersion: nil,
                                       appClass: .native, reason: "r", override: .automatic,
                                       outcome: .typed, multiLine: false)
        for _ in 0..<(CompatibilityReport.capacity + 25) { report.record(event) }
        XCTAssertEqual(report.snapshot.count, CompatibilityReport.capacity)
    }

    func test_emptyReportSaysHowToFillIt() {
        let text = CompatibilityReport.render(events: [], speakfreeVersion: "1", macOSVersion: "2")
        XCTAssertTrue(text.contains("No insertions recorded yet"))
        XCTAssertTrue(text.contains("No dictated text"))
    }

    // MARK: - Config and Settings round-trip (scratch config dir only)

    func test_configRoundTripsOverridesAndReportFlag() throws {
        var config = Config.defaultConfig
        config.insertionOverrides = ["com.example.app": .paste, "com.apple.Terminal": .type]
        config.compatibilityReport = FlexBool(true)
        try config.save()
        XCTAssertTrue(Config.configFile.path.hasPrefix(tempDir.path), "must write only the scratch dir")

        let loaded = Config.load()
        XCTAssertEqual(loaded.insertionOverrides, ["com.example.app": .paste, "com.apple.Terminal": .type])
        XCTAssertEqual(loaded.compatibilityReport?.value, true)
    }

    func test_unknownMethodStringDecodesAsAutomaticAndIsDropped() throws {
        let json = """
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base","language":"en",
         "insertionOverrides":{"com.a":"paste","com.b":"telepathy","com.c":"automatic"}}
        """
        let config = try Config.decode(from: Data(json.utf8))
        XCTAssertNil(config.insertionOverrides?["com.b"])
        XCTAssertEqual(config.insertionOverrides?.unknown, ["com.b": "telepathy"])
        XCTAssertEqual(config.effectiveInsertionOverrides, ["com.a": .paste])
    }

    /// A method written by a newer build survives a Settings save in this build, and the value
    /// stays a plain JSON object.
    func test_unknownMethodsSurviveASettingsSave() throws {
        let json = """
        {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base","language":"en",
         "insertionOverrides":{"com.future":"telepathy","com.a":"paste"}}
        """
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: Config.configFile)
        let vm = SettingsViewModel()
        vm.setInsertionOverride(.type, for: "com.other")
        let saved = try String(contentsOf: Config.configFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"com.future\" : \"telepathy\""), saved)
        let object = try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any]
        XCTAssertEqual(object?["insertionOverrides"] as? [String: String],
                       ["com.future": "telepathy", "com.a": "paste", "com.other": "type"])
        // Choosing a method for that app here replaces the unknown entry.
        vm.setInsertionOverride(.paste, for: "COM.FUTURE")
        let again = try JSONSerialization.jsonObject(with: Data(contentsOf: Config.configFile)) as? [String: Any]
        XCTAssertEqual(again?["insertionOverrides"] as? [String: String],
                       ["COM.FUTURE": "paste", "com.a": "paste", "com.other": "type"])
    }

    func test_legacyConfigWithoutTheKeysHasNoOverrides() throws {
        let json = #"{"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"base","language":"en"}"#
        let config = try Config.decode(from: Data(json.utf8))
        XCTAssertNil(config.insertionOverrides)
        XCTAssertEqual(config.effectiveInsertionOverrides, [:])
        XCTAssertNil(config.compatibilityReport)
    }

    func test_settingsViewModelSavesAndClearsAnOverride() {
        let vm = SettingsViewModel(config: Config.defaultConfig)
        vm.setInsertionOverride(.paste, for: "com.example.App")
        XCTAssertEqual(Config.load().insertionOverrides, ["com.example.App": .paste])

        // Same app, different letter case: replaces, does not duplicate.
        vm.setInsertionOverride(.type, for: "com.example.app")
        XCTAssertEqual(Config.load().insertionOverrides, ["com.example.app": .type])

        vm.setInsertionOverride(.automatic, for: "COM.EXAMPLE.APP")
        XCTAssertNil(Config.load().insertionOverrides, "Automatic removes the entry")
    }

    func test_settingsViewModelSavesReportFlagAndKeepsOverridesAcrossRefresh() {
        let vm = SettingsViewModel(config: Config.defaultConfig)
        vm.compatibilityReportEnabled = true
        vm.setInsertionOverride(.accessibility, for: "com.example.remote")
        vm.refreshFromDisk()
        XCTAssertTrue(vm.compatibilityReportEnabled)
        XCTAssertEqual(vm.insertionOverrides, ["com.example.remote": .accessibility])
        XCTAssertEqual(Config.load().compatibilityReport?.value, true)
    }

    // MARK: - Round-1 review regressions (2026-09-24)

    func test_crlfCountsAsALineBreak() {
        XCTAssertTrue(AppCompatibility.hasLineBreak("a\r\nb"))
        XCTAssertTrue(AppCompatibility.hasLineBreak("a\rb"))
        XCTAssertFalse(AppCompatibility.hasLineBreak("a b"))
    }

    func test_crlfIsNeverTypedIntoATerminal() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.Terminal",
                                           overrides: ["com.apple.Terminal": .type])
        inserter.insert(text: "make\r\nmake install")
        XCTAssertTrue(rec.typed.isEmpty)
        XCTAssertEqual(rec.pasted, ["make\r\nmake install"])
    }

    func test_editorsWithTerminalPanesNeverGetTypedLineBreaks() {
        for id in ["dev.zed.Zed", "com.jetbrains.intellij", "com.microsoft.VSCode",
                   "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"] {
            let (inserter, rec) = makeInserter(bundleID: id, overrides: [id: .type])
            inserter.insert(text: "npm test\nnpm run build")
            XCTAssertTrue(rec.typed.isEmpty, id)
            XCTAssertEqual(rec.pasted, ["npm test\nnpm run build"], id)
            inserter.insert(text: "single line")
            XCTAssertEqual(rec.typed, ["single line"], "single-line Type still types in \(id)")
        }
        // Route table agrees when told the app has a terminal pane.
        XCTAssertEqual(AppCompatibility.route(for: .listedPaste, override: .type, textHasLineBreak: true,
                                              lineBreaksUnsafe: true), .paste)
        XCTAssertTrue(AppCompatibility.typedLineBreaksUnsafe(appClass: .listedPaste, bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(AppCompatibility.typedLineBreaksUnsafe(appClass: .listedPaste, bundleID: "com.tinyspeck.slackmacgap"))
    }

    /// Large clipboard: the paste route falls back to typing to protect the clipboard item. For
    /// an editor with a terminal pane and a multi-line dictation, that typing must be refused and
    /// the text shown to the user instead, with the clipboard untouched.
    func test_largeClipboardFallbackNeverTypesLineBreaksIntoTerminalPanes() throws {
        let report = CompatibilityReport()
        report.isEnabled = true
        let (inserter, rec) = makeInserter(bundleID: "dev.zed.Zed", report: report)
        inserter.performPaste = nil  // exercise the real pasteViaClipboard size guard
        let big = Data(count: TextInserter.maxRestorableClipboardBytes + 1)
        inserter.pasteboard.clearContents()
        inserter.pasteboard.setData(big, forType: NSPasteboard.PasteboardType("com.example.big"))
        let before = inserter.pasteboard.changeCount
        var shown: [String] = []
        inserter.onRemoteInsertionFailure = { text, _ in shown.append(text) }
        inserter.insert(text: "cd repo\ngit push")
        XCTAssertTrue(rec.typed.isEmpty, "no typed line break")
        XCTAssertEqual(shown, ["cd repo\ngit push"])
        XCTAssertEqual(inserter.pasteboard.changeCount, before, "clipboard left unchanged")
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed])

        // Single line into the same app: typed, and the report says typed, not pasted.
        inserter.insert(text: "git status")
        XCTAssertEqual(rec.typed, ["git status"])
        XCTAssertEqual(report.snapshot.last?.outcome, .typed)
        XCTAssertEqual(report.snapshot.count, 2)
    }

    func test_failedRemoteDeliveryIsReportedOnceAsFailed() {
        let report = CompatibilityReport()
        report.isEnabled = true
        let (inserter, _) = makeInserter(bundleID: "com.philandro.anydesk", report: report)
        inserter.performRemoteInsertion = nil
        inserter.executeAppleScript = { _ in ["NSAppleScriptErrorNumber": -1743] }
        var shown = 0
        inserter.onRemoteInsertionFailure = { _, _ in shown += 1 }
        inserter.insert(text: "hello remote")
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed])
        // The next successful insertion is still recorded.
        inserter.executeAppleScript = { _ in nil }
        inserter.insert(text: "hello again")
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed, .remoteTyped])
    }

    func test_commonWordURLSchemesAreNotRemoteSignals() {
        for scheme in ["receiver", "screens", "jump", "workspaces", "nx", "spice", "ard"] {
            XCTAssertEqual(classOf("com.example.local", schemes: [scheme]), .native, scheme)
        }
    }

    func test_cefUnderAnotherNameStaysNative() throws {
        // DaVinci Resolve ships CEF as "ChromiumEmbeddedFramework.framework" for a side panel;
        // its editor fields are Qt widgets.
        let url = try makeBundle(id: "com.example.resolve", frameworks: ["ChromiumEmbeddedFramework.framework"],
                                 chromiumMarkerIn: "ChromiumEmbeddedFramework.framework")
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.resolve", bundleURL: url).appClass, .native)
    }

    func test_failedProbeIsNotCached() throws {
        let url = tempDir.appendingPathComponent("Later.app")
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.later", bundleURL: url).appClass, .native)
        // The app appears (or finishes updating): the next classification sees it.
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info(id: "com.example.later", schemes: ["vnc"]), format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.later", bundleURL: url).appClass, .remoteDesktop)
    }

    func test_appUpdatedInPlaceIsReclassified() throws {
        let url = try makeBundle(id: "com.example.updated")
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.updated", bundleURL: url).appClass, .native)
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info(id: "com.example.updated", schemes: ["rdp"]), format: .xml, options: 0)
        try plist.write(to: plistURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: plistURL.path)
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.example.updated", bundleURL: url).appClass,
                       .remoteDesktop)
    }

    /// A hand-edited overrides value of the wrong shape must not reset the rest of config.
    func test_malformedOverridesDoNotResetConfig() throws {
        let json = """
        {"hotkey":{"keyCode":61,"modifiers":[]},"modelSize":"base","language":"de",
         "insertionOverrides":["com.a","paste"]}
        """
        let config = try Config.decode(from: Data(json.utf8))
        XCTAssertEqual(config.language, "de")
        XCTAssertEqual(config.hotkey.keyCode, 61)
        XCTAssertEqual(config.effectiveInsertionOverrides, [:])
    }

    // MARK: - Round-2 review regressions (2026-09-24)

    /// Automatic fallbacks never type a line break, even into an app classified native: it may
    /// be an unknown terminal.
    func test_nativeChainPastesMultiLineInsteadOfTyping() {
        let (inserter, rec) = makeInserter(bundleID: "com.example.unknownterm")
        inserter.insert(text: "cd repo\ngit push")
        XCTAssertTrue(rec.typed.isEmpty)
        XCTAssertEqual(rec.pasted, ["cd repo\ngit push"])
    }

    /// An explicit Type choice on a native app still types line breaks (as Shift+Return).
    func test_explicitTypeOnANativeAppTypesLineBreaks() {
        let (inserter, rec) = makeInserter(bundleID: "com.example.notes",
                                           overrides: ["com.example.notes": .type])
        inserter.insert(text: "line one\nline two")
        XCTAssertEqual(rec.typed, ["line one\nline two"])
    }

    /// An unlisted VS Code fork (web runtime, found on disk) never gets typed line breaks.
    func test_unlistedWebRuntimeNeverGetsTypedLineBreaks() throws {
        let url = try makeBundle(id: "com.vscodium", frameworks: ["Electron Framework.framework"])
        let (inserter, rec) = makeInserter(bundleID: "com.vscodium", overrides: ["com.vscodium": .type])
        inserter.frontmostBundleURLProvider = { url }
        XCTAssertEqual(inserter.frontmostProfile().appClass, .webRuntime)
        inserter.insert(text: "npm test\nnpm run build")
        XCTAssertTrue(rec.typed.isEmpty)
        XCTAssertEqual(rec.pasted, ["npm test\nnpm run build"])
    }

    func test_trailingLineBreakIsDroppedForTerminals() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.Terminal")
        inserter.insert(text: "ls -la\n")
        XCTAssertTrue(inserter.insert(text: "\r\n"), "a bare break is nothing to insert, not a failure")
        XCTAssertEqual(rec.pasted, ["ls -la"], "trailing break dropped; a bare break inserts nothing")
    }

    /// The maintainer, 2026-09-24: "I mean drop it everywhere." A dictation that ends in a spoken
    /// "new line" / "new paragraph" never ends in a line break, whatever the app and route.
    func test_trailingLineBreakIsDroppedInEveryApp() {
        let (slack, slackRec) = makeInserter(bundleID: "com.tinyspeck.slackmacgap")
        slack.insert(text: "hello\n")
        slack.insert(text: "first\nsecond\n\n")
        XCTAssertEqual(slackRec.pasted, ["hello", "first\nsecond"], "middle breaks kept")

        let (textEdit, textEditRec) = makeInserter(bundleID: "com.apple.TextEdit")
        textEdit.insert(text: "notes\n")
        XCTAssertEqual(textEditRec.typed + textEditRec.pasted, ["notes"])

        let (typed, typedRec) = makeInserter(bundleID: "com.apple.TextEdit",
                                             overrides: ["com.apple.TextEdit": .type])
        typed.insert(text: "a\nb\n")
        XCTAssertEqual(typedRec.typed, ["a\nb"])

        let (remote, remoteRec) = makeInserter(bundleID: "com.philandro.anydesk")
        remote.insert(text: "hi\n")
        XCTAssertEqual(remoteRec.remote, ["hi"], "one line again, so it is typed, not pasted")
    }

    /// Review round 2: the remembered cursor tail must match what was inserted, or the next
    /// dictation into a web app (which reads the tail, not the live field) loses its space.
    func test_rememberedTailOmitsTheDroppedLineBreak() {
        let tail = AppDelegate.insertionTail(contextBefore: "Hi. ", inserted: "Sounds good\n")
        XCTAssertEqual(tail, "Hi. Sounds good")
        XCTAssertTrue(TextInserter.shouldPrependSpace(contextBefore: tail))
        XCTAssertEqual(AppDelegate.insertionTail(contextBefore: nil, inserted: "a\nb"), "a\nb")
    }

    func test_trimmingTrailingLineBreaks() {
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("a\nb\r\n\n"), "a\nb")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("hi \n"), "hi")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("hi\n \t"), "hi")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("end\u{2028}"), "end")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("hi\n\u{00A0}"), "hi")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("hi\u{0085}"), "hi")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("keep nbsp\u{00A0}"), "keep nbsp\u{00A0}")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("keep trailing space "), "keep trailing space ")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("\nlead"), "\nlead")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks("\n\n"), "")
        XCTAssertEqual(AppCompatibility.trimmingTrailingLineBreaks(""), "")
    }

    private func makeRemotePasteInserter(report: CompatibilityReport) -> TextInserter {
        let (inserter, _) = makeInserter(bundleID: "com.philandro.anydesk", report: report)
        inserter.performRemoteInsertion = nil
        inserter.onRemoteInsertionFailure = { _, _ in }
        return inserter
    }

    /// Multi-line text to a viewer goes by clipboard plus a delayed System Events ⌘V. The report
    /// row is written when the ⌘V is actually sent, for the viewer, exactly once.
    func test_delayedRemotePasteIsRecordedOnceWhenSent() {
        let report = CompatibilityReport()
        report.isEnabled = true
        let inserter = makeRemotePasteInserter(report: report)
        let sent = expectation(description: "remote paste sent")
        inserter.executeAppleScript = { source in
            XCTAssertTrue(source.contains("keystroke \"v\" using command down"))
            sent.fulfill()
            return nil
        }
        inserter.insert(text: "line one\nline two")
        XCTAssertTrue(report.snapshot.isEmpty, "nothing recorded before the paste is sent")
        wait(for: [sent], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.main.async { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertEqual(report.snapshot.map(\.outcome), [.remotePasted])
        XCTAssertEqual(report.snapshot.first?.bundleID, "com.philandro.anydesk")
    }

    /// If the frontmost app changes before the delayed ⌘V, the failure is recorded once, against
    /// the viewer (not the app now in front), and the next insertion is still recorded.
    func test_delayedRemotePasteFailureIsRecordedAgainstTheViewer() {
        let report = CompatibilityReport()
        report.isEnabled = true
        let inserter = makeRemotePasteInserter(report: report)
        inserter.executeAppleScript = { _ in XCTFail("no paste into a changed app"); return nil }
        let failed = expectation(description: "late failure")
        inserter.onRemoteInsertionFailure = { _, _ in failed.fulfill() }
        inserter.insert(text: "line one\nline two")
        inserter.frontmostBundleIDProvider = { "com.tinyspeck.slackmacgap" }
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed])
        XCTAssertEqual(report.snapshot.first?.bundleID, "com.philandro.anydesk")

        let (_, rec) = (inserter, Recorder())
        inserter.performPaste = { rec.pasted.append($0) }
        inserter.insert(text: "next")
        XCTAssertEqual(report.snapshot.map(\.outcome), [.deliveryFailed, .pasted])
        XCTAssertEqual(report.snapshot.last?.bundleID, "com.tinyspeck.slackmacgap")
    }

    /// Round 3 minor: an Accessibility override on a terminal, reaching the refocus closure's
    /// paste after a failed AX write, also drops the trailing line break.
    func test_refocusPasteIntoTerminalDropsTrailingLineBreak() {
        let (inserter, rec) = makeInserter(bundleID: "com.apple.Terminal",
                                           overrides: ["com.apple.Terminal": .accessibility])
        let target = simulateSuccessfulRefocus(inserter)
        inserter.directAXInsert = { _, _ in false }
        let done = expectation(description: "paste after refocus")
        inserter.performPaste = { rec.pasted.append($0); done.fulfill() }
        inserter.insert(text: "make\n", refocusing: target)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(rec.pasted, ["make"])
    }

    func test_citrixLauncherIsNotARemoteViewer() {
        XCTAssertEqual(classOf("com.citrix.receiver.nomas"), .native)
        XCTAssertEqual(classOf("com.citrix.receiver.icaviewer.mac"), .remoteDesktop)
    }

    func test_renamedChromiumAvoidsLiveWindowContextButBrowsersDoNot() throws {
        TextInserter.resetChromiumProbeCache()
        let app = try makeBundle(id: "com.example.renamedchromium", frameworks: ["Codex Framework.framework"],
                                 chromiumMarkerIn: "Codex Framework.framework")
        XCTAssertTrue(TextInserter.shouldAvoidLiveWindowContext(bundleID: "com.example.renamedchromium", bundleURL: app))
        let browser = try makeBundle(id: "com.example.chromiumbrowser", schemes: ["http", "https"], html: true,
                                     frameworks: ["Browser Framework.framework"],
                                     chromiumMarkerIn: "Browser Framework.framework")
        XCTAssertFalse(TextInserter.shouldAvoidLiveWindowContext(bundleID: "com.example.chromiumbrowser", bundleURL: browser))
        TextInserter.resetChromiumProbeCache()
    }
}
