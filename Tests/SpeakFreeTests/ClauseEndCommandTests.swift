// Claude · 2026-09-24 · punctuation pass
//
// Spoken "question mark" / "exclamation mark" at the END of a clause is the command, even when
// an adjective-modified noun precedes it ("is the oven preheated question mark?"). The
// 2026-08-24 noun guards looked only at what the phrase follows, so they left the literal words
// in the output whenever the command came after "the/that … noun". These tests pin the
// clause-end rule, the literal-noun protections that must survive it (including clause-final
// literal uses a public user will say), and the mid-sentence comma garbles added in the same
// pass. All strings are synthetic.

import XCTest
@testable import SpeakFreeLib

final class ClauseEndCommandTests: XCTestCase {

    private func p(_ t: String) -> String { TextPostProcessor.process(t, hybrid: true) }

    // MARK: - Clause-end command after a noun phrase converts

    func testCommandAfterDeterminerModifiedNounConverts() {
        XCTAssertEqual(p("Is the oven preheated question mark?"), "Is the oven preheated?")
        XCTAssertEqual(p("Did you water the plants question mark."), "Did you water the plants?")
        XCTAssertEqual(p("Is it on your laptop question mark? I looked."), "Is it on your laptop? I looked.")
        XCTAssertEqual(p("Should we paint the fence question mark"), "Should we paint the fence?")
    }

    func testCommandBeforeSpokenLineBreakConverts() {
        // Verify pass: a spoken line break is a clause end too.
        XCTAssertEqual(p("Did you lock the door question mark new line thanks"), "Did you lock the door?\nThanks")
        XCTAssertEqual(p("Did you lock the door question mark new paragraph thanks"), "Did you lock the door?\n\nThanks")
        XCTAssertEqual(p("Good luck with the move exclamation mark new line see you"), "Good luck with the move!\nSee you")
        XCTAssertEqual(p("I drew the big question mark new line"), "I drew the big question mark\n")
        XCTAssertEqual(p("Type a question mark new line"), "Type a question mark\n")
    }

    func testCommandDirectlyAfterDemonstrativeConverts() {
        XCTAssertEqual(p("Can we skip that question mark?"), "Can we skip that?")
        XCTAssertEqual(p("Could you look into this question mark."), "Could you look into this?")
    }

