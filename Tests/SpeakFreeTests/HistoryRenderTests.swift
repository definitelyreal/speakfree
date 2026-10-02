// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core · 2026-10-01
// Opt-in artifact generator. Synthetic inputs only: no live clipboard, config, or recordings.
import AppKit
import SwiftUI
import XCTest
@testable import SpeakFreeLib

final class HistoryRenderTests: XCTestCase {
    func testRenderHistoryAndClipboardPreferences() throws {
        guard let directory = ProcessInfo.processInfo.environment["HISTORY_RENDER_DIR"] else {
            throw XCTSkip("HISTORY_RENDER_DIR is not set; synthetic render harness only runs on demand")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("speakfree-history-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldOverride = Config.configDirOverride
        Config.configDirOverride = scratch
        defer { Config.configDirOverride = oldOverride; try? FileManager.default.removeItem(at: scratch) }

        let model = HistoryPickerModel()
        model.pointerLocation = { NSPoint(x: 400, y: 300) }
        let image = NSImage(size: NSSize(width: 128, height: 80))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 128, height: 80), xRadius: 8, yRadius: 8).fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: 44, y: 20, width: 40, height: 40)).fill()
        image.unlockFocus()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.entries = [
            .init(createdAt: now.addingTimeInterval(-20), source: .dictation, items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("Let's meet Thursday and review the revised design together.".utf8))])]),
            .init(createdAt: now.addingTimeInterval(-80), source: .clipboard, items: [.init(representations: [
                .init(type: "public.tiff", data: try XCTUnwrap(image.tiffRepresentation))])]),
            .init(createdAt: now.addingTimeInterval(-120), source: .clipboard, items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("Design notes\n• Keep the interaction simple\n• Preserve formatting".utf8)),
                .init(type: "public.html", data: Data("<h1>Design notes</h1><p>Keep the interaction simple</p>".utf8))])]),
            .init(createdAt: now.addingTimeInterval(-180), source: .clipboard, items: [.init(representations: [
                .init(type: "public.file-url", data: Data("file:///synthetic/Design-notes.pdf".utf8))])])
        ]
        model.clipboardEnabled = true
        model.reconcileSelection()
        var config = Config.defaultConfig
        config.history = HistorySettings()
        config.history?.retention = .week
        config.history?.includeClipboard = true
        let settings = SettingsViewModel(config: config)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            model.keyboardFocus = .search
            try render(HistoryPickerView(model: model), size: model.preferredSize,
                       appearance: appearance, to: output.appendingPathComponent("history-\(name)_AI_.png"))
            model.selectedID = model.entries[2].id
            model.handle(.focusPlainText)
            try render(HistoryPickerView(model: model), size: model.preferredSize,
                       appearance: appearance, to: output.appendingPathComponent("history-plain-text-focus-\(name)_AI_.png"))
            model.handle(.cycleFilter(1))
            try render(HistoryPickerView(model: model), size: model.preferredSize,
                       appearance: appearance, to: output.appendingPathComponent("history-filter-focus-\(name)_AI_.png"))
            XCTAssertEqual(model.keyboardFocus, .filter(.dictation), "Rendering must preserve the keyboard focus target")
            model.filter = .clipboard
            model.clipboardEnabled = false
            try render(HistoryPickerView(model: model), size: model.preferredSize,
                       appearance: appearance, to: output.appendingPathComponent("history-disabled-\(name)_AI_.png"))
            model.fit(to: NSRect(x: 0, y: 0, width: 500, height: 250))
            model.status = "Copied. Press ⌘V in the app where you want it."
            try render(HistoryPickerView(model: model), size: model.preferredSize,
                       appearance: appearance, to: output.appendingPathComponent("history-short-disabled-\(name)_AI_.png"))
            model.fit(to: NSRect(x: 0, y: 0, width: 280, height: 210))
            try render(HistoryPickerView(model: model), size: NSSize(width: 280, height: model.preferredSize.height),
                       appearance: appearance, to: output.appendingPathComponent("history-narrow-disabled-\(name)_AI_.png"))
            model.fit(to: NSRect(x: 0, y: 0, width: 500, height: 250))
            model.clipboardEnabled = true
            model.filter = .all
            model.keyboardFocus = .search
            try render(HistoryPickerView(model: model), size: model.preferredSize,
                       appearance: appearance, to: output.appendingPathComponent("history-short-\(name)_AI_.png"))
            model.status = nil
            model.fit(to: NSRect(x: 0, y: 0, width: 1440, height: 900))
            try render(ClipboardSettingsView(viewModel: settings, isReview: true), size: NSSize(width: 720, height: 720),
                       appearance: appearance, to: output.appendingPathComponent("clipboard-preferences-\(name)_AI_.png"))
            try render(SettingsView(viewModel: settings, isReview: true), size: NSSize(width: 740, height: 740),
                       appearance: appearance, to: output.appendingPathComponent("settings-tabs-\(name)_AI_.png"))
        }
        try """
        <!-- ai-suggestion:unverified | session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core | date:2026-10-01 -->
        Rendered from synthetic HistoryRenderTests fixtures only; no user clipboard, recordings, or config content.
        All *_AI_.png renders in this directory: ai-suggestion:unverified.
        Includes light/dark History, keyboard filter focus, disabled Clipboard, short and narrow
        layouts, and the synthetic Preferences fixtures. No live user input is replayed.
        """.write(to: output.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.display()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 1000)
        window.orderOut(nil)
    }
}
