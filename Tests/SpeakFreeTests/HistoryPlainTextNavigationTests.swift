// ai-suggestion:unverified · session:unknown · 2026-10-04
// Words-only acceptance cases. Authored without reading implementation or prior tests.
import Foundation
import XCTest
@testable import SpeakFreeLib

final class HistoryPlainTextNavigationTests: XCTestCase {
    private func rich(_ text: String) -> HistoryEntry {
        HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.rtf", data: Data("{\\rtf1\\ansi \(text)}".utf8)),
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))
        ])])
    }

    private func plain(_ text: String) -> HistoryEntry {
        HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))
        ])])
    }

    private func image() -> HistoryEntry {
        HistoryEntry(source: .clipboard, items: [.init(representations: [
            .init(type: "public.png", data: Data([0x89, 0x50, 0x4e, 0x47]))
        ])])
    }

    private func dictation() -> HistoryEntry {
        HistoryEntry(source: .dictation, items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data("spoken words".utf8))
        ])])
    }

    private func picker(_ entries: [HistoryEntry]) -> HistoryPickerModel {
        let model = HistoryPickerModel()
        model.clipboardEnabled = true
        model.entries = entries
        model.resetForPresentation()
        model.handle(.focusRow)
        return model
    }

    private func assertSelection(
        _ model: HistoryPickerModel, _ entry: HistoryEntry, aa: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(model.selectedID, entry.id, file: file, line: line)
        XCTAssertEqual(model.keyboardFocus, aa ? .plainText : .row, file: file, line: line)
    }

    func testAaFollowsAdjacentRichRowsDownAndUp() {
        let entries = [rich("first"), rich("second"), rich("third")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        assertSelection(model, entries[0], aa: true)
        for index in [1, 2] {
            model.handle(.move(1))
            assertSelection(model, entries[index], aa: true)
        }
        for index in [1, 0] {
            model.handle(.move(-1))
            assertSelection(model, entries[index], aa: true)
        }
    }

    func testAaReturnsAfterEachKindOfIneligibleRowInBothDirections() {
        // The intervening row stays reachable; it must not consume the Aa preference.
        for middle in [plain("plain"), image(), dictation()] {
            let entries = [rich("first"), middle, rich("last")]
            let model = picker(entries)
            model.handle(.focusPlainText)
            model.handle(.move(1))
            assertSelection(model, entries[1], aa: false)
            model.handle(.move(1))
            assertSelection(model, entries[2], aa: true)
            model.handle(.move(-1))
            assertSelection(model, entries[1], aa: false)
            model.handle(.move(-1))
            assertSelection(model, entries[0], aa: true)
        }
    }

    func testAaSurvivesConsecutiveIneligibleRowsAndDirectionChanges() {
        let entries = [rich("first"), plain("plain"), image(), dictation(), rich("last")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        for index in 1...4 {
            model.handle(.move(1))
            assertSelection(model, entries[index], aa: index == 4)
        }
        model.handle(.move(-1))
        assertSelection(model, entries[3], aa: false)
        model.handle(.move(1))
        assertSelection(model, entries[4], aa: true)
        for index in stride(from: 3, through: 0, by: -1) {
            model.handle(.move(-1))
            assertSelection(model, entries[index], aa: index == 0)
        }
    }

    func testRichFirstAndLastBoundsKeepAaFocused() {
        let entries = [rich("first"), plain("middle"), rich("last")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        model.handle(.move(-1))
        assertSelection(model, entries[0], aa: true)
        model.handle(.move(1))
        model.handle(.move(1))
        model.handle(.move(1))
        assertSelection(model, entries[2], aa: true)
        model.handle(.move(-1))
        model.handle(.move(-1))
        assertSelection(model, entries[0], aa: true)
    }

    func testIneligibleFirstAndLastBoundsDoNotEraseAaPreference() {
        let entries = [plain("first"), rich("middle"), image()]
        let model = picker(entries)
        model.handle(.move(1))
        model.handle(.focusPlainText)
        model.handle(.move(-1))
        model.handle(.move(-1))
        assertSelection(model, entries[0], aa: false)
        model.handle(.move(1))
        assertSelection(model, entries[1], aa: true)
        model.handle(.move(1))
        model.handle(.move(1))
        assertSelection(model, entries[2], aa: false)
        model.handle(.move(-1))
        assertSelection(model, entries[1], aa: true)
    }

    func testEnterOnRestoredAaConvertsDestinationRichText() throws {
        for copyOnly in [false, true] {
            for direction in [-1, 1] {
                let entries = [rich("first text"), image(), rich("last text")]
                let model = picker(entries)
                if direction == -1 {
                    model.handle(.move(1))
                    model.handle(.move(1))
                }
                model.handle(.focusPlainText)
                model.handle(.move(direction))
                model.handle(.move(direction))
                var choices: [(HistoryEntry, Bool)] = []
                model.choose = { choices.append(($0, $1)) }
                model.handle(.activate(copyOnly: copyOnly))
                XCTAssertEqual(choices.count, 1)
                let chosen = try XCTUnwrap(choices.first)
                XCTAssertEqual(chosen.1, copyOnly)
                XCTAssertEqual(chosen.0.items.count, 1)
                let item = try XCTUnwrap(chosen.0.items.first)
                XCTAssertEqual(item.representations.map(\.type), ["public.utf8-plain-text"])
                XCTAssertEqual(item.representations.first?.data,
                               Data((direction == 1 ? "last text" : "first text").utf8))
            }
        }
    }

    func testEnterOnIneligibleRowActivatesOriginalEntryWithoutConversion() throws {
        for middle in [plain("plain"), image(), dictation()] {
            for copyOnly in [false, true] {
                for direction in [-1, 1] {
                    let entries = [rich("first"), middle, rich("last")]
                    let model = picker(entries)
                    if direction == -1 {
                        model.handle(.move(1))
                        model.handle(.move(1))
                    }
                    model.handle(.focusPlainText)
                    model.handle(.move(direction))
                    var choices: [(HistoryEntry, Bool)] = []
                    model.choose = { choices.append(($0, $1)) }
                    model.handle(.activate(copyOnly: copyOnly))
                    XCTAssertEqual(choices.count, 1)
                    let chosen = try XCTUnwrap(choices.first)
                    XCTAssertEqual(chosen.0.id, middle.id)
                    XCTAssertEqual(chosen.1, copyOnly)
                    XCTAssertEqual(chosen.0.items.count, middle.items.count)
                    XCTAssertEqual(chosen.0.items.first?.representations.map(\.type),
                                   middle.items.first?.representations.map(\.type))
                    XCTAssertEqual(chosen.0.items.first?.representations.map(\.data),
                                   middle.items.first?.representations.map(\.data))
                }
            }
        }
    }

    func testExplicitRowFocusWhileAaIsUnavailableCancelsPreference() {
        let entries = [rich("first"), image(), rich("last")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        model.handle(.move(1))
        model.handle(.focusRow)
        model.handle(.move(1))
        assertSelection(model, entries[2], aa: false)
        model.handle(.move(-1))
        model.handle(.move(-1))
        assertSelection(model, entries[0], aa: false)
    }

    func testFreshPresentationClearsRememberedAaPreference() {
        let entries = [rich("first"), image(), rich("last")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        model.handle(.move(1))
        model.resetForPresentation()
        model.handle(.focusRow)
        assertSelection(model, entries[0], aa: false)
        model.handle(.move(1))
        model.handle(.move(1))
        assertSelection(model, entries[2], aa: false)
    }

    func testSearchAndFilterClearRememberedAaPreference() {
        let entries = [rich("first"), image(), rich("last")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        model.handle(.move(1))
        model.handle(.focusSearch)
        XCTAssertEqual(model.keyboardFocus, .search)
        model.handle(.focusRow)
        model.handle(.move(1))
        XCTAssertEqual(model.keyboardFocus, .row)

        let filtered = picker(entries)
        filtered.handle(.focusPlainText)
        filtered.handle(.move(1))
        filtered.handle(.filter(.clipboard))
        filtered.handle(.focusRow)
        filtered.handle(.move(1))
        filtered.handle(.move(1))
        assertSelection(filtered, entries[2], aa: false)
    }

    func testPageNavigationPreservesAaAcrossUnavailableRows() throws {
        // Enough alternating rows to include several pages, independent of page size.
        let entries = (0..<41).map { index in
            index.isMultiple(of: 2) ? rich("rich \(index)") : plain("plain \(index)")
        }
        let model = picker(entries)
        model.handle(.focusPlainText)
        for direction in [1, 1, -1, 1, -1, -1] {
            model.handle(.page(direction))
            let index = try XCTUnwrap(entries.firstIndex { $0.id == model.selectedID })
            assertSelection(model, entries[index], aa: index.isMultiple(of: 2))
            // Find the next rich row by arrows; paging must not have discarded intent.
            if !index.isMultiple(of: 2) {
                model.handle(.move(direction))
                let adjacent = try XCTUnwrap(entries.firstIndex { $0.id == model.selectedID })
                assertSelection(model, entries[adjacent], aa: true)
            }
        }
    }

    func testStationaryPointerPreservesAaButDeliberateHoverClearsIt() {
        let entries = [rich("first"), image(), rich("last")]
        let model = picker(entries)
        model.pointerLocation = { .zero }
        model.resetForPresentation()
        model.handle(.focusRow)
        model.handle(.focusPlainText)
        model.hover(entries[1].id, at: .zero)
        assertSelection(model, entries[0], aa: true)
        model.hover(entries[1].id, at: NSPoint(x: 1, y: 0))
        assertSelection(model, entries[1], aa: false)
        model.handle(.move(1))
        assertSelection(model, entries[2], aa: false)
    }

    func testTypingSearchClearsRememberedAaPreference() {
        let entries = [rich("match first"), plain("match middle"), rich("match last")]
        let model = picker(entries)
        model.handle(.focusPlainText)
        model.handle(.move(1))
        model.query = "match"
        model.searchChanged()
        model.handle(.focusRow)
        model.handle(.move(1))
        model.handle(.move(1))
        assertSelection(model, entries[2], aa: false)
    }
}
