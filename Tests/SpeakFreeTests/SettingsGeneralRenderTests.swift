// Claude · 2026-07-26 · Session: ec24b5ef-be6a-4c4b-be38-a3b84ca63074
//
// Artifact generator, not an assertion suite (same pattern as HUDVariantRenderTests):
// renders the Settings window's General section so the Globe-key banner and the dev-mode
// recordings checkbox can be reviewed visually. Skips unless SETTINGS_RENDER_DIR is set.
//
// Writes NOTHING to the real config: Config.configDirOverride is set to a scratch dir for the
// duration, per the worktree-safety rule (a test once overwrote the live config.json).

import XCTest
import AppKit
import SwiftUI
@testable import SpeakFreeLib

final class SettingsGeneralRenderTests: XCTestCase {

    func test_renderGeneralSectionStates() throws {
        guard let outDir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("SETTINGS_RENDER_DIR not set — render harness only runs on demand")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-settings-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        defer {
            Config.configDirOverride = nil
            try? FileManager.default.removeItem(at: scratch)
            unsetenv("SPEAKFREE_DEV_MODE")
        }

        // (name, hotkey, toggleMode, devMode) — the four states that matter.
        let cases: [(String, UInt16, Bool, Bool)] = [
            ("fn-hold-stock", KeyCodes.fnKeyCode, false, false),
            ("fn-toggle-banner", KeyCodes.fnKeyCode, true, false),
            ("rightoption-toggle-no-banner", KeyCodes.rightOptionKeyCode, true, false),
            ("fn-toggle-devmode", KeyCodes.fnKeyCode, true, true),
        ]

        for (name, keyCode, toggle, dev) in cases {
            setenv("SPEAKFREE_DEV_MODE", dev ? "1" : "0", 1)

            var config = Config.defaultConfig
            config.hotkey = HotkeyConfig(keyCode: keyCode, modifiers: [])
            config.toggleMode = FlexBool(toggle)
            config.saveRecordings = FlexBool(false)

            let viewModel = SettingsViewModel(config: config)
            let host = NSHostingView(rootView: SettingsView(viewModel: viewModel))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
            // A window is required for SwiftUI to lay out and draw.
            let window = NSWindow(contentRect: host.frame,
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            host.display()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: URL(fileURLWithPath: outDir)
                .appendingPathComponent("\(name).png"))
        }
    }
}
