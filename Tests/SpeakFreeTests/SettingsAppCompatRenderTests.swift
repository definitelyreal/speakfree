// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Artifact generator, not an assertion suite (same pattern as SettingsGeneralRenderTests):
// renders the whole Settings window tall enough to show the Advanced section's "Insertion by
// App" and "Compatibility Report" rows. Skips unless SETTINGS_RENDER_DIR is set. Writes nothing
// to the real config (Config.configDirOverride points at a scratch dir).

import XCTest
import AppKit
import SwiftUI
@testable import SpeakFreeLib

final class SettingsAppCompatRenderTests: XCTestCase {

    func test_renderAdvancedAppCompatRows() throws {
        guard let outDir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("SETTINGS_RENDER_DIR not set — render harness only runs on demand")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-appcompat-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        defer {
            Config.configDirOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }

        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(false)
        config.insertionOverrides = ["com.apple.Terminal": .type, "com.example.unknownviewer": .paste]
        config.compatibilityReport = FlexBool(true)

        let viewModel = SettingsViewModel(config: config)
        let host = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 3200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("advanced-appcompat.png"))
    }
}
