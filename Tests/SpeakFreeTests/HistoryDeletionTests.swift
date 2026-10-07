// ai-suggestion:unverified · session:unknown · 2026-10-05
import AppKit
import XCTest
@testable import SpeakFreeLib

final class HistoryDeletionTests: XCTestCase {
    private func entry(_ text: String, source: HistoryEntry.Source = .clipboard, rich: Bool = false) -> HistoryEntry {
        var representations = [HistoryRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]
        if rich { representations.append(.init(type: "public.rtf", data: Data("{\\rtf1\\ansi \(text)}".utf8))) }
        return HistoryEntry(source: source, items: [.init(representations: representations)])
    }

    private func picker(_ entries: [HistoryEntry]) -> HistoryPickerModel {
        let model = HistoryPickerModel()
        model.pointerLocation = { .zero }
        model.entries = entries
        model.clipboardEnabled = true
        model.resetForPresentation()
        return model
    }

    private func key(_ code: UInt16, model: HistoryPickerModel, modifiers: NSEvent.ModifierFlags = [],
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(model.keyAction(keyCode: code, modifiers: modifiers), file: file, line: line)
        model.handle(action)
    }

    func testRowArrowsVisitAaThenTrashAndSkipUnavailableAa() throws {
        let rich = entry("rich", rich: true)
        let model = picker([rich, entry("plain"), entry("dictation", source: .dictation)])
        try key(124, model: model)
        XCTAssertEqual(model.keyboardFocus, .plainText)
        try key(124, model: model)
        XCTAssertEqual(model.keyboardFocus, .trash)
        try key(124, model: model)
        XCTAssertEqual(model.keyboardFocus, .trash, "Right clamps at the final action")
        try key(123, model: model)
        XCTAssertEqual(model.keyboardFocus, .plainText)
        try key(123, model: model)
        XCTAssertEqual(model.keyboardFocus, .row)
        for index in 1...2 {
            model.move(1)
            try key(124, model: model)
            XCTAssertEqual(model.selectedID, model.entries[index].id)
            XCTAssertEqual(model.keyboardFocus, .trash)
            try key(123, model: model)
            XCTAssertEqual(model.keyboardFocus, .row)
        }
    }

    func testTrashIntentFollowsRowsAndPagesWithoutRevertingToAa() throws {
        let model = picker((0..<18).map { entry("row \($0)", rich: $0.isMultiple(of: 2)) })
        model.handle(.nextRowAction)
        model.handle(.nextRowAction)
        for delta in [1, 1, -1] {
            model.move(delta)
            XCTAssertEqual(model.keyboardFocus, .trash)
        }
        model.page(1)
        XCTAssertEqual(model.selectedID, model.entries[7].id)
        XCTAssertEqual(model.keyboardFocus, .trash)
        model.page(-1)
        XCTAssertEqual(model.selectedID, model.entries[1].id)
        XCTAssertEqual(model.keyboardFocus, .trash)
        model.handle(.previousRowAction)
        model.move(1)
        XCTAssertEqual(model.keyboardFocus, .row, "Leaving Trash clears the remembered action")
    }

    func testTrashReturnDeletesOnlySelectedIDAndNeverPastes() throws {
        let entries = [entry("first"), entry("second", rich: true)]
        let model = picker(entries)
        var removed: [UUID] = []
        var choices = 0
        model.remove = { id in removed.append(id); model.entries.removeAll { $0.id == id }; model.reconcileSelection() }
        model.choose = { _, _ in choices += 1 }
        model.move(1)
        model.handle(.nextRowAction)
        model.handle(.nextRowAction)
        try key(36, model: model, modifiers: .command)
        XCTAssertTrue(removed.isEmpty, "Copy shortcut must not delete")
        try key(36, model: model)
        XCTAssertEqual(removed, [entries[1].id])
        XCTAssertEqual(model.selectedID, entries[0].id)
        XCTAssertEqual(model.keyboardFocus, .trash)
        model.deleteRow(entries[1].id)
        XCTAssertEqual(removed, [entries[1].id], "A disappeared mouse target must not delete another row")
        XCTAssertEqual(choices, 0)
        model.pasteBehavior = .pasting
        try key(36, model: model)
        XCTAssertEqual(removed, [entries[1].id])
    }

