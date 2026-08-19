// Claude · 2026-07-29 · Session: 6277a78f-7ff9-4d99-b9d1-f9ee9afe952a
//
// Michael, 2026-07-29: "additional spaces should be tracked so that you are able to see them."
//
// Spacing damage is the one dictation defect NOTHING could observe. The recordings corpus stores
// the dictation alone (.txt), so a spurious leading space or a missing one lives only in the
// target app — 2026-07-29's corpus showed 0 leading spaces, 0 doubles, 0 space-before-punct while
// Michael was actively looking at extra spaces on screen. `spacingDiagnosis` classifies the seam
// so the diagnostic log can count what only he could see.

import XCTest
@testable import SpeakFreeLib

final class SpacingDiagnosisTests: XCTestCase {

    private func diagnose(_ context: String?, _ insert: String) -> TextInserter.SpacingDiagnosis {
        TextInserter.spacingDiagnosis(contextBefore: context, insertText: insert)
    }

    // MARK: - The defect Michael reported

    /// Field already ends in a space AND the pipeline prepended one → "word  next".
    func test_extraSpace_whenFieldEndsInSpaceAndSpaceIsPrepended() {
        XCTAssertEqual(diagnose("Send this ", " tomorrow"), .extraSpace)
    }

    func test_extraSpace_afterNewline() {
        XCTAssertEqual(diagnose("first line\n", " second"), .extraSpace)
    }

    // MARK: - The opposite defect

    /// Printable butted against printable → "wordnext". This is what a blind context produces
    /// when prependSpace defaults to false mid-sentence.
    func test_missingSpace_whenBothSidesArePrintable() {
        XCTAssertEqual(diagnose("I was thinking", "about it"), .missingSpace)
    }

    func test_missingSpace_afterSentencePunctuation() {
        XCTAssertEqual(diagnose("Done.", "Next thing"), .missingSpace)
    }

    // MARK: - Correct seams must stay silent, or the signal is worthless

    func test_ok_singleSpaceFromPrepend() {
        XCTAssertEqual(diagnose("I was thinking", " about it"), .ok)
    }

    func test_ok_fieldEndsInSpaceAndNonePrepended() {
        XCTAssertEqual(diagnose("Send this ", "tomorrow"), .ok)
    }

    /// Opening brackets and curly-open quotes attach to what follows — not a defect. Straight
    /// `"`/`'` are excluded: one glyph is both open and close, and closers (`."`, `dogs'`) cluster
    /// after sentence-final punctuation where a space belongs, so they diagnose as missingSpace
    /// rather than ok (VERIFY 2026-08-18).
    func test_ok_afterOpeningBracketOrQuote() {
        for opener in ["(", "[", "“", "-", "/"] {
            XCTAssertEqual(diagnose("text \(opener)", "inner"), .ok,
                           "no space belongs after \(opener)")
        }
    }

    /// Straight quote / apostrophe are ambiguous open-vs-close; default to expecting a space so
    /// closing-quote seams (`"stop."` + `Then`) do not join.
    func test_missingSpace_afterStraightQuoteOrApostrophe() {
        XCTAssertEqual(diagnose("text \"", "inner"), .missingSpace)
        XCTAssertEqual(diagnose("dogs'", "bones"), .missingSpace)
    }

    // MARK: - Blind is its own verdict, never silently "ok"

    /// 75-91% of 2026-07-29's dictations had no cursor context. Counting the blind seams is the
    /// point: reporting them as `ok` would hide the real finding.
    func test_blind_whenNoContextCaptured() {
        XCTAssertEqual(diagnose(nil, "some text"), .blind)
        XCTAssertEqual(diagnose("", "some text"), .blind)
    }

    func test_blind_whenInsertTextIsEmpty() {
        XCTAssertEqual(diagnose("existing", ""), .blind)
    }

    // MARK: - The log must not leak message content

    func test_charClassNeverEchoesTheCharacter() {
        XCTAssertEqual(TextInserter.charClass("q"), "letter")
        XCTAssertEqual(TextInserter.charClass("7"), "digit")
        XCTAssertEqual(TextInserter.charClass(" "), "space")
        XCTAssertEqual(TextInserter.charClass("\n"), "newline")
        XCTAssertEqual(TextInserter.charClass(","), "punct")
        XCTAssertEqual(TextInserter.charClass(nil), "none")
        // Every class label is a fixed vocabulary word, so no dictated character can reach the log.
        let vocabulary: Set<String> = ["letter", "digit", "space", "newline", "punct", "other", "none"]
        for ch in "Confidential secret 42!,\n" {
            XCTAssertTrue(vocabulary.contains(TextInserter.charClass(ch)),
                          "charClass leaked something other than a fixed label for \(ch.debugDescription)")
        }
    }
}
