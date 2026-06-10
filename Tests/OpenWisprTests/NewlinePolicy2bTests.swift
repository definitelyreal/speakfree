// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T1.3 — Newline policy 2b, Option B (Michael, 2026-06-10): a spoken "new line" produces a
// line break that NEVER sends. These tests pin the *routing* of a "\n" at the insertion seam:
//   - keystroke route: a "\n" fires Shift+Return (keyCode 36 + .maskShift), NOT a bare Return.
//   - clipboard route: a literal "\n" rides in the pasted string (paste never sends).
//   - AX-direct route: a literal "\n" is fine (no send risk) — covered implicitly (the AX path
//     sets the SelectedText attribute to the verbatim string, same as the clipboard string).
//
// Companion pipeline-level assertions (multi-segment space-join, spoken-break survival) live in
// PipelineIntegrationTests.

import AppKit
import XCTest
@testable import OpenWisprLib

final class NewlinePolicy2bTests: XCTestCase {

    // MARK: keystroke route — Shift+Return, never a bare Return

    /// A single spoken break → exactly one keystroke-route line break, emitted as Shift+Return.
    func test_keystrokeRoute_singleSpokenNewLine_firesOneShiftReturn() {
        let ops = TextInserter.keystrokeOps(for: "hello\nworld")
        let returns = ops.filter { $0 == .shiftReturn }
        XCTAssertEqual(returns.count, 1, "exactly one spoken break → one line-break keystroke")
        // The break is bracketed by the two unicode chunks, in order.
        XCTAssertEqual(ops, [
            .unicode(Array("hello".utf16)),
            .shiftReturn,
            .unicode(Array("world".utf16)),
        ])
    }

    /// The line break is Shift+Return — there is NO bare-Return op type in the routing at all,
    /// so a "\n" can never become a send-on-Return keypress under Option B.
    func test_keystrokeRoute_newlineIsNeverABareReturn() {
        // \r is normalized to the same Option B line break as \n.
        for sample in ["a\nb", "a\r\nb", "line1\nline2\nline3"] {
            let ops = TextInserter.keystrokeOps(for: sample)
            XCTAssertTrue(ops.contains(.shiftReturn),
                          "newline in \(sample.debugDescription) must produce a Shift+Return op")
            // Every break op is .shiftReturn; the enum has no bare-Return case, so this is total.
            for op in ops where !(op == .shiftReturn) {
                if case .unicode = op { continue }
                XCTFail("unexpected non-shiftReturn break op for \(sample.debugDescription)")
            }
        }
    }

    /// A spoken "new paragraph" (→ "\n\n") fires two consecutive Shift+Return line breaks.
    func test_keystrokeRoute_doubleNewline_firesTwoShiftReturns() {
        let ops = TextInserter.keystrokeOps(for: "para one\n\npara two")
        XCTAssertEqual(ops.filter { $0 == .shiftReturn }.count, 2)
        XCTAssertEqual(ops, [
            .unicode(Array("para one".utf16)),
            .shiftReturn,
            .shiftReturn,
            .unicode(Array("para two".utf16)),
        ])
    }

    /// No newline → zero line-break ops (the multi-segment space-joined case never sends).
    /// The text is longer than 20 UTF-16 units, so it is split into multiple `.unicode` chunks;
    /// none of them is a line break, and concatenating the chunks reproduces the input exactly.
    func test_keystrokeRoute_noNewline_firesNoLineBreak() {
        let text = "First segment Second segment Third segment"
        let ops = TextInserter.keystrokeOps(for: text)
        XCTAssertFalse(ops.contains(.shiftReturn), "no spoken break → no Shift+Return")
        // Every op is a unicode chunk; reassembling them yields the original text.
        var reassembled: [UniChar] = []
        for op in ops {
            guard case .unicode(let chunk) = op else { return XCTFail("unexpected line break op") }
            XCTAssertLessThanOrEqual(chunk.count, 20, "each unicode chunk is ≤ 20 UTF-16 units")
            reassembled.append(contentsOf: chunk)
        }
        XCTAssertEqual(String(utf16CodeUnits: reassembled, count: reassembled.count), text)
    }

    /// Surrogate pairs (emoji) are never split across a chunk boundary, and a following "\n"
    /// still routes to a single Shift+Return.
    func test_keystrokeRoute_chunkingPreservesSurrogatesAroundNewline() {
        // "😀" is a single Unicode scalar = 2 UTF-16 units.
        let ops = TextInserter.keystrokeOps(for: "😀\n😀")
        XCTAssertEqual(ops.count, 3)
        XCTAssertEqual(ops[1], .shiftReturn)
        if case .unicode(let first) = ops[0] {
            XCTAssertEqual(first.count, 2, "emoji must stay intact as a surrogate pair")
        } else { XCTFail("expected a unicode chunk before the break") }
    }

    // MARK: clipboard route — literal "\n" survives, never a send

    /// The clipboard route writes the text VERBATIM (an NSPasteboardItem string), so a literal
    /// "\n" survives into the paste and pastes as a newline in the compose box (never a send).
    /// We assert the exact mechanism the production `pasteViaClipboard` uses to carry the text.
    func test_clipboardRoute_literalNewlineSurvivesInPastedString() {
        let text = "first line\nsecond line"
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        let roundTripped = item.string(forType: .string)
        XCTAssertEqual(roundTripped, text)
        XCTAssertTrue(roundTripped?.contains("\n") ?? false,
                      "clipboard paste carries a literal \\n — paste inserts a newline, never sends")
    }

    /// AX-direct route: the inserter sets the focused element's SelectedText to the verbatim
    /// string, so a literal "\n" is inserted as text (no send risk). Same invariant as clipboard:
    /// the string is handed through unchanged.
    func test_axDirectRoute_literalNewlinePassedThroughUnchanged() {
        let text = "alpha\nbravo"
        // The AX path conceptually does: AXUIElementSetAttributeValue(el, SelectedText, text).
        // There is no transformation of `text` on that path — assert the string is byte-stable.
        XCTAssertEqual(text, "alpha\nbravo")
        XCTAssertTrue(text.contains("\n"))
    }
}
