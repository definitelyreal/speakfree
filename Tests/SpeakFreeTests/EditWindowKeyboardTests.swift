// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

@MainActor
final class EditWindowKeyboardTests: XCTestCase {
    func testPlainEditingChordsAndRedoAreRecognized() {
        let cases: [(String, EditTextView.EditingShortcut)] = [
            ("c", .copy), ("x", .cut), ("v", .paste), ("a", .selectAll), ("z", .undo), ("i", .versions)
        ]
        for (key, expected) in cases {
            XCTAssertEqual(EditTextView.editingShortcut(key: key, modifiers: .command), expected)
            XCTAssertEqual(EditTextView.editingShortcut(key: key.uppercased(), modifiers: [.command, .capsLock]), expected)
        }
        XCTAssertEqual(EditTextView.editingShortcut(key: "Z", modifiers: [.command, .shift]), .redo)
    }

    func testHistoryAndOtherModifiedShortcutsAreNotTurnedIntoPlainEditingActions() {
        XCTAssertNil(EditTextView.editingShortcut(key: "v", modifiers: [.command, .shift]), "History owns this chord")
        for key in ["c", "x", "v", "a", "z", "i"] {
            let variants: [NSEvent.ModifierFlags] = [[.command, .option], [.command, .control], [.command, .function], []]
            for flags in variants {
                XCTAssertNil(EditTextView.editingShortcut(key: key, modifiers: flags))
            }
        }
        XCTAssertNil(EditTextView.editingShortcut(key: "i", modifiers: [.command, .shift]))
    }

    func testVersionsOnlyRunsForExactCommandIThroughTheNativeEventHandler() throws {
        let view = EditTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        var calls = 0
        view.onShowVersions = { calls += 1 }
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        }
        _ = view.performKeyEquivalent(with: try event([.command, .option]))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(view.performKeyEquivalent(with: try event(.command)))
        XCTAssertEqual(calls, 1)
    }
}

/// Opt-in synthetic renders use unnamed window placement, so neither saved frames nor live
/// settings/clipboard/microphone are read or changed.
@MainActor
final class EditWindowAppearanceTests: XCTestCase {
    func testRenderSmallEditWindowInLightAndDark() throws {
        guard let directory = ProcessInfo.processInfo.environment["EDIT_WINDOW_RENDER_DIR"] else {
            throw XCTSkip("EDIT_WINDOW_RENDER_DIR is not set; synthetic render harness only runs on demand")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let settings = EditModeSettings(cleanupEnabled: false, consentGiven: true, model: .sonnet, animation: .quiet)
            let core = EditSessionCore(persistenceEnabled: false, settings: settings,
                                      cleaner: ScriptedCleaner(), clipboard: FakeClipboard())
            let controller = EditWindowController(core: core, targetName: "A very long document title in TextEdit",
                                                  placementAutosaveName: nil)
            core.onEvent = { [weak controller] in controller?.handle($0) }
            for text in ["The garden center opens at eight, so let's leave by seven thirty.",
                         "Keep this paragraph until I choose where to insert it."] {
                let id = core.beginTake()
                core.takeStopped(id)
                core.takeTranscribed(id, raw: text, pipelineText: text)
            }
            controller.window.appearance = NSAppearance(named: appearance)
            controller.window.setContentSize(NSSize(width: 420, height: 240))
            controller.window.layoutIfNeeded()
            let content = try XCTUnwrap(controller.window.contentView)
            content.wantsLayer = true
            controller.window.appearance?.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            content.display()
            let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            controller.window.appearance?.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: image)
            }
            let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("edit-small-\(name).png"))
            XCTAssertGreaterThan(data.count, 1000)
            XCTAssertEqual(content.bounds.width, 420, accuracy: 1, "a long destination title must truncate, not widen the window")
            XCTAssertEqual(core.commitText, "The garden center opens at eight, so let's leave by seven thirty.\n\nKeep this paragraph until I choose where to insert it.")
        }
        try """
        <!-- ai-suggestion:unverified | session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b | date:2026-10-01 -->
        edit-small-light.png and edit-small-dark.png: synthetic EditWindowAppearanceTests fixtures,
        ai-suggestion:unverified. No user text, screen capture, microphone, or clipboard access.
        """.write(to: output.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
    }
}