    func testArticleBeforeClauseEndCommandStaysLiteral() {
        // Review round 3: no word list separates an inserted article from a real object, so
        // "a/an question mark" is never rewritten (a visible leftover beats a deleted object).
        let cases = [
            "Which bus should I take a question mark?",
            "Did you forget a question mark?",
            "How do I dictate a question mark?",
            "Maybe a question mark?",
            "Wait, he sent a question mark?",
            "Does every question require a question mark?",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "article + noun changed: \(text)")
        }
    }

    func testGlyphObjectAfterDemonstrativeStaysLiteral() {
        let cases = [
            "Can you remove that question mark?",
            "Delete that question mark.",
            "Should I keep that question mark?",
            "Did you click that question mark?",
            "What's that question mark?",
            "What is that exclamation point?",
            "Delete that exclamation point.",
            "What about the third question mark?",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "glyph object changed: \(text)")
        }
    }

    func testCommandAfterNegationAtClauseEndConverts() {
        XCTAssertEqual(p("Maybe it works, maybe not question mark."), "Maybe it works, maybe not?")
    }

    func testCommandBeforeCommaAndClauseOpenerConverts() {
        XCTAssertEqual(p("Is this the right door question mark, it looks locked."),
                       "Is this the right door? It looks locked.")
    }

    func testSentenceInitialCommandBeforeQuestionInversionConverts() {
        // Round 4: only after a sentence that is itself a question.
        XCTAssertEqual(p("Was that the plan. Question mark is it still the plan?"),
                       "Was that the plan? Is it still the plan?")
        XCTAssertEqual(p("Good point. Question mark is it a symbol?"),
                       "Good point. Question mark is it a symbol?")
        XCTAssertEqual(p("Right? Question mark can you check?"), "Right? Can you check?")
    }

    func testExclamationAfterNounPhraseAtClauseEndConverts() {
        XCTAssertEqual(p("Good luck with the move exclamation mark."), "Good luck with the move!")
        XCTAssertEqual(p("See you at the party exclamation point"), "See you at the party!")
        XCTAssertEqual(p("Congrats on the new job exclamation park."), "Congrats on the new job!")
        XCTAssertEqual(p("Nice work. Exclamation, Mark."), "Nice work!")
    }

    func testClauseFinalTailGarbles() {
        XCTAssertEqual(p("What is the budget for a sequel question market."), "What is the budget for a sequel?")
        XCTAssertEqual(p("Tell me about Friday explanation market."), "Tell me about Friday!")
        XCTAssertEqual(p("Did you see the email, Kushmark?"), "Did you see the email?")
    }

    // MARK: - Literal nouns stay literal

    func testLiteralNounThatContinuesTheSentenceIsUntouched() {
        let cases = [
            "I tried to type a question mark in the search box.",
            "Remove the question mark icons from the toolbar.",
            "Add a question mark that people can click.",
            "The sign needs a question mark, not a dot.",
            "Type the word question mark.",
            "I said question mark.",
            "Where do the question marks go?",
            "She drew a red question mark.",
            "I drew a large exclamation mark.",
            "The question mark is a symbol.",
            "I drew that bright question mark on the wall",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "literal noun changed: \(text)")
        }
    }

    func testClauseFinalLiteralNounIsUntouched() {
        // Adversarial review round 1: literal uses that END a clause.
        let cases = [
            "The answer is a question mark.",
            "Replace it with a question mark.",
            "What is a question mark? It is punctuation.",
            "Is it a question mark?",
            "Can I use a question mark?",
            "You get an exclamation point.",
            "What an exclamation mark.",
            "The cat, a question mark.",
            "A question mark.",
            "An exclamation mark!",
            "The question mark.",
            "The one with the question mark.",
            "I like the exclamation marker",
            "His future is a big question mark.",
            "Click the question mark Google shows",
            // Adversarial review round 2: the figurative idiom and more glyph-object shapes.
            "The timeline is still a big question mark.",
            "That's a big question mark.",
            "There's a huge question mark.",
            "Funding remains a big question mark.",
            "That deserves a real exclamation mark.",
            "Should we change the period to a question mark?",
            "Does the sentence end in a question mark?",
            "Do you see a question mark?",
            "Should I include a question mark?",
            "Can you insert a question mark?",
            "Swap the dot for a question mark?",
            "Does that need an extra question mark?",
            "Was it not a question mark?",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "clause-final literal noun changed: \(text)")
        }
    }

    func testLiteralNounBeforeCommaIsUntouched() {
        let cases = [
            "I drew the big question mark, and it looked odd.",
            "My logo has a bold question mark, which I like.",
            "The big question mark, I think, is funding.",
            "The real question mark, it seems, is the budget.",
            "The blue exclamation point, on the left, is new.",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "literal noun before comma changed: \(text)")
        }
    }

    func testContractedWhatsQuestionConverts() {
        XCTAssertEqual(p("What's the plan question mark?"), "What's the plan?")
        XCTAssertEqual(p("Where’s the charger question mark."), "Where’s the charger?")
    }

    func testMidSentenceBareCommandStillConverts() {
        XCTAssertEqual(p("how are you question mark I am fine"), "how are you? I am fine")
    }

    // MARK: - Round 4: the clause decides

    func testQuestionClauseConvertsAfterNounPhrase() {
        XCTAssertEqual(p("Where is the remote question mark"), "Where is the remote?")
        XCTAssertEqual(p("What is the address question mark."), "What is the address?")
        XCTAssertEqual(p("What time is the meeting question mark"), "What time is the meeting?")
        XCTAssertEqual(p("Is this a problem question mark"), "Is this a problem?")
        XCTAssertEqual(p("What did you type question mark"), "What did you type?")
        XCTAssertEqual(p("You fixed that, right question mark"), "You fixed that, right?")
        XCTAssertEqual(p("Tea or coffee question mark"), "Tea or coffee?")
        XCTAssertEqual(p("Does that still happen any question mark?"), "Does that still happen any?")
        XCTAssertEqual(p("Can you fix that question mark?"), "Can you fix that?")
        XCTAssertEqual(p("Is the store open question mark"), "Is the store open?")
        XCTAssertEqual(p("Is that real question mark"), "Is that real?")
        XCTAssertEqual(p("Did he finish first question mark"), "Did he finish first?")
        XCTAssertEqual(p("Does Sam know the plan question mark"), "Does Sam know the plan?")
    }

    func testDeclarativeQuestionAfterNounPhraseConverts() {
        XCTAssertEqual(p("You remember the party question mark"), "You remember the party?")
        XCTAssertEqual(p("Let me call you in a few question mark."), "Let me call you in a few?")
        XCTAssertEqual(p("I should say no question mark."), "I should say no?")
        XCTAssertEqual(p("We could schedule a call exclamation mark."), "We could schedule a call!")
        XCTAssertEqual(p("They moved the meeting question mark"), "They moved the meeting?")
        XCTAssertEqual(p("Look at the view exclamation mark"), "Look at the view!")
        XCTAssertEqual(p("I loved the ending exclamation mark"), "I loved the ending!")
        XCTAssertEqual(p("You left it on the old remote question mark"), "You left it on the old remote?")
        XCTAssertEqual(p("Hi Sam exclamation mark how was the trip question mark"),
                       "Hi Sam! How was the trip?")
        // Known limit: in a question, a plain adjective head converts, because the tagger
        // also calls real clause-final nouns adjectives ("for the podcast question mark").
        XCTAssertEqual(p("Did you see the weird question mark"), "Did you see the weird?")
    }

    func testClauseActingOnTheGlyphStaysLiteral() {
        let cases = [
            "Click the circled question mark.",
            "Hover over the help question mark.",
            "Type the inverted question mark.",
            "Use the Spanish question mark.",
            "Draw an upside-down question mark.",
            "Add an inverted exclamation mark.",
            "Can you add the inverted exclamation mark",
            "Look at this question mark, it's huge.",
            "I noticed that question mark.",
            "Change that question mark.",
            "It is the main question mark.",
            "type question mark",
            "Press question mark to open help.",
            // Review round 1: negated imperatives, multi-word modifiers, bare adjectives.
            "Don't click the circled question mark.",
            "Do not remove the circled question mark.",
            "Don't touch the circled question mark.",
            "Have a look at the circled question mark.",
            "Draw an upside down question mark.",
            "Click the circled help question mark.",
            "He stared at the strange question mark.",
            "There's a weird question mark.",
            "The printout had a faded question mark.",
            "Everyone loved the dramatic exclamation mark.",
            // Review round 2.
            "What happened to the circled question mark",
            "I typed question mark in the search box.",
            // Review round 3: two-word modifiers and irregular participles in statements.
            "The icon is a small circled question mark.",
            "He stared at the upside down question mark.",
            "The logo has a hand-drawn question mark.",
            "The app shows a greyed out question mark.",
            "The file shows up with a broken question mark.",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "glyph clause changed: \(text)")
        }
    }

    func testSpokenLineBreakAfterCommandKeepsTheBreak() {
        XCTAssertEqual(p("Did you see it question mark. New line. Thanks"), "Did you see it?\nThanks")
    }

    func testNameInAListIsNotAComma() {
        XCTAssertEqual(p("Sam, Karma, and Lee came."), "Sam, Karma, and Lee came.")
        XCTAssertEqual(p("Lee. Kamala, or Sam, will drive."), "Lee. Kamala, or Sam, will drive.")
    }

    func testEtcFollowedByARealVerbSurvives() {
        XCTAssertEqual(p("Items etc. appeared"), "Items etc. appeared")
    }

    // MARK: - Mid-sentence comma garbles

    func testCommaGarblesBetweenClauseMarksConvert() {
        XCTAssertEqual(p("Okay, come a can you open the gate?"), "Okay, can you open the gate?")
        XCTAssertEqual(p("We listed the fruits, etc. Appeared."), "We listed the fruits, etc.")
    }

    func testRealUsesOfComeComboAndAppearedSurvive() {
        let cases = [
            "Come on, let's go.",
            "Please come a little earlier.",
            "They will come, I think, around noon.",
            "The combo meal was good.",
            "I ordered the combo, and it was cold.",
            "We have come a long way.",
            "It appeared.",
            "If you can, come, and bring a friend.",
            "Come, come, don't be shy.",
            "Please, come, sit down.",
            "Things fell apart. Appeared.",
            "Oh, come, you can't be serious.",
            "Sure, come, I'll save you a seat.",
            "I got the burger, combo, and a drink.",
            "We had the number three. Combo, please.",
        ]
        for text in cases {
            XCTAssertEqual(p(text), text, "real word changed: \(text)")
        }
    }
}
