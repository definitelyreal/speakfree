// Claude · 2026-07-29 · Session: 6277a78f-7ff9-4d99-b9d1-f9ee9afe952a
//
// 2026-07-29 report: "bad commas". Parakeet hears the spoken word "comma" as "comment" or
// "common" — 6 occurrences in one day's corpus. Both are REAL words, so they join the
// kamala/karma rule shape (punctuation required on BOTH sides), never the loose non-word tail
// used for kama/kana/komma. The false-positive tests below are the whole point: every negative
// case is a synthetic sentence with the exact shape of a real string from the 2026-07-29 corpus.

import XCTest
@testable import SpeakFreeLib

final class CommaMishearTests: XCTestCase {

    private func hybrid(_ text: String) -> String {
        TextPostProcessor.process(text, hybrid: true)
    }

    // MARK: - Converts (the reported defect)

    /// Synthetic reproduction of a 2026-07-29 chat dictation: the speaker said
    /// "soup comma let me know".
    func test_commentAfterPeriodBecomesComma() {
        let out = hybrid("added some fresh basil and salt on the soup. Comment, let me know if it seems too much")
        XCTAssertFalse(out.lowercased().contains("comment"), "got: \(out)")
        XCTAssertTrue(out.contains("soup, let me know"), "got: \(out)")
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
        XCTAssertEqual(hybrid("I've always wanted to bake fresh bread, comment"),
                       "I've always wanted to bake fresh bread,")
        XCTAssertEqual(hybrid("That is the plan: coma"), "That is the plan,")
    }

    /// 2026-08-22 regression: Parakeet split the spoken "comma" into two capitalised
    /// tokens "Ka Ma" ("Yeah, Ka Ma, it also becomes…"). The non-word bigram joins the loose
    /// kama/kana family (preceding-punctuation garble signature), not the both-sides real-word rule.
    func test_kaMaSplitTokenBecomesComma() {
        let out = hybrid("Yeah, Ka Ma, it also becomes the way that we plan weekly meals")
        XCTAssertFalse(out.contains("Ka Ma"), "got: \(out)")
        XCTAssertTrue(out.contains("Yeah, it also becomes"), "got: \(out)")
    }

    func test_discourseMarkerRealWordHomophoneBecomesComma() {
        XCTAssertEqual(hybrid("Shoot comment, I thought I sent it"),
                       "Shoot, I thought I sent it")
        XCTAssertEqual(hybrid("Okay awesome comment. I think we're set"),
                       "Okay awesome, I think we're set")
    }

    // MARK: - Must NOT convert — all four reproduce real strings' shapes from the same day

    /// Noun use mid-sentence: determiner + modifier + "comment" + noun.
    func test_realWordCommentMidSentenceIsUntouched() {
        let input = "One thing is that the right comment box and the logo should move"
        XCTAssertEqual(hybrid(input), input)
    }

    /// Plural noun directly before a capitalised pronoun.
    func test_pluralCommentsIsUntouched() {
        let input = "in quick comments I may have mentioned it"
        XCTAssertEqual(hybrid(input), input)
    }

    /// A complaint-shaped message: plural "comments and" plus "should be common in".
    func test_complaintShapedTextIsUntouched() {
        let input = "there are typos, in fact, odd sentences, and kind comments and notes that should be common in drafts"
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

    // MARK: - Sentence-medial shapes (2026-08-14, looser conversion approved)
    // Positive cases are synthetic sentences with the shapes of the 8/13-14 dogfood corpus.

    /// Shape 1: bare word before, punctuation after. In the original failure, Whisper on the
    /// same audio heard "…, comma, I would love".
    func test_bareBeforePunctAfterConverts() {
        let out = hybrid("very familiar with the baking side comment, I would love to chat")
        XCTAssertTrue(out.contains("baking side, I would love"), "got: \(out)")
        let out2 = hybrid("There's lots of different lunch options common. Maybe that's better")
        XCTAssertTrue(out2.contains("lunch options, Maybe"), "got: \(out2)")
    }

    /// Shape 2: no punctuation anywhere, clause-continuing conjunction after.
    func test_bareBothSidesBeforeConjunctionConverts() {
        let out = hybrid("think about what holds other things comment and think about cost")
        XCTAssertTrue(out.contains("holds other things, and think"), "got: \(out)")
    }

    /// DELIBERATE non-conversions (VERIFY round 2): a determiner/possessive/copula two tokens
    /// back is the signature of a real noun phrase ("your GitHub comment"), and these command
    /// garbles share it exactly ("your walk comment"). Converting them would silently delete
    /// legitimate nouns, so they stay unconverted — the acoustic layer is the right fix.
    func test_nounPhraseSignatureTwoTokensBackStaysUnconverted() {
        let cases = [
            "It looks like I'll have to miss your walk comment since we're cooking",
            "you're assuming that bread baking is fine comment. There's more to it",
            "could be from anyone at any point in the yard comment, so I would suggest",
        ]
        for input in cases {
            let out = hybrid(input)
            XCTAssertTrue(out.lowercased().contains("comment"),
                          "documented loss changed behavior: \(input) → \(out)")
        }
    }

    /// Shape 3: punctuation before (consumed), clause-starter after.
    func test_punctBeforeClauseStarterAfterConverts() {
        let out = hybrid("The bread bakes for about 40 minutes. Common need to cool it at 6.40 though")
        XCTAssertTrue(out.contains("40 minutes, need to cool"), "got: \(out)")
        let out2 = hybrid("useful for my day-to-day chores. Common to separate the laundry")
        XCTAssertTrue(out2.contains("chores, to separate"), "got: \(out2)")
        let out3 = hybrid("that would work too. Comment either way, period.")
        XCTAssertTrue(out3.contains("work too, either way"), "got: \(out3)")
    }

    // MARK: - Sentence-medial guards: preceding word marks legitimate prose

    func test_precedingDeterminerBlocksMedialConversion() {
        // Corpus shapes with neutral wording. "a/the/this/latest" and copulas/comparatives
        // protect the noun. The last three are the VERIFY round-1 adversarial finds
        // (2026-08-14): compound modifiers ("long/blog/review comment") with the determiner
        // 2+ tokens back.
        let cases = [
            "it's a comment by a user, not a reply",
            "send replies to this comment. Would you",
            "C this latest comment made by the bot.",
            "that was more common, period",
            "something there is common and it feels important",
            "I want you to comment, then merge it",
            "He posted a long comment. It was rude",
            "Sarcasm in a code review comment which nobody reads",
            "Please read the blog comment. Then reply to it",
            "She left a snarky comment. Then she logged off",
            "I read your GitHub comment, and I agree with it",
            "Bike theft here is increasingly common. Lock it up",
            "His parting comment, which stung, was unnecessary",
            "I appreciated Sarah's comment, but I disagreed with it",
        ]
        for input in cases {
            let out = hybrid(input)
            XCTAssertTrue(out.lowercased().contains("comment") || out.lowercased().contains("common"),
                          "legit word deleted from: \(input) → \(out)")
        }
    }

    /// Followers outside the closed clause-starter sets must not trigger shapes 2/3.
    func test_nonClauseFollowerStaysUntouched() {
        let input = "Read the thread. Comment moderation is a mess"
        XCTAssertEqual(hybrid(input), input)
        let input2 = "the picnic was common knowledge around here"
        XCTAssertEqual(hybrid(input2), input2)
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
