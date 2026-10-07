// ai-suggestion:unverified · session:unknown · 2026-10-05
// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:clipboard_core · 2026-10-01
import AppKit
import XCTest
@testable import SpeakFreeLib

final class HistoryInterfaceTests: XCTestCase {
    private func entry(_ text: String, source: HistoryEntry.Source = .dictation) -> HistoryEntry {
        .init(source: source, items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])])
    }

    private func pickerModel() -> HistoryPickerModel {
        let model = HistoryPickerModel()
        model.pointerLocation = { NSPoint(x: 400, y: 300) }
        return model
    }

    func testPresentationClearsSearchButPreservesSourceFilter() {
        let newest = entry("new dictation")
        let older = entry("old copy", source: .clipboard)
        let model = pickerModel()
        model.clipboardEnabled = true
        model.entries = [newest, older]
        model.filter = .clipboard
        model.query = "old"
        model.keyboardFocus = .filter(.clipboard)
        model.selectedID = older.id
        model.resetForPresentation()
        XCTAssertEqual(model.filter, .clipboard)
        XCTAssertEqual(model.keyboardFocus, .search)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedID, older.id)
    }

    func testFilterPreferenceSurvivesNewModelAndInvalidValueDefaultsToAll() throws {
        let suite = "HistoryInterfaceTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = HistoryPickerModel(preferences: preferences)
        XCTAssertEqual(first.filter, .all)
        first.handle(.filter(.dictation))
        XCTAssertEqual(HistoryPickerModel(preferences: preferences).filter, .dictation)
        first.filter = .clipboard
        let reopened = HistoryPickerModel(preferences: preferences)
        reopened.resetForPresentation()
        XCTAssertEqual(reopened.filter, .clipboard)
        XCTAssertTrue(reopened.showsClipboardDisabled)
        preferences.set("future-filter", forKey: HistoryPickerModel.filterPreferenceKey)
        XCTAssertEqual(HistoryPickerModel(preferences: preferences).filter, .all)
    }

    func testShortcutDefaultsToCommandShiftVAndCannotCaptureShiftTyping() throws {
        XCTAssertEqual(HistorySettings().shortcutKeyCode, 9)
        XCTAssertEqual(HistorySettings().shortcutModifiers, ["cmd", "shift"])
        XCTAssertEqual(HistorySettings().shortcutLabel, "⇧⌘V")
        XCTAssertEqual(try JSONDecoder().decode(HistorySettings.self, from: Data("{}".utf8)), HistorySettings())
        for json in [#"{"shortcutModifiers":[]}"#, #"{"shortcutModifiers":null}"#, #"{"shortcutModifiers":"invalid"}"#] {
            let settings = try JSONDecoder().decode(HistorySettings.self, from: Data(json.utf8))
            XCTAssertTrue(settings.shortcutModifiers.isEmpty)
            XCTAssertEqual(settings.shortcutLabel, "Choose shortcut…")
        }
        let custom = try JSONDecoder().decode(HistorySettings.self, from: Data(#"{"shortcutKeyCode":8,"shortcutModifiers":["ctrl","option"]}"#.utf8))
        XCTAssertEqual(custom.shortcutKeyCode, 8)
        XCTAssertEqual(custom.shortcutModifiers, ["ctrl", "option"])
        XCTAssertEqual(custom.shortcutLabel, "⌃⌥C")
        var aliases = custom
        aliases.shortcutModifiers = ["command", "alt", "control", "shift", "cmd"]
        aliases.shortcutKeyCode = 125
        XCTAssertEqual(aliases.shortcutLabel, "⌃⌥⇧⌘↓")
        XCTAssertFalse(HistorySettings.isSafeShortcut(["shift"]))
        XCTAssertFalse(HistorySettings.isSafeShortcut([]))
        XCTAssertTrue(HistorySettings.isSafeShortcut(["command", "shift"]))
        XCTAssertTrue(HistorySettings.isSafeShortcut(["alt"]))
        XCTAssertEqual(HistorySettings.normalizedModifiers(["command", "control", "alt"]), ["cmd", "ctrl", "option"])
        let decoded = try JSONDecoder().decode(HistorySettings.self, from: Data(#"{"shortcutModifiers":["shift"]}"#.utf8))
        XCTAssertTrue(decoded.shortcutModifiers.isEmpty)
    }

    func testSearchFindsTextBeyondVisiblePreviewAndReconcilesSelection() {
        let long = entry(String(repeating: "prefix ", count: 80) + "RareNeedle")
        let other = entry("different", source: .clipboard)
        let model = pickerModel()
        model.entries = [other, long]
        model.selectedID = other.id
        model.query = "rareneedle"
        model.reconcileSelection()
        XCTAssertFalse(long.displayTitle.contains("RareNeedle"))
        XCTAssertEqual(model.visible.map(\.id), [long.id])
        XCTAssertEqual(model.selectedID, long.id)
        model.filter = .clipboard
        model.reconcileSelection()
        XCTAssertTrue(model.visible.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    func testFiltersReconcileAndArrowSelectionStaysWithinVisibleResults() {
        let first = entry("one")
        let copy = entry("two", source: .clipboard)
        let last = entry("three")
        let model = pickerModel()
        model.entries = [first, copy, last]
        model.clipboardEnabled = true
        model.reconcileSelection()
        model.move(-1)
        XCTAssertEqual(model.selectedID, first.id)
        model.move(10)
        XCTAssertEqual(model.selectedID, last.id)
        model.move(1)
        XCTAssertEqual(model.selectedID, last.id)
        model.filter = .clipboard
        model.reconcileSelection()
        XCTAssertEqual(model.selectedID, copy.id)
        model.move(-1)
        XCTAssertEqual(model.selectedID, copy.id)
        model.entries = []
        model.reconcileSelection()
        model.move(1)
        XCTAssertNil(model.selectedID)
    }

    func testActivationPassesExactRichEntryAndCopyIntentWithoutFlattening() throws {
        let rich = HistoryEntry(source: .clipboard, items: [
            .init(representations: [.init(type: "public.rtf", data: Data([1, 0, 255])),
                                    .init(type: "public.html", data: Data("<b>hello</b>".utf8))]),
            .init(representations: [.init(type: "public.png", data: Data([137, 80, 78, 71]))])
        ])
        let model = pickerModel()
        model.entries = [rich]
        model.reconcileSelection()
        var selected: [(HistoryEntry, Bool)] = []
        model.choose = { selected.append(($0, $1)) }
        model.activate()
        model.activate(copyOnly: true)
        XCTAssertEqual(selected.map { $0.0 }, [rich, rich])
        XCTAssertEqual(selected.map { $0.1 }, [false, true])
        model.filter = .dictation
        model.reconcileSelection()
        model.activate()
        XCTAssertEqual(selected.count, 2, "An invisible selection must never be pasted")
    }

    func testMouseChoiceActivatesClickedRichRowOnceAndRejectsDisappearedRows() {
        let first = entry("first")
        let rich = HistoryEntry(source: .clipboard, items: [
            .init(representations: [.init(type: "public.rtf", data: Data([1, 0, 255])),
                                    .init(type: "public.html", data: Data("<b>second</b>".utf8))])
        ])
        let model = pickerModel()
        model.entries = [first, rich]
        model.resetForPresentation()
        var choices: [(HistoryEntry, Bool)] = []
        model.choose = { choices.append(($0, $1)) }
        model.activate(id: rich.id)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.0, rich, "Mouse activation must preserve every representation")
        XCTAssertEqual(choices.first?.1, false)
        XCTAssertEqual(model.selectedID, rich.id)
        model.entries = [first]
        model.activate(id: rich.id)
        XCTAssertEqual(choices.count, 1, "A removed row must not paste a replacement at the same position")
    }

    func testMouseHoverDoesNotScrollAndStationaryPointerDoesNotUndoKeyboardPaging() {
        let model = pickerModel()
        model.entries = (0..<18).map { entry("row \($0)") }
        model.resetForPresentation()
        let revision = model.selectionScrollRevision
        let pointer = NSPoint(x: -12_345, y: -12_345)
        model.hover(model.entries[4].id, at: pointer)
        XCTAssertEqual(model.selectedID, model.entries[4].id)
        XCTAssertEqual(model.selectionScrollRevision, revision,
                       "Hover must not reposition content beneath the pointer")
        model.hover(model.entries[5].id, at: pointer)
        XCTAssertEqual(model.selectedID, model.entries[4].id,
                       "Rows scrolling beneath a stationary pointer do not steal selection")
        model.move(1)
        XCTAssertEqual(model.selectedID, model.entries[5].id)
        XCTAssertGreaterThan(model.selectionScrollRevision, revision)
        model.page(1)
        XCTAssertEqual(model.selectedID, model.entries[11].id)
        model.hover(model.entries[10].id, at: model.pointerLocation())
        XCTAssertEqual(model.selectedID, model.entries[11].id,
                       "Keyboard paging keeps its selection until the pointer actually moves")
        model.hover(model.entries[10].id, at: pointer)
        XCTAssertEqual(model.selectedID, model.entries[10].id)
    }

    func testCommandArrowsMoveByVisiblePageAndClampToFilteredResults() {
        let model = pickerModel()
        model.entries = (0..<15).map { entry("row \($0)") }
        model.resetForPresentation()
        model.handle(.page(1))
        XCTAssertEqual(model.selectedID, model.entries[6].id)
        XCTAssertEqual(model.selectionScrollAnchor, .top)
        model.handle(.page(1))
        XCTAssertEqual(model.selectedID, model.entries[12].id)
        model.handle(.page(1))
        XCTAssertEqual(model.selectedID, model.entries.last?.id)
        model.handle(.page(-1))
        XCTAssertEqual(model.selectedID, model.entries[8].id)
        XCTAssertEqual(model.selectionScrollAnchor, .top)
        model.query = "row 1"
        model.reconcileSelection()
        model.handle(.page(1))
        XCTAssertEqual(model.selectedID, model.visible.last?.id)
        model.handle(.page(-1))
        XCTAssertEqual(model.selectedID, model.visible.first?.id)
        model.move(1)
        XCTAssertNil(model.selectionScrollAnchor, "Single-row movement keeps nearby rows in view")
        model.page(1)
        model.select(model.visible[0].id)
        XCTAssertNil(model.selectionScrollAnchor, "Clicking after paging must not jump the list")
    }

    func testPagingForwardTwiceThenBackRestoresPreviousSixRowPage() throws {
        let model = pickerModel()
        model.entries = (0..<18).map { entry("row \($0)") }
        model.resetForPresentation()
        model.handle(.page(1))
        model.handle(.page(1))
        XCTAssertEqual(model.selectedID, model.entries[12].id)
        XCTAssertEqual(model.selectionScrollAnchor, .top)
        model.handle(.page(-1))
        let start = try XCTUnwrap(model.visible.firstIndex { $0.id == model.selectedID })
        XCTAssertEqual(start, 6)
        XCTAssertEqual(model.selectionScrollAnchor, .top,
                       "Paging back must show rows 6–11; a bottom anchor shows rows 1–6")
        XCTAssertEqual(Array(model.visible.dropFirst(start).prefix(HistoryPickerLayout.pageSize)),
                       Array(model.entries[6..<12]))
    }

    func testPickerKeysUseGlyphConventionsAndLeaveTextEditingModifiersAlone() {
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 125, modifiers: .command), .page(1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 126, modifiers: [.command, .numericPad, .function]), .page(-1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 125, modifiers: []), .move(1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 121, modifiers: []), .page(1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 116, modifiers: []), .page(-1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 36, modifiers: .command), .activate(copyOnly: true))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 43, modifiers: .command), .preferences)
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 18, modifiers: .command), .filter(.dictation))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 19, modifiers: .command), .filter(.clipboard))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 20, modifiers: .command), .filter(.all))
        XCTAssertEqual(HistoryPickerModel.Filter.allCases, [.dictation, .clipboard, .all])
        XCTAssertNil(HistoryPickerKeyAction.action(keyCode: 126, modifiers: .option))
        XCTAssertNil(HistoryPickerKeyAction.action(keyCode: 125, modifiers: [.command, .shift]))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 48, modifiers: []), .cycleFocus(1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 48, modifiers: .shift), .cycleFocus(-1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 3, modifiers: .command), .focusSearch)
        XCTAssertNil(HistoryPickerKeyAction.action(keyCode: 8, modifiers: .command), "Command-C still copies search text")
    }

    func testFilterArrowNavigationCyclesAllSourcesWithoutClearingSearch() {
        let model = pickerModel()
        let dictation = entry("shared dictation")
        let clipboard = entry("shared copy", source: .clipboard)
        model.entries = [dictation, clipboard]
        model.query = "shared"
        model.handle(.cycleFilter(1))
        XCTAssertEqual(model.filter, .dictation)
        XCTAssertEqual(model.keyboardFocus, .filter(.dictation))
        XCTAssertEqual(model.selectedID, dictation.id)
        model.handle(.cycleFilter(1))
        XCTAssertEqual(model.filter, .clipboard)
        XCTAssertTrue(model.showsClipboardDisabled, "The unavailable filter still offers Preferences")
        XCTAssertNil(model.selectedID)
        model.handle(.cycleFilter(1))
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.selectedID, dictation.id)
        model.handle(.cycleFilter(-1))
        XCTAssertEqual(model.filter, .clipboard)
        model.handle(.cycleFilter(-1))
        XCTAssertEqual(model.filter, .dictation)
        model.handle(.cycleFilter(-1))
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.query, "shared")
    }

    func testFilterArrowKeysNeverStealSearchCaretOrModifiedEditingKeys() {
        let model = pickerModel()
        model.query = "editable search"
        XCTAssertFalse(model.filterNavigationFocused)
        for key: UInt16 in [123, 124] {
            XCTAssertNil(model.keyAction(keyCode: key, modifiers: []))
        }
        model.handle(.cycleFilter(1))
        XCTAssertTrue(model.filterNavigationFocused)
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 123, modifiers: [],
                                                    filterNavigationFocused: model.filterNavigationFocused), .cycleFilter(-1))
        XCTAssertEqual(HistoryPickerKeyAction.action(keyCode: 124, modifiers: [],
                                                    filterNavigationFocused: model.filterNavigationFocused), .cycleFilter(1))
        for flags: NSEvent.ModifierFlags in [.shift, .option, .command, .control] {
            XCTAssertNil(HistoryPickerKeyAction.action(keyCode: 123, modifiers: flags,
                                                       filterNavigationFocused: true))
        }
        model.handle(.focusSearch)
        XCTAssertEqual(model.keyboardFocus, .search)
        XCTAssertFalse(model.filterNavigationFocused)
        model.keyboardFocus = nil
        XCTAssertFalse(model.filterNavigationFocused, "Unfocused controls must not claim horizontal arrows")
    }

    func testDirectFilterShortcutsPreserveSearchFocusOrFollowFocusedChip() {
        let model = pickerModel()
        model.query = "find me"
        model.handle(.filter(.clipboard))
        XCTAssertEqual(model.keyboardFocus, .search)
        model.handle(.cycleFilter(1))
        XCTAssertEqual(model.keyboardFocus, .filter(.all))
        model.handle(.filter(.dictation))
        XCTAssertEqual(model.keyboardFocus, .filter(.dictation))
        XCTAssertEqual(model.query, "find me")
    }

    func testDisabledClipboardRemainsDiscoverableWithoutActivatingHiddenEntries() {
        let model = pickerModel()
        let copied = entry("previously captured", source: .clipboard)
        model.entries = [copied]
        model.selectedID = copied.id
        var choices = 0
        var preferences = 0
        model.choose = { _, _ in choices += 1 }
        model.openPreferences = { preferences += 1 }
        model.handle(.filter(.clipboard))
        XCTAssertTrue(model.showsClipboardDisabled)
        XCTAssertTrue(model.visible.isEmpty)
        XCTAssertNil(model.selectedID)
        model.activate()
        XCTAssertEqual(choices, 0)
        model.handle(.preferences)
        XCTAssertEqual(preferences, 1)
        model.clipboardEnabled = true
        model.reconcileSelection()
        XCTAssertFalse(model.showsClipboardDisabled)
        XCTAssertEqual(model.visible, [copied])
        model.activate()
        XCTAssertEqual(choices, 1)
    }

    func testCompactPickerCapsRowsAndFitsBesidePointerOnAnyScreen() {
        let model = pickerModel()
        model.entries = (0..<20).map { entry("row \($0)") }
        let fullSize = model.preferredSize
        XCTAssertLessThanOrEqual(fullSize.width, 380)
        XCTAssertLessThanOrEqual(fullSize.height, 400)
        model.entries = Array(model.entries.prefix(1))
        XCTAssertLessThan(model.preferredSize.height, fullSize.height)
        XCTAssertEqual(HistoryPickerLayout.listHeight(itemCount: 6), HistoryPickerLayout.listHeight(itemCount: 200))
        let screen = NSRect(x: -1600, y: 120, width: 1600, height: 900)
        let center = NSPoint(x: -900, y: 700)
        let near = HistoryPickerLayout.frame(near: center, size: fullSize, visibleFrame: screen)
        XCTAssertEqual(near.minX, center.x + 8)
        XCTAssertEqual(near.maxY, center.y - 6)
        for point in [NSPoint(x: -1600, y: 120), NSPoint(x: 0, y: 1020), NSPoint(x: 0, y: 120)] {
            let frame = HistoryPickerLayout.frame(near: point, size: fullSize, visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame), "Panel must avoid clipped results on screen edges")
        }
        let smallScreen = NSRect(x: 100, y: -300, width: 280, height: 250)
        XCTAssertTrue(smallScreen.contains(HistoryPickerLayout.frame(near: .zero, size: fullSize, visibleFrame: smallScreen)))
    }

    func testShortDisplayShrinksContentAndKeyboardPagesWithItsVisibleCapacity() {
        let model = pickerModel()
        model.entries = (0..<18).map { entry("row \($0)") }
        let screen = NSRect(x: 0, y: 0, width: 500, height: 250)
        let available = screen.height - 2 * HistoryPickerLayout.screenInset
        model.fit(to: screen)
        model.resetForPresentation()
        XCTAssertEqual(model.pageSize, 2)
        XCTAssertEqual(model.listHeight, 2 * HistoryPickerLayout.rowHeight + 8)
        XCTAssertEqual(model.preferredSize.height, model.chromeHeight + model.listHeight)
        XCTAssertLessThanOrEqual(model.preferredSize.height, available)
        model.page(1)
        XCTAssertEqual(model.selectedID, model.entries[2].id)
        model.page(-1)
        XCTAssertEqual(model.selectedID, model.entries[0].id)

        model.status = "Copied. Press ⌘V in the app where you want it."
        XCTAssertEqual(model.pageSize, 1)
        XCTAssertEqual(model.listHeight, HistoryPickerLayout.rowHeight + 8)
        XCTAssertLessThanOrEqual(model.preferredSize.height, available)
        model.page(1)
        XCTAssertEqual(model.selectedID, model.entries[1].id)
        model.filter = .clipboard
        XCTAssertTrue(model.showsClipboardDisabled)
        XCTAssertTrue(model.showsInlineClipboardPreferences,
                      "The concise explanation and native button fit a 250-point display")
        XCTAssertLessThanOrEqual(model.chromeHeight + model.listHeight, available,
                                 "The content must fit, not merely the outer window frame")
        model.fit(to: NSRect(x: 0, y: 0, width: 500, height: 210))
        XCTAssertFalse(model.showsInlineClipboardPreferences,
                       "On tighter screens Preferences stays in the fixed footer")
        XCTAssertLessThanOrEqual(model.preferredSize.height, 210 - 2 * HistoryPickerLayout.screenInset)
        model.status = nil
        XCTAssertLessThanOrEqual(model.preferredSize.height, available)
        model.fit(to: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(model.pageSize, 6)
        XCTAssertEqual(model.listHeight, HistoryPickerLayout.emptyHeight)
        XCTAssertTrue(model.showsInlineClipboardPreferences)
    }

    func testHistoryDefaultAndRoundTripAreIndependentOfRecordingRetention() throws {
        var config = Config.defaultConfig
        config.history = nil
        config.saveRecordings = FlexBool(false)
        let model = SettingsViewModel(config: config)
        XCTAssertEqual(model.historySettings.retention, .session)
        XCTAssertFalse(model.historySettings.includeClipboard)
        XCTAssertTrue(model.historySettings.policy.captureDictations)
        XCTAssertFalse(model.historySettings.policy.persistent)
        XCTAssertGreaterThan(model.historySettings.policy.maximumAge, 7 * 24 * 60 * 60,
                             "Session history ends at quit, not a hidden seven-day deadline")
        model.historySettings.retention = .week
        model.historySettings.includeClipboard = true
        model.historySettings.shortcutKeyCode = 7
        model.historySettings.shortcutModifiers = ["ctrl", "alt"]
        let roundTrip = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(model.toConfig()))
        XCTAssertEqual(roundTrip.history, model.historySettings)
        XCTAssertEqual(roundTrip.saveRecordings?.value, false)
        XCTAssertTrue(try XCTUnwrap(roundTrip.history).policy.persistent)
    }

    func testPartialAndFutureHistorySettingsDoNotResetUnrelatedConfig() throws {
        let variants: [(String, HistorySettings.Retention, Bool)] = [
            (#"{}"#, .session, false),
            (#"{"includeClipboard":true}"#, .session, true),
            (#"{"retention":"future-retention","includeClipboard":true}"#, .off, true),
            (#"{"retention":23,"includeClipboard":"bad","shortcutKeyCode":-1}"#, .off, false),
            (#""malformed-history""#, .off, false)
        ]
        for (historyJSON, expectedRetention, expectedClipboard) in variants {
            let json = """
            {"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"custom-model","language":"de",
             "modelPath":"/synthetic/model.bin","history":\(historyJSON)}
            """
            let decoded = try Config.decode(from: Data(json.utf8))
            XCTAssertEqual(decoded.modelSize, "custom-model")
            XCTAssertEqual(decoded.language, "de")
            XCTAssertEqual(decoded.modelPath, "/synthetic/model.bin")
            XCTAssertEqual(decoded.history?.retention, expectedRetention)
            XCTAssertEqual(decoded.history?.includeClipboard, expectedClipboard)
        }
    }

    func testSharedSettingsWriterPreservesUnrelatedValues() {
        var config = Config.defaultConfig
        config.modelPath = "/synthetic/model.bin"
        config.reuseStreamingPartial = FlexBool(false)
        config.localAPIPort = 5678
        let model = SettingsViewModel(config: config)
        model.historySettings.includeClipboard = true
        let written = model.toConfig()
        XCTAssertEqual(written.modelPath, config.modelPath)
        XCTAssertEqual(written.reuseStreamingPartial?.value, false)
        XCTAssertEqual(written.localAPIPort, 5678)
        XCTAssertEqual(written.history?.includeClipboard, true)
    }
}
