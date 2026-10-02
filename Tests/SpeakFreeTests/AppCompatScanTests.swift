// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// `speakfree compat scan` and the detection rules it prompted: RDP/VNC client libraries,
// terminal libraries inside Electron apps, and browser app shims. Every bundle here is a
// synthetic fixture in a scratch folder; nothing reads the real /Applications.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class AppCompatScanTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree.compatscan.\(UUID().uuidString)")
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

    /// A fixture .app: Info.plist, optional frameworks (folders or plain dylib files), optional
    /// node_modules entries under `modulesFolder`.
    @discardableResult
    private func makeApp(_ name: String, id: String?, in folder: URL? = nil,
                         schemes: [String] = [], frameworks: [String] = [],
                         modules: [String] = [],
                         modulesFolder: String = "Contents/Resources/app.asar.unpacked/node_modules",
                         displayName: String? = nil) throws -> URL {
        let fm = FileManager.default
        let app = (folder ?? tempDir).appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [:]
        if let id { info["CFBundleIdentifier"] = id }
        info["CFBundleName"] = name
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if !schemes.isEmpty { info["CFBundleURLTypes"] = [["CFBundleURLSchemes": schemes]] }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if !frameworks.isEmpty {
            let fw = contents.appendingPathComponent("Frameworks")
            try fm.createDirectory(at: fw, withIntermediateDirectories: true)
            for f in frameworks {
                if f.hasSuffix(".dylib") {
                    try Data().write(to: fw.appendingPathComponent(f))
                } else {
                    try fm.createDirectory(at: fw.appendingPathComponent(f), withIntermediateDirectories: true)
                }
            }
        }
        for module in modules {
            try fm.createDirectory(at: app.appendingPathComponent(modulesFolder).appendingPathComponent(module),
                                   withIntermediateDirectories: true)
        }
        return app
    }

    private func classify(_ url: URL, id: String) -> AppClassification {
        AppCompatibility.classify(bundleID: id, bundleURL: url)
    }

    // MARK: - Rules found by the scan

    func test_rdpClientWithoutAnRDPSchemeIsRemoteByItsLibrary() throws {
        let freerdp = try makeApp("RDP One", id: "com.example.rdpone",
                                  frameworks: ["libfreerdp-client3.3.16.1.dylib", "libz.dylib"])
        let winpr = try makeApp("RDP Two", id: "com.example.rdptwo", frameworks: ["libwinpr3.dylib"])
        let framework = try makeApp("RDP Three", id: "com.example.rdpthree", frameworks: ["MacFreeRDP.framework"])
        let vnc = try makeApp("VNC", id: "com.example.screenviewer", frameworks: ["libvncclient.1.dylib"])
        for (url, id) in [(freerdp, "com.example.rdpone"), (winpr, "com.example.rdptwo"),
                          (framework, "com.example.rdpthree"), (vnc, "com.example.screenviewer")] {
            let result = classify(url, id: id)
            XCTAssertEqual(result.appClass, .remoteDesktop, id)
            XCTAssertTrue(result.reason.contains("remote desktop library"), result.reason)
        }
    }

    func test_ordinaryDylibsDoNotMakeAnAppRemote() throws {
        let url = try makeApp("Plain", id: "com.example.plain",
                              frameworks: ["libz.dylib", "Sparkle.framework", "libssl.3.dylib"])
        XCTAssertEqual(classify(url, id: "com.example.plain").appClass, .native)
    }

    func test_hopToDeskSchemeIsRemote() {
        let result = AppCompatibility.classify(
            bundleID: "com.example.fork",
            info: ["CFBundleIdentifier": "com.example.fork", "CFBundleURLTypes": [["CFBundleURLSchemes": ["hoptodesk"]]]],
            frameworks: nil)
        XCTAssertEqual(result.appClass, .remoteDesktop)
    }

    func test_iPhoneMirroringIsRemote() {
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.apple.ScreenContinuity", info: nil, frameworks: nil).appClass,
                       .remoteDesktop)
    }

    func test_electronAppShippingNodePtyHasATerminalPane() throws {
        let url = try makeApp("Agents", id: "com.example.agents",
                              frameworks: ["Electron Framework.framework"], modules: ["node-pty", "sharp"])
        let result = classify(url, id: "com.example.agents")
        XCTAssertEqual(result.appClass, .webRuntime)
        XCTAssertTrue(result.hasTerminalPane)
        XCTAssertTrue(result.reason.contains("node-pty"), result.reason)
    }

    func test_scopedNodePtyForkIsFound() throws {
        let url = try makeApp("Scoped", id: "com.example.scoped",
                              frameworks: ["Electron Framework.framework"],
                              modules: ["@lydell/node-pty-darwin-arm64", "@img/sharp"])
        XCTAssertTrue(classify(url, id: "com.example.scoped").hasTerminalPane)
    }

    func test_unpackedXtermInAppFolderIsFound() throws {
        let url = try makeApp("Editor", id: "com.example.editor",
                              frameworks: ["Electron Framework.framework"],
                              modules: ["@xterm/xterm", "@vscode/ripgrep"],
                              modulesFolder: "Contents/Resources/app/node_modules")
        XCTAssertTrue(classify(url, id: "com.example.editor").hasTerminalPane)
    }

    func test_electronAppWithoutATerminalLibraryHasNoTerminalPane() throws {
        let url = try makeApp("Video", id: "com.electron.videotool",
                              frameworks: ["Electron Framework.framework"], modules: ["syphon", "@sentry/node"])
        let result = classify(url, id: "com.electron.videotool")
        XCTAssertEqual(result.appClass, .webRuntime)
        XCTAssertFalse(result.hasTerminalPane)
    }

    func test_terminalPaneFlagMakesLineBreaksSafe() {
        XCTAssertTrue(AppCompatibility.typedLineBreaksUnsafe(appClass: .listedPaste, bundleID: "com.example.chat",
                                                             hasTerminalPane: true))
        XCTAssertFalse(AppCompatibility.typedLineBreaksUnsafe(appClass: .native, bundleID: "com.example.chat"))
    }

    /// End to end through the inserter: an unlisted Electron app with node-pty never gets a
    /// trailing line break pasted (it could run the line in a shell pane).
    func test_inserterDropsTrailingLineBreakForAnUnlistedAppWithAShellPane() throws {
        let url = try makeApp("Agents", id: "com.example.agents2",
                              frameworks: ["Electron Framework.framework"], modules: ["node-pty"])
        var pasted: [String] = []
        let inserter = TextInserter()
        inserter.frontmostBundleIDProvider = { "com.example.agents2" }
        inserter.frontmostBundleURLProvider = { url }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.compatibilityReport = CompatibilityReport()
        inserter.performPaste = { pasted.append($0) }
        inserter.performUnicodeInsertion = { _ in XCTFail("must not type"); return true }
        inserter.pasteboard = NSPasteboard(name: .init("speakfree.test.compatscan.\(UUID().uuidString)"))
        addTeardownBlock { inserter.pasteboard.releaseGlobally() }
        inserter.insert(text: "npm test\n")
        XCTAssertEqual(pasted, ["npm test"])
    }

    /// Review round 1: a Type setting on an app with a shell pane still pastes line breaks,
    /// whatever its class.
    func test_typeOverrideOnAnAppWithAShellPanePastesLineBreaks() throws {
        let url = try makeApp("Chatty", id: "com.example.chatty", modules: ["node-pty"])
        let classification = classify(url, id: "com.example.chatty")
        XCTAssertEqual(classification.appClass, .native)
        XCTAssertTrue(classification.hasTerminalPane)
        var pasted: [String] = [], typed: [String] = []
        let inserter = TextInserter()
        inserter.frontmostBundleIDProvider = { "com.example.chatty" }
        inserter.frontmostBundleURLProvider = { url }
        inserter.frontmostPIDProvider = { 999_999 }
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.insertionOverrides = ["com.example.chatty": .type]
        inserter.compatibilityReport = CompatibilityReport()
        inserter.performPaste = { pasted.append($0) }
        inserter.performUnicodeInsertion = { typed.append($0); return true }
        inserter.pasteboard = NSPasteboard(name: .init("speakfree.test.compatscan.\(UUID().uuidString)"))
        addTeardownBlock { inserter.pasteboard.releaseGlobally() }
        inserter.insert(text: "one\ntwo")
        XCTAssertEqual(pasted, ["one\ntwo"])
        XCTAssertTrue(typed.isEmpty)
        inserter.insert(text: "single line")
        XCTAssertEqual(typed, ["single line"], "single lines still type as chosen")
    }

    /// Review round 1: the remote-library rule sits after the named terminals but before ssh://.
    func test_remoteLibraryRuleOrdering() throws {
        let terminal = try makeApp("Term", id: "com.googlecode.iterm2", frameworks: ["libfreerdp2.dylib"])
        XCTAssertEqual(classify(terminal, id: "com.googlecode.iterm2").appClass, .terminal)
        let manager = try makeApp("Manager", id: "com.example.connections", schemes: ["ssh"],
                                  frameworks: ["libfreerdp2.dylib"])
        XCTAssertEqual(classify(manager, id: "com.example.connections").appClass, .remoteDesktop)
        let sshOnly = try makeApp("SSH", id: "com.example.sshonly", schemes: ["ssh"])
        XCTAssertEqual(classify(sshOnly, id: "com.example.sshonly").appClass, .terminal)
    }

    func test_browserAppShimIsLabelled() {
        let shim = AppCompatibility.classify(bundleID: "com.google.Chrome.app.abcdef", info: nil, frameworks: nil)
        XCTAssertEqual(shim.appClass, .browser)
        XCTAssertEqual(shim.reason, "web app installed from a browser")
        XCTAssertEqual(AppCompatibility.classify(bundleID: "com.google.Chrome", info: nil, frameworks: nil).reason,
                       "known browser")
    }

    func test_terminalsKeepTheirClassEvenWithNodePty() throws {
        let url = try makeApp("Hyperish", id: "co.zeit.hyper",
                              frameworks: ["Electron Framework.framework"], modules: ["node-pty"])
        let result = classify(url, id: "co.zeit.hyper")
        XCTAssertEqual(result.appClass, .terminal)
        XCTAssertFalse(result.reason.contains("terminal pane"))
    }

    // MARK: - The scan itself

    func test_scanFindsAppsOneFolderDownAndSkipsBundlesWithoutAnID() throws {
        let apps = tempDir.appendingPathComponent("Applications")
        let utilities = apps.appendingPathComponent("Utilities")
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
        try makeApp("Top", id: "com.example.top", in: apps)
        try makeApp("Nested", id: "com.example.nested", in: utilities, schemes: ["ssh"])
        try makeApp("NoID", id: nil, in: apps)
        // Two levels down is not scanned (that is inside a vendor folder's subfolder).
        let deep = utilities.appendingPathComponent("Deeper")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try makeApp("Deep", id: "com.example.deep", in: deep)

        let rows = AppCompatScan.scan(folders: [apps])
        XCTAssertEqual(Set(rows.map(\.bundleID)), ["com.example.top", "com.example.nested"])
        let nested = try XCTUnwrap(rows.first { $0.bundleID == "com.example.nested" })
        XCTAssertEqual(nested.appClass, .terminal)
        XCTAssertEqual(nested.route, "Paste")
    }

    func test_scanReportsOneRowPerBundleIDAndTheRoutes() throws {
        let a = tempDir.appendingPathComponent("A"), b = tempDir.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try makeApp("Same", id: "com.example.same", in: a)
        try makeApp("Same", id: "COM.EXAMPLE.SAME", in: b)
        try makeApp("Viewer", id: "com.example.viewer", in: a, schemes: ["vnc"])
        let rows = AppCompatScan.scan(folders: [a, b])
        XCTAssertEqual(rows.filter { $0.bundleID.lowercased() == "com.example.same" }.count, 1)
        let same = try XCTUnwrap(rows.first { $0.bundleID == "com.example.same" })
        XCTAssertEqual(same.route, "Accessibility")
        XCTAssertNil(same.multiLineRoute)
        let viewer = try XCTUnwrap(rows.first { $0.bundleID == "com.example.viewer" })
        XCTAssertEqual(viewer.route, "Remote keystrokes")
    }

    func test_markdownEscapesPipesAndCountsClasses() {
        let rows = [
            AppScanRow(bundleID: "com.example.a", name: "A | B", path: "/x", appClass: .native,
                       reason: "no special handling detected", route: "Accessibility", multiLineRoute: nil),
            AppScanRow(bundleID: "com.example.t", name: "T", path: "/y", appClass: .terminal,
                       reason: "known terminal", route: "Paste", multiLineRoute: nil),
        ]
        let md = AppCompatScan.renderMarkdown(rows)
        XCTAssertTrue(md.hasPrefix("2 apps scanned."))
        XCTAssertTrue(md.contains("- Native app: 1"))
        XCTAssertTrue(md.contains("- Terminal: 1"))
        XCTAssertTrue(md.contains("A \\| B"))
        XCTAssertEqual(AppCompatScan.renderTSV(rows).split(separator: "\n").count, 2)
    }
}
