// Claude · 2026-07-29 · Session: 6277a78f-7ff9-4d99-b9d1-f9ee9afe952a
//
// Michael, 2026-07-29: "bad commas". Parakeet hears the spoken word "comma" as "comment" or
// "common" — 6 occurrences in one day's corpus. Both are REAL words, so they join the
// kamala/karma rule shape (punctuation required on BOTH sides), never the loose non-word tail
// used for kama/kana/komma. The false-positive tests below are the whole point: every negative
// case is a real string from the 2026-07-29 corpus.

import XCTest
@testable import SpeakFreeLib

final class CommaMishearTests: XCTestCase {

    private func hybrid(_ text: String) -> String {
        TextPostProcessor.process(text, hybrid: true)
    }

    // MARK: - Converts (the reported defect)

    /// Real 2026-07-29 00:17 dictation into Slack. He said "cheek comma let me know".
    func test_commentAfterPeriodBecomesComma() {
        let out = hybrid("added some light wrap and glow on her cheek. Comment, let me know if it seems extreme")
        XCTAssertFalse(out.lowercased().contains("comment"), "got: \(out)")
        XCTAssertTrue(out.contains("cheek, let me know"), "got: \(out)")
    }

    func test_commonAfterPeriodBecomesComma() {
        let out = hybrid("that was the plan. Common, then we shipped it")
        XCTAssertFalse(out.lowercased().contains("common"), "got: \(out)")
        XCTAssertTrue(out.contains("plan, then we shipped it"), "got: \(out)")
    }

    func test_commentAfterCommaBecomesComma() {
        let out = hybrid("first thing, comment. second thing")
        XCTAssertFalse(out.lowercased().contains("comment"), "got: \(out)")
    }

    func test_trailingRealWordHomophoneAfterPunctuationBecomesComma() {
        XCTAssertEqual(hybrid("I've always wanted to go to Turkey, comment"),
                       "I've always wanted to go to Turkey,")
        XCTAssertEqual(hybrid("That is the plan: coma"), "That is the plan,")
    }

    func test_discourseMarkerRealWordHomophoneBecomesComma() {
        XCTAssertEqual(hybrid("Shoot comment, I thought I sent it"),
                       "Shoot, I thought I sent it")
        XCTAssertEqual(hybrid("Okay awesome comment. I think we're set"),
                       "Okay awesome, I think we're set")
    }

    // MARK: - Must NOT convert — all four are real strings from the same day's corpus

    /// "One thing is that the right comment bar and the meme should…" (00:36, Chrome)
    func test_realWordCommentMidSentenceIsUntouched() {
        let input = "One thing is that the right comment bar and the meme should move"
        XCTAssertEqual(hybrid(input), input)
    }

    /// "…and in off-handed comments I may have talked about…" (15:21)
    func test_pluralCommentsIsUntouched() {
        let input = "in off-handed comments I may have talked about it"
        XCTAssertEqual(hybrid(input), input)
    }

    /// Michael's own complaint message (15:59) — "bad comments and things that should be common in"
    func test_michaelsComplaintTextIsUntouched() {
        let input = "there are spaces, in fact, error sentences, and bad comments and things that should be common in favours"
        XCTAssertEqual(hybrid(input), input)
    }

    /// The word genuinely starting a sentence, with no trailing punctuation, must survive —
    /// this is the failure mode that deleted "Comma" and "Colon" in the 2026-07-15 review.
    func test_sentenceInitialCommentWithoutTrailingPunctIsUntouched() {
        let input = "Read the thread. Comment threads are a mess"
        XCTAssertEqual(hybrid(input), input)
        let input2 = "That is unusual. Common sense would say otherwise"
        XCTAssertEqual(hybrid(input2), input2)
    }

    func test_realComaAndCommentNounsStayUntouched() {
        XCTAssertEqual(hybrid("The patient remained in a coma."),
                       "The patient remained in a coma.")
        XCTAssertEqual(hybrid("Please leave a comment."), "Please leave a comment.")
    }

    // MARK: - The existing family must not regress

    func test_existingCommaHomophonesStillConvert() {
        XCTAssertFalse(hybrid("unreal. Kama have you seen it").lowercased().contains("kama"))
        XCTAssertFalse(hybrid("I got your text. Karma, I haven't had time").lowercased().contains("karma"))
    }

    /// comment/common must NOT be in the unguarded spoken-mode table, for the same reason
    /// kamala/karma are excluded: they are real words.
    func test_commentIsNotInUnguardedSpokenFallback() {
        let out = TextPostProcessor.process("leave a comment on the post", hybrid: false)
        XCTAssertTrue(out.contains("comment"), "spoken mode must not strip the real word: \(out)")
    }
}