    func testMouseDeletionThenReturnKeepsNeighborAcrossSynchronousRefreshAndArrival() throws {
        let entries = (0..<18).map { entry("row \($0)", rich: $0.isMultiple(of: 2)) }
        let model = picker(entries)
        let arrival = entry("new arrival")
        var removed: [UUID] = []
        model.choose = { _, _ in XCTFail("Deleting rows must never paste") }
        model.remove = { id in
            removed.append(id)
            model.entries.removeAll { $0.id == id }
            if removed.count == 1 { model.entries.insert(arrival, at: 0) }
            model.reconcileSelection()
        }
        model.deleteRow(entries[6].id) // The exact row identity supplied by a mouse click.
        XCTAssertEqual(model.selectedID, entries[7].id)
        XCTAssertEqual(model.keyboardFocus, .trash)
        try key(36, model: model)
        XCTAssertEqual(removed, [entries[6].id, entries[7].id])
        XCTAssertEqual(model.selectedID, entries[8].id)
        XCTAssertTrue(model.entries.contains { $0.id == arrival.id })
        XCTAssertTrue(model.entries.contains { $0.id == entries[0].id })
        model.handle(.previousRowAction)
        XCTAssertEqual(model.keyboardFocus, .plainText, "Left from the neighbor's Trash returns to its available Aa")
    }

