// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import SwiftUI
import XCTest
@testable import SpeakFreeLib

/// Unshown native windows, scratch configuration, and synthetic data only.
final class SettingsSidebarTests: XCTestCase {
    func testSidebarNavigationPreservesConfigAndExternalClipboardSelection() throws {
        try withFixture { model, scratch in
            try model.toConfig().save()
            let configURL = scratch.appendingPathComponent("config.json")
            let before = try Data(contentsOf: configURL)
            let host = NSHostingView(rootView: SettingsView(viewModel: model, isReview: true))
            let window = makeWindow(host, size: NSSize(width: 800, height: 500), appearance: .aqua)
            defer { window.orderOut(nil) }

            // History's Preferences button changes this existing binding directly.
            // Rebuilding the detail must neither reset that route nor save UI navigation.
            for tab in [SettingsTab.clipboard, .dictation, .clipboard] {
                model.selectedSettingsTab = tab
                settle(host)
                XCTAssertEqual(model.selectedSettingsTab, tab)
                XCTAssertEqual(try Data(contentsOf: configURL), before)
                XCTAssertEqual(model.keyMode, .edit)
                XCTAssertEqual(model.historySettings.retention, .week)
                let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
                XCTAssertFalse(scrollViews.isEmpty, "Preferences must remain scrollable in a short window")
                for scroll in scrollViews {
                    if let document = scroll.documentView {
                        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1,
                                                 "A settings section must not require horizontal scrolling")
                    }
                }
            }
        }
    }

    func testRenderSidebarPreferences() throws {
        guard let path = ProcessInfo.processInfo.environment["PREFERENCES_RENDER_DIR"] else {
            throw XCTSkip("PREFERENCES_RENDER_DIR is not set; synthetic render harness runs on demand")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try withFixture { model, _ in
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for tab in SettingsTab.allCases {
                    model.selectedSettingsTab = tab
                    try render(model, size: NSSize(width: 860, height: 760), appearance: appearance,
                               to: output.appendingPathComponent("preferences-\(tab.title.lowercased())-\(name)_AI_.png"))
                    try render(model, size: NSSize(width: 800, height: 500), appearance: appearance,
                               to: output.appendingPathComponent("preferences-\(tab.title.lowercased())-compact-\(name)_AI_.png"))
                    try render(model, size: NSSize(width: 800, height: 500), appearance: appearance,
                               to: output.appendingPathComponent("preferences-\(tab.title.lowercased())-bottom-\(name)_AI_.png"),
                               scrollToBottom: true)
                }
            }
        }
        try """
        <!-- ai-suggestion:unverified | session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b | date:2026-10-01 -->
        All preferences-*_AI_.png images in this directory are synthetic native SettingsView
        renders from SettingsSidebarTests, at 860×760 and 800×500 points, in light and dark.
        No real configuration, dictations, or clipboard content was read. Windows were never
        shown or activated. Appearance assessment is unverified until independent review.
        """.write(to: output.appendingPathComponent("PROVENANCE_AI_.md"), atomically: true, encoding: .utf8)
    }

    private func withFixture(_ body: (SettingsViewModel, URL) throws -> Void) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("speakfree-prefs-sidebar-AI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldOverride = Config.configDirOverride
        let oldDevMode = ProcessInfo.processInfo.environment["SPEAKFREE_DEV_MODE"]
        Config.configDirOverride = scratch
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        defer {
            Config.configDirOverride = oldOverride
            if let oldDevMode { setenv("SPEAKFREE_DEV_MODE", oldDevMode, 1) }
            else { unsetenv("SPEAKFREE_DEV_MODE") }
        }
        var config = Config.defaultConfig
        config.hotkey = HotkeyConfig(keyCode: 61, modifiers: [])
        config.keyMode = .edit
        config.editModeCleanup = FlexBool(false)
        config.saveRecordings = FlexBool(false)
        config.history = HistorySettings()
        config.history?.retention = .week
        config.history?.includeClipboard = false
        try body(SettingsViewModel(config: config), scratch)
    }

    private func makeWindow<V: View>(_ host: NSHostingView<V>, size: NSSize,
                                    appearance: NSAppearance.Name) -> NSWindow {
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        settle(host)
        return window
    }

    private func settle(_ host: NSView) {
        host.window?.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
    }

    private func render(_ model: SettingsViewModel, size: NSSize, appearance: NSAppearance.Name,
                        to url: URL, scrollToBottom: Bool = false) throws {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let host = NSHostingView(rootView: SettingsView(viewModel: model, isReview: true)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active))
        let window = makeWindow(host, size: size, appearance: appearance)
        defer { window.orderOut(nil) }
        if scrollToBottom {
            let scroll = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSScrollView }
                .max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }))
            let document = try XCTUnwrap(scroll.documentView)
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
        }
        host.display()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
