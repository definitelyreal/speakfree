// ai-suggestion:unverified · session:unknown · 2026-10-05
// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_mouse_history · 2026-10-01
// Opt-in native interaction test. Transparent synthetic window; no system input or clipboard access.
import AppKit
import XCTest
@testable import SpeakFreeLib

final class HistoryMouseTests: XCTestCase {
    func testRichTextButtonAndDisabledPlainTextButtonHaveSeparateHitTargets() throws {
        guard ProcessInfo.processInfo.environment["HISTORY_MOUSE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in transparent native History interaction harness")
        }
        _ = NSApplication.shared
        let model = HistoryPickerModel()
        model.clipboardEnabled = true
        let rich = HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.rtf", data: Data(#"{\rtf1\ansi Rich \b sample\b0}"#.utf8)),
            .init(type: "public.utf8-plain-text", data: Data("Rich sample".utf8))])])
        let plain = HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data("Plain sample".utf8))])])
        model.entries = [rich, plain]
        model.resetForPresentation()
        var choices: [HistoryEntry] = []
        model.choose = { entry, copy in XCTAssertFalse(copy); choices.append(entry) }
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: model.preferredSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let host = HistoryHostingView(rootView: HistoryPickerView(model: model))
        host.frame = NSRect(origin: .zero, size: model.preferredSize)
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        panel.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        // Confine text events to this transparent test window. No global keyboard
        // event, application activation, or real clipboard is involved.
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let search = try XCTUnwrap(textField(in: host))
        model.focusSearchEditor = { [weak panel] in XCTAssertTrue(panel?.focusSearchEditor() == true) }
        XCTAssertEqual(model.keyboardFocus, .search)
        XCTAssertTrue(panel.makeFirstResponder(nil))
        model.handle(.focusSearch)
        XCTAssertNotNil(search.currentEditor(), "⌘F must reassert native focus when logical focus is already search")
        let nativeEditor = try XCTUnwrap(search.currentEditor())
        let revision = model.selectionScrollRevision
        for _ in 0..<2 {
            for _ in 0..<5 {
                model.handle(try XCTUnwrap(model.keyAction(keyCode: 48, modifiers: [])))
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                XCTAssertEqual(model.editorFocus, .search)
                XCTAssertTrue(search.currentEditor() === nativeEditor,
                              "Logical Tab navigation must retain the same native field editor")
            }
        }
        XCTAssertEqual(model.selectionScrollRevision, revision)
        model.handle(try XCTUnwrap(model.keyAction(keyCode: 124, modifiers: [])))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.keyboardFocus, .plainText, "Right Arrow must work on the initially selected row")
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        editor.insertText("Rich", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.query, "Rich", "Typing after row/action navigation must continue filtering")
        XCTAssertEqual(model.keyboardFocus, .search)
        model.query = ""
        model.handle(try XCTUnwrap(model.keyAction(keyCode: 48, modifiers: [])))
        XCTAssertEqual(model.keyboardFocus, .filter(.dictation))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.keyboardFocus, .filter(.dictation),
                       "A queued search update must not overwrite a newer Tab focus choice")
        XCTAssertTrue(search.currentEditor() === nativeEditor)
        model.resetForPresentation()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let top = model.preferredSize.height - HistoryPickerLayout.headerHeight - 1 - 4
        let firstY = top - HistoryPickerLayout.rowHeight * 0.5
        let secondY = top - HistoryPickerLayout.rowHeight * 1.5
        try click(panel, at: NSPoint(x: model.preferredSize.width - 52, y: firstY), eventNumber: 1)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.items.first?.representations.map(\.type), ["public.utf8-plain-text"])
        try click(panel, at: NSPoint(x: model.preferredSize.width - 90, y: firstY), eventNumber: 3)
        XCTAssertEqual(choices.last, rich, "The main row must still paste every original format")
        try click(panel, at: NSPoint(x: model.preferredSize.width - 52, y: secondY), eventNumber: 5)
        XCTAssertEqual(choices.count, 2, "The flat disabled control must not paste anything")
        var removed: [UUID] = []
        model.remove = { removed.append($0) }
        try click(panel, at: NSPoint(x: model.preferredSize.width - 24, y: secondY), eventNumber: 7)
        XCTAssertEqual(removed, [plain.id], "Trash must have its own hit target beside the disabled Aa")
        XCTAssertEqual(choices.count, 2)
        var batches: [[UUID]] = []
        model.removeMany = { batches.append($0) }
        let headerTrash = NSPoint(x: model.preferredSize.width - 22, y: model.preferredSize.height - 56)
        try click(panel, at: headerTrash, eventNumber: 9)
        XCTAssertNotNil(model.armedDeletion)
        XCTAssertTrue(batches.isEmpty, "The first mouse click only asks for confirmation")
        try click(panel, at: headerTrash, eventNumber: 11)
        XCTAssertTrue(batches.isEmpty, "Fast second click is a double-click, not confirmation")
        RunLoop.main.run(until: Date().addingTimeInterval(model.doubleClickInterval + 0.05))
        try click(panel, at: headerTrash, eventNumber: 13)
        XCTAssertEqual(batches, [[rich.id, plain.id]])
    }

    func testSingleMouseClickPastesSyntheticRowInNonactivatingPanel() throws {
        guard ProcessInfo.processInfo.environment["HISTORY_MOUSE_TESTS"] == "1" else {
            throw XCTSkip("HISTORY_MOUSE_TESTS=1 enables the transparent native History interaction harness")
        }
        _ = NSApplication.shared
        let model = HistoryPickerModel()
        model.pointerLocation = { NSPoint(x: 400, y: 300) }
        model.entries = ["First synthetic item", "Second synthetic item"].map { text in
            HistoryEntry(source: .dictation, items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data(text.utf8))])])
        }
        model.resetForPresentation()
        var choices: [UUID] = []
        model.choose = { entry, copyOnly in
            XCTAssertFalse(copyOnly)
            choices.append(entry.id)
        }
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: model.preferredSize),
                                 styleMask: [.nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let host = HistoryHostingView(rootView: HistoryPickerView(model: model))
        host.frame = NSRect(origin: .zero, size: model.preferredSize)
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        panel.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(panel.alphaValue, 0, "This harness must not put visible UI in front of the user's work")
        XCTAssertTrue(host.acceptsFirstMouse(for: nil), "The menu must act on its first click")

        // Click the second row well away from its text/icon. Padding is part of the
        // row's hit area, and choosing it must not depend on keyboard selection.
        let point = NSPoint(x: model.preferredSize.width - 90,
                            y: model.preferredSize.height - HistoryPickerLayout.headerHeight - 1 - 4
                                - HistoryPickerLayout.rowHeight * 1.5)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 1.05, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        panel.sendEvent(down)
        panel.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(choices, [model.entries[1].id], "One mouse click must choose exactly the clicked row")

        var preferenceOpens = 0
        model.openPreferences = { preferenceOpens += 1 }
        // The disabled-looking Clipboard chip still accepts a click and explains
        // how to enable capture. Its inline Preferences button remains clickable.
        // Header inset 10 + first chip 38 + spacing 5 + half chip 19 = 72.
        // x=116 targets All, so it cannot test the disabled Clipboard route.
        try click(panel, at: NSPoint(x: 72, y: model.preferredSize.height - 56), eventNumber: 3)
        XCTAssertEqual(model.filter, .clipboard)
        XCTAssertTrue(model.showsClipboardDisabled)
        panel.setContentSize(model.preferredSize)
        panel.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let buttonY = model.preferredSize.height - HistoryPickerLayout.headerHeight - 1
            - model.listHeight / 2 - 11
        try click(panel, at: NSPoint(x: model.preferredSize.width / 2, y: buttonY), eventNumber: 5)
        XCTAssertEqual(preferenceOpens, 1, "Clipboard's explanation must offer a working Preferences button")
        XCTAssertEqual(choices.count, 1, "Clicking controls must not activate a history item")
    }

    func testSixthRowTrashClickThenReturnDeletesItsNextNeighbor() throws {
        guard ProcessInfo.processInfo.environment["HISTORY_MOUSE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in transparent native History interaction harness")
        }
        _ = NSApplication.shared
        let model = HistoryPickerModel()
        model.pointerLocation = { .zero }
        let entries = (0..<10).map { index in
            HistoryEntry(source: .dictation, items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("Synthetic row \(index)".utf8))])])
        }
        model.entries = entries
        model.resetForPresentation()
        var removed: [UUID] = []
        model.choose = { _, _ in XCTFail("Trash and its follow-up Return must not paste") }
        model.remove = { id in
            removed.append(id)
            model.entries.removeAll { $0.id == id }
            model.reconcileSelection()
        }
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: model.preferredSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let host = HistoryHostingView(rootView: HistoryPickerView(model: model))
        host.frame = NSRect(origin: .zero, size: model.preferredSize)
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        panel.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let sixthRowTrash = NSPoint(x: model.preferredSize.width - 24,
            y: model.preferredSize.height - HistoryPickerLayout.headerHeight - 1 - 4
                - HistoryPickerLayout.rowHeight * 5.5)
        try click(panel, at: sixthRowTrash, eventNumber: 1)
        XCTAssertEqual(removed, [entries[5].id])
        XCTAssertEqual(model.selectedID, entries[6].id)
        XCTAssertEqual(model.keyboardFocus, .trash)
        model.handle(try XCTUnwrap(model.keyAction(keyCode: 36, modifiers: [])))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(removed, [entries[5].id, entries[6].id])
        XCTAssertEqual(model.selectedID, entries[7].id)
        XCTAssertTrue(model.entries.contains { $0.id == entries[0].id }, "The newest item must remain untouched")
    }

    private func click(_ panel: NSPanel, at point: NSPoint, eventNumber: Int) throws {
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: pressure))
            panel.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}