    func testDeletingFinalRowUsesPreviousSurvivingNeighborAndEmptyReturnDoesNothing() throws {
        let entries = (0..<9).map { entry("row \($0)") }
        let model = picker(entries)
        var removed: [UUID] = []
        model.choose = { _, _ in XCTFail("A destructive action must not become paste") }
        model.remove = { id in
            removed.append(id)
            model.entries.removeAll { $0.id == id }
            model.reconcileSelection()
        }
        model.deleteRow(entries[8].id)
        XCTAssertEqual(model.selectedID, entries[7].id)
        for _ in 0..<8 { try key(36, model: model) }
        XCTAssertEqual(removed, entries.reversed().map(\.id))
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.keyboardFocus, .trash)
        try key(36, model: model)
        XCTAssertEqual(removed.count, 9)
    }

    func testActionHoverKeepsItsOwnSelectionUntilPointerMoves() {
        let entries = [entry("rich", rich: true), entry("plain")]
        let model = picker(entries)
        model.hoverAction(.trash, id: entries[0].id, at: NSPoint(x: 1, y: 0))
        XCTAssertEqual(model.keyboardFocus, .trash)
        model.hover(entries[0].id, at: NSPoint(x: 1, y: 0))
        XCTAssertEqual(model.keyboardFocus, .trash, "The parent row must not erase an action at the same pointer position")
        model.move(1)
        model.hoverAction(.trash, id: entries[0].id, at: .zero)
        XCTAssertEqual(model.selectedID, entries[1].id, "Keyboard scrolling beneath a stationary pointer preserves selection")
        model.hoverAction(.plainText, id: entries[0].id, at: NSPoint(x: 2, y: 0))
        XCTAssertEqual(model.selectedID, entries[0].id)
        XCTAssertEqual(model.keyboardFocus, .plainText)
        model.hover(entries[1].id, at: NSPoint(x: 3, y: 0))
        XCTAssertEqual(model.keyboardFocus, .row)
        model.move(-1)
        XCTAssertEqual(model.keyboardFocus, .row)
    }

    func testMouseBulkConfirmationDeletesAllSearchMatchesBeyondFirstPage() throws {
        let matches = (0..<15).map { entry("needle \($0)") }
        let model = picker(matches + [entry("unrelated"), entry("needle dictation", source: .dictation)])
        var now: TimeInterval = 100
        model.uptime = { now }
        model.filter = .clipboard
        model.query = "needle"
        model.searchChanged()
        var batches: [[UUID]] = []
        model.removeMany = { batches.append($0) }
        XCTAssertGreaterThan(model.visible.count, model.pageSize)
        XCTAssertEqual(model.countSummary, "15 matches")
        model.clickBulkDelete()
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(model.bulkDeletePrompt, "Delete 15 matches?")
        XCTAssertEqual(model.armedDeletion?.ids, matches.map(\.id))
        model.clickBulkDelete()
        XCTAssertTrue(batches.isEmpty, "A double-click must not confirm bulk deletion")
        now += model.doubleClickInterval + 0.01
        model.clickBulkDelete()
        XCTAssertEqual(batches, [matches.map(\.id)])
        XCTAssertNil(model.armedDeletion)
        XCTAssertEqual(model.keyboardFocus, .search)
        model.activate(copyOnly: true)
        XCTAssertEqual(batches.count, 1)
    }

    func testTabToBulkPreservesClipboardScopeThroughAllChip() throws {
        let copied = entry("shared copy")
        let model = picker([entry("shared dictation", source: .dictation), copied])
        model.filter = .clipboard
        model.query = "shared"
        model.searchChanged()
        var batches: [[UUID]] = []
        model.removeMany = { batches.append($0) }
        for focus: HistoryPickerModel.KeyboardFocus in [.filter(.dictation), .filter(.clipboard), .filter(.all), .bulkDelete] {
            try key(48, model: model)
            XCTAssertEqual(model.keyboardFocus, focus)
            XCTAssertEqual(model.editorFocus, .search)
            XCTAssertEqual(model.filter, .clipboard, "Tab must never change the active deletion scope")
            XCTAssertEqual(model.visible.map(\.id), [copied.id])
            XCTAssertEqual(model.countSummary, "1 match")
        }
        XCTAssertEqual(model.bulkDeletePrompt, "Delete 1 match?")
        try key(36, model: model, modifiers: .command)
        XCTAssertTrue(batches.isEmpty)
        try key(36, model: model)
        XCTAssertEqual(batches, [[copied.id]])
    }

    func testFilterReturnSelectsWithoutPastingAndArrowsStartAtFocusedChip() throws {
        let model = picker([entry("copy"), entry("speech", source: .dictation)])
        var choices = 0
        model.choose = { _, _ in choices += 1 }
        try key(48, model: model)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.keyboardFocus, .filter(.dictation))
        try key(36, model: model)
        XCTAssertEqual(model.filter, .dictation)
        XCTAssertEqual(choices, 0)
        try key(48, model: model)
        XCTAssertEqual(model.keyboardFocus, .filter(.clipboard))
        XCTAssertEqual(model.filter, .dictation)
        try key(124, model: model)
        XCTAssertEqual(model.filter, .all, "Arrow starts from focused Clipboard, not active Dictations")
        XCTAssertEqual(model.keyboardFocus, .filter(.all))
        XCTAssertEqual(model.editorFocus, .search)
    }

    func testChangingScopeContentOrFocusCancelsArmedDeletion() {
        let changes: [(HistoryPickerModel) -> Void] = [
            { $0.query = "different" }, { $0.filter = .dictation },
            { $0.entries.append(self.entry("new arrival")) }, { $0.entries = Array($0.entries.reversed()) },
            { $0.clipboardEnabled = false }, { $0.keyboardFocus = .search },
            { $0.keyboardFocus = nil }, { $0.handle(.cycleFocus(-1)) }, { $0.resetForPresentation() }
        ]
        for change in changes {
            let model = picker([entry("one"), entry("two")])
            var batches = 0
            model.removeMany = { _ in batches += 1 }
            model.clickBulkDelete()
            XCTAssertNotNil(model.armedDeletion)
            change(model)
            XCTAssertNil(model.armedDeletion)
            model.handle(.activate(copyOnly: false))
            XCTAssertEqual(batches, 0)
        }
    }

    func testUnchangedPersistenceRefreshPreservesBulkConfirmation() throws {
        let entries = [entry("one"), entry("two", rich: true)]
        let model = picker(entries)
        var batches: [[UUID]] = []
        model.removeMany = { batches.append($0) }
        model.clickBulkDelete()
        let armed = model.armedDeletion
        model.entries = entries.map { $0 }
        model.reconcileSelection()
        XCTAssertEqual(model.armedDeletion, armed)
        XCTAssertEqual(model.keyboardFocus, .bulkDelete)
        XCTAssertEqual(model.bulkDeletePrompt, "Delete 2 Items?")
        try key(36, model: model)
        XCTAssertEqual(batches, [entries.map(\.id)])
    }

    func testSameIDContentReplacementAndRemovalCancelWithoutPasteOrRearming() throws {
        let first = entry("first")
        let second = entry("second")
        let replacement = HistoryEntry(id: first.id, createdAt: first.createdAt, source: first.source,
            items: entry("changed payload").items)
        for refreshed in [[replacement, second], [second]] {
            let model = picker([first, second])
            var batches = 0
            model.removeMany = { _ in batches += 1 }
            model.choose = { _, _ in XCTFail("An invalidated confirmation must not become paste") }
            model.clickBulkDelete()
            model.entries = refreshed
            model.reconcileSelection()
            XCTAssertNil(model.armedDeletion)
            XCTAssertNil(model.bulkDeletePrompt)
            XCTAssertEqual(model.keyboardFocus, .filter(.all), "Leave the Delete footer state when confirmation expires")
            try key(36, model: model)
            XCTAssertEqual(batches, 0)
            XCTAssertNil(model.armedDeletion, "Return selects the active filter; it must not arm changed results")
            model.clickBulkDelete()
            XCTAssertEqual(model.armedDeletion?.ids, refreshed.map(\.id))
            XCTAssertEqual(batches, 0, "A fresh click asks for confirmation again")
        }
    }

    func testNewArrivalRequiresFreshConfirmationAndEscapeCancelsBeforeClosing() throws {
        let first = entry("first")
        let model = picker([first])
        var batches: [[UUID]] = []
        var closes = 0
        model.removeMany = { batches.append($0) }
        model.close = { closes += 1 }
        model.clickBulkDelete()
        model.entries.append(entry("arrival"))
        XCTAssertNil(model.armedDeletion)
        try key(36, model: model)
        XCTAssertTrue(batches.isEmpty)
        model.clickBulkDelete()
        XCTAssertEqual(model.armedDeletion?.ids, model.entries.map(\.id))
        XCTAssertTrue(batches.isEmpty, "The click following a content change only re-arms")
        try key(53, model: model)
        XCTAssertNil(model.armedDeletion)
        XCTAssertEqual(model.keyboardFocus, .search)
        XCTAssertEqual(closes, 0)
        try key(53, model: model)
        XCTAssertEqual(closes, 1)
    }

    func testEmptyAndInFlightResultsDoNotArmAndCountsUseCurrentScope() {
        let model = picker([])
        model.clickBulkDelete()
        XCTAssertNil(model.armedDeletion)
        model.entries = [entry("copy"), entry("speech", source: .dictation)]
        model.filter = .all
        XCTAssertEqual(model.countSummary, "2 Items")
        model.filter = .clipboard
        XCTAssertEqual(model.countSummary, "1 Clipboard Item")
        model.filter = .dictation
        XCTAssertEqual(model.countSummary, "1 Dictation")
        model.pasteBehavior = .pasting
        model.clickBulkDelete()
        XCTAssertNil(model.armedDeletion)
    }

    func testQueryReconciliationPrecedesSubsequentFocusNavigation() throws {
        let model = picker([entry("first"), entry("second", rich: true)])
        model.move(1)
        model.handle(.nextRowAction)
        XCTAssertEqual(model.keyboardFocus, .plainText)
        model.query = "first"
        XCTAssertEqual(model.keyboardFocus, .search, "Typing returns to Search synchronously")
        XCTAssertEqual(model.selectedID, model.entries[0].id)
        model.query = ""
        try key(48, model: model)
        XCTAssertEqual(model.keyboardFocus, .filter(.dictation))
        XCTAssertEqual(model.filter, .all, "The later Tab controls focus, not the selected scope")
        model.handle(.cycleFilter(1))
        XCTAssertEqual(model.keyboardFocus, .filter(.clipboard))
        XCTAssertEqual(model.filter, .clipboard)
    }

    func testLogicalNavigationDoesNotQueueNativeSearchFocusOrScrollWork() throws {
        let model = picker([entry("one"), entry("two", rich: true)])
        var nativeRequests = 0
        model.focusSearchEditor = { nativeRequests += 1 }
        let initialRevision = model.selectionScrollRevision
        for _ in 0..<20 {
            for _ in 0..<5 {
                try key(48, model: model)
                XCTAssertEqual(model.editorFocus, .search)
            }
        }
        XCTAssertEqual(model.keyboardFocus, .search)
        XCTAssertEqual(model.selectionScrollRevision, initialRevision, "Focus-only navigation must not queue row scrolling")
        XCTAssertEqual(nativeRequests, 0, "Tab must not enqueue AppKit focus/layout round trips")
        model.move(1)
        model.handle(.nextRowAction)
        XCTAssertEqual(model.editorFocus, .search)
        model.handle(.nextRowAction)
        XCTAssertEqual(model.editorFocus, .search)
        XCTAssertEqual(nativeRequests, 0)
        model.handle(.focusSearch)
        XCTAssertEqual(nativeRequests, 1, "Explicit Search still repairs missing native focus")
    }
}
