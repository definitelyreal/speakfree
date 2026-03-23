import XCTest
@testable import OpenWisprLib

final class TextPostProcessorTests: XCTestCase {

    func testPeriodReplacement() {
        XCTAssertEqual(TextPostProcessor.process("hello period"), "hello.")
    }

    func testCommaReplacement() {
        XCTAssertEqual(TextPostProcessor.process("one comma two"), "one, two")
    }

    func testQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("how are you question mark"), "how are you?")
    }

    func testExclamationMark() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation mark"), "wow!")
    }

    func testExclamationPoint() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation point"), "wow!")
    }

    func testColon() {
        XCTAssertEqual(TextPostProcessor.process("note colon"), "note:")
    }

    func testSemicolon() {
        XCTAssertEqual(TextPostProcessor.process("first semicolon second"), "first; second")
    }

    func testEllipsis() {
        XCTAssertEqual(TextPostProcessor.process("wait ellipsis"), "wait...")
    }

    func testNewLine() {
        XCTAssertEqual(TextPostProcessor.process("hello new line world"), "hello \n world")
    }

    func testNewParagraph() {
        XCTAssertEqual(TextPostProcessor.process("hello new paragraph world"), "hello \n\n world")
    }

    func testOpenCloseQuotes() {
        XCTAssertEqual(TextPostProcessor.process("he said open quote hello close quote"), "he said \" hello \"")
    }

    func testOpenCloseParens() {
        XCTAssertEqual(TextPostProcessor.process("open paren note close paren"), "( note )")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(TextPostProcessor.process("hello Period"), "hello.")
    }

    func testMultiplePunctuationInOneSentence() {
        XCTAssertEqual(TextPostProcessor.process("hello comma how are you question mark"), "hello, how are you?")
    }

    func testSpacingFixRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello , world"), "hello, world")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(TextPostProcessor.process("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(TextPostProcessor.process(""), "")
    }

    func testFullStop() {
        XCTAssertEqual(TextPostProcessor.process("done full stop"), "done.")
    }

    func testDash() {
        XCTAssertEqual(TextPostProcessor.process("one dash two"), "one  — two")
    }

    func testHyphen() {
        XCTAssertEqual(TextPostProcessor.process("well hyphen known"), "well - known")
    }

    func testSemiColonTwoWords() {
        XCTAssertEqual(TextPostProcessor.process("first semi colon second"), "first; second")
    }

    func testNewlineSingleWord() {
        XCTAssertEqual(TextPostProcessor.process("hello newline world"), "hello \n world")
    }

    func testEnsureSpaceAfterPunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello,world"), "hello, world")
    }

    // =========================================================================
    // MARK: - Hybrid Punctuation Mode Tests (50 cases)
    //
    // In hybrid mode, whisper auto-punctuates AND the user says spoken
    // punctuation words. This creates conflicts we need to handle.
    //
    // Each test notes whether the CURRENT implementation would PASS or FAIL.
    // =========================================================================

    // -------------------------------------------------------------------------
    // MARK: Category 1 — Basic spoken punctuation (clean input, no whisper conflict)
    // -------------------------------------------------------------------------

    // 1. Basic period at end
    // CURRENT: PASS — "hello period" → replace "period" → "hello." → fixSpacing removes space → "hello."
    func testHybrid01_basicPeriod() {
        XCTAssertEqual(TextPostProcessor.process("hello period"), "hello.")
    }

    // 2. Basic comma mid-sentence
    // CURRENT: PASS — "one comma two" → "one , two" → fixSpacing → "one, two"
    func testHybrid02_basicComma() {
        XCTAssertEqual(TextPostProcessor.process("one comma two"), "one, two")
    }

    // 3. Basic question mark
    // CURRENT: PASS — "how are you question mark" → "how are you ?" → fixSpacing → "how are you?"
    func testHybrid03_basicQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("how are you question mark"), "how are you?")
    }

    // 4. Basic exclamation mark
    // CURRENT: PASS — "wow exclamation mark" → "wow !" → fixSpacing → "wow!"
    func testHybrid04_basicExclamationMark() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation mark"), "wow!")
    }

    // 5. Basic ellipsis
    // CURRENT: PASS — "and then ellipsis" → "and then ..." → fixSpacing doesn't touch "..." → "and then ..."
    // Wait — fixSpacing regex is \s+([.,?!:;]) — "..." starts with "." so it matches.
    // "and then ..." → fixSpacing removes space before "." → "and then..."
    // Then ensureSpaceAfter won't fire because nothing after "..."
    // CURRENT: PASS
    func testHybrid05_basicEllipsis() {
        XCTAssertEqual(TextPostProcessor.process("and then ellipsis"), "and then...")
    }

    // 6. Basic colon
    // CURRENT: PASS — "note colon here" → "note : here" → fixSpacing → "note: here"
    func testHybrid06_basicColon() {
        XCTAssertEqual(TextPostProcessor.process("note colon here it is"), "note: here it is")
    }

    // 7. Basic semicolon (one word)
    // CURRENT: PASS — "first semicolon then" → "first ; then" → fixSpacing → "first; then"
    func testHybrid07_basicSemicolon() {
        XCTAssertEqual(TextPostProcessor.process("first semicolon then"), "first; then")
    }

    // 8. "Komma" variant (the [ck]omma pattern)
    // CURRENT: PASS — "one komma two" → "one , two" → "one, two"
    func testHybrid08_kommaVariant() {
        XCTAssertEqual(TextPostProcessor.process("one komma two"), "one, two")
    }

    // 9. Exclamation point variant
    // CURRENT: PASS — "great exclamation point" → "great !" → "great!"
    func testHybrid09_exclamationPoint() {
        XCTAssertEqual(TextPostProcessor.process("great exclamation point"), "great!")
    }

    // 10. Full stop variant
    // CURRENT: PASS — "done full stop" → "done." → "done."
    func testHybrid10_fullStop() {
        XCTAssertEqual(TextPostProcessor.process("the end full stop"), "the end.")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 2 — Hybrid conflicts (whisper auto-punctuates + spoken word)
    // -------------------------------------------------------------------------

    // 11. Whisper adds period AND user said "period" — double period
    // Input: "Hello. Period." (whisper punctuated the sentence, then "period" is a new sentence)
    // Step 1 replace: "Hello. ." → fixSpacing: "Hello.." → collapse: ".." not handled → "Hello.."
    // ensureSpaceAfter: no \w after ".." → "Hello.."
    // CURRENT: FAIL — produces "Hello.." instead of "Hello."
    // BUG: collapseAdjacentPunctuation doesn't handle ".." (two consecutive periods)
    func testHybrid11_whisperPeriodPlusSpokenPeriod() {
        XCTAssertEqual(TextPostProcessor.process("Hello. Period."), "Hello.")
    }

    // 12. Whisper adds comma before spoken exclamation mark
    // Input: "Great, exclamation mark." (whisper added comma after "Great" and period at end)
    // Step 1 replace: "Great, !." → fixSpacing: "Great,!." → collapse: ",!" → "!" then no ".!" rule
    // Wait — collapse step 1: [,;:]\s*[.!?] matches ",!" → "Great!."
    // collapse step 2: no "." before [!?] pattern matches → stays "Great!."
    // Hmm, "!." — the period AFTER ! is not handled by collapse.
    // CURRENT: FAIL — produces "Great!." instead of "Great!"
    // BUG: trailing whisper period after spoken exclamation not removed
    func testHybrid12_whisperCommaBeforeSpokenExclamation() {
        XCTAssertEqual(TextPostProcessor.process("Great, exclamation mark."), "Great!")
    }

    // 13. Whisper adds comma before spoken question mark
    // Input: "Really, question mark." → replace: "Really, ?." → fixSpacing: "Really,?."
    // collapse step 1: ",?" → "Really?." → step 2: no ".!" match (it's ".") → "Really?."
    // CURRENT: FAIL — produces "Really?." instead of "Really?"
    // BUG: trailing whisper period after spoken question mark not removed
    func testHybrid13_whisperCommaBeforeSpokenQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("Really, question mark."), "Really?")
    }

    // 14. Whisper adds period before spoken exclamation mark in next "sentence"
    // Input: "Amazing. Exclamation mark." → replace: "Amazing. !." → fixSpacing: "Amazing.!."
    // collapse step 1: no [,;:] match → skip. step 2: ".!" → "!" → "Amazing!."
    // Wait — ".!" matches \.\s*([!?]) → replaces with "!" → "Amazing!."
    // But then we still have "!." which isn't handled.
    // CURRENT: FAIL — produces "Amazing!." instead of "Amazing!"
    // BUG: trailing period after exclamation not handled
    func testHybrid14_whisperPeriodBeforeSpokenExclamation() {
        XCTAssertEqual(TextPostProcessor.process("Amazing. Exclamation mark."), "Amazing!")
    }

    // 15. Whisper adds period, user said "question mark"
    // Input: "Is that so. Question mark." → replace: "Is that so. ?." → fixSpacing: "Is that so.?."
    // collapse step 1: no match. step 2: ".?" → "?" → "Is that so?."
    // Still has "?." — not handled.
    // CURRENT: FAIL — produces "Is that so?." instead of "Is that so?"
    // BUG: trailing period after question mark not handled
    func testHybrid15_whisperPeriodBeforeSpokenQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("Is that so. Question mark."), "Is that so?")
    }

    // 16. Whisper adds comma, user said "period"
    // Input: "Done, period." → replace: "Done, .." → fixSpacing: "Done,.."
    // collapse step 1: [,]\s*[.] → matches ",." → "Done." then second "." → "Done.."?
    // Actually: "Done,.." — the regex [,;:]\s*([.!?]) is greedy? No, it matches ONE [.!?].
    // So ",." matches, replaced with "." → "Done.." wait no.
    // Let me re-trace: "Done, .." → fixSpacing: \s+([.,?!:;]) — matches " ." (space before first ".") → "Done,.."
    // collapse step 1: [,;:]\s*([.!?]) — matches ",." (the comma followed by period) → replaces with "." → "Done.."
    // Hmm, ",.." — the regex matches first occurrence ",." → "." so result is "Done.."
    // collapse step 2: \.\s*([!?]) — no match on ".." → stays "Done.."
    // CURRENT: FAIL — produces "Done.." instead of "Done."
    // BUG: double period not collapsed
    func testHybrid16_whisperCommaBeforeSpokenPeriod() {
        XCTAssertEqual(TextPostProcessor.process("Done, period."), "Done.")
    }

    // 17. Whisper adds period at end, user said "comma" mid-sentence
    // Input: "Hello, comma, world." — whisper added commas AND user said comma
    // Wait, more realistic: "First comma second." → replace: "First , second." → fixSpacing: "First, second."
    // This is fine actually — whisper just added the trailing period, spoken comma was mid-sentence.
    // CURRENT: PASS
    func testHybrid17_spokenCommaMidSentenceWithWhisperPeriod() {
        XCTAssertEqual(TextPostProcessor.process("First comma second."), "First, second.")
    }

    // 18. Whisper capitalizes after its auto-period, spoken period creates double
    // Input: "Hello. Period. Next sentence." — whisper treated "Period" as a word, capitalized it
    // replace: "Hello. . Next sentence." → fixSpacing: "Hello.. Next sentence."
    // collapse: ".." not handled → "Hello.. Next sentence."
    // CURRENT: FAIL — produces "Hello.. Next sentence." instead of "Hello. Next sentence."
    func testHybrid18_whisperCapitalizedPeriodWord() {
        XCTAssertEqual(TextPostProcessor.process("Hello. Period. Next sentence."), "Hello. Next sentence.")
    }

    // 19. Whisper adds comma, user says "comma" — double comma
    // Input: "So, comma, the thing" — whisper heard comma AND user said it
    // replace: "So, , , the thing" → fixSpacing removes spaces before commas → "So,,, the thing"
    // collapse: no rule for ",," → stays "So,,, the thing"
    // CURRENT: FAIL — produces "So,,, the thing" instead of "So, the thing"
    // BUG: consecutive commas not collapsed
    func testHybrid19_whisperCommaAndSpokenComma() {
        XCTAssertEqual(TextPostProcessor.process("So, comma, the thing"), "So, the thing")
    }

    // 20. Whisper adds trailing period after spoken period
    // Input: "The end period." — whisper added "." at end, user said "period"
    // replace: "The end ." → fixSpacing: "The end." — wait that's only one period now.
    // Hmm let me re-check: "The end period." → replace "period" → "The end .."
    // Wait no — "period" is at position "The end [period]." — the "." is whisper's.
    // After replacing "period" with ".": "The end .."
    // fixSpacing: \s+([.,?!:;]) matches " ." (space before first dot) → "The end.."
    // collapse: ".." not handled → "The end.."
    // CURRENT: FAIL — produces "The end.." instead of "The end."
    func testHybrid20_spokenPeriodWithWhisperTrailingPeriod() {
        XCTAssertEqual(TextPostProcessor.process("The end period."), "The end.")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 3 — Multiple spoken punctuation in one utterance
    // -------------------------------------------------------------------------

    // 21. Two spoken punctuation: comma and question mark
    // Input: "hello comma how are you question mark"
    // replace: "hello , how are you ?" → fixSpacing: "hello, how are you?" → good
    // CURRENT: PASS
    func testHybrid21_commaAndQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("hello comma how are you question mark"), "hello, how are you?")
    }

    // 22. Three spoken punctuation in one utterance
    // Input: "hi comma how are you question mark great exclamation mark"
    // replace: "hi , how are you ? great !" → fixSpacing: "hi, how are you? great!"
    // CURRENT: PASS
    func testHybrid22_threeSpokenPunctuationClean() {
        XCTAssertEqual(
            TextPostProcessor.process("hi comma how are you question mark great exclamation mark"),
            "hi, how are you? great!"
        )
    }

    // 23. Multiple spoken punctuation with whisper auto-punctuation throughout
    // Input: "Hi, comma, how are you? Question mark." — whisper duplicated both
    // replace: "Hi, , , how are you? ? ." → fixSpacing: "Hi,,, how are you??.".
    // Wait let me be more careful. After replacement of "comma" and "question mark":
    // "Hi, , , how are you? ?." → fixSpacing: \s+([.,?!:;]) removes space before each punct
    // "Hi,,, how are you??."
    // collapse step 1: no [,;:] before [.!?] in "Hi,,," — actually ",,," doesn't match [,;:]\s*[.!?]
    // collapse step 1 on "??." — no match. step 2: no "." before [!?] — no wait, ".?" would match
    // but we have "??." — that's ? then ? then . — no match for either rule.
    // CURRENT: FAIL — produces "Hi,,, how are you??." instead of "Hi, how are you?"
    // BUG: multiple duplicate commas, duplicate question marks, trailing period not handled
    func testHybrid23_multipleSpokenWithWhisperDuplicates() {
        XCTAssertEqual(
            TextPostProcessor.process("Hi, comma, how are you? Question mark."),
            "Hi, how are you?"
        )
    }

    // 24. Comma then period in same sentence (both spoken, no conflict)
    // Input: "first comma second period"
    // replace: "first , second ." → fixSpacing: "first, second." → good
    // CURRENT: PASS
    func testHybrid24_commaAndPeriod() {
        XCTAssertEqual(TextPostProcessor.process("first comma second period"), "first, second.")
    }

    // 25. Semicolon and period (spoken, with whisper trailing period)
    // Input: "first semicolon second period."
    // replace: "first ; second .." → fixSpacing: "first; second.."
    // collapse: ".." not handled → "first; second.."
    // CURRENT: FAIL — produces "first; second.." instead of "first; second."
    func testHybrid25_semicolonAndPeriodWithWhisperTrailing() {
        XCTAssertEqual(TextPostProcessor.process("first semicolon second period."), "first; second.")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 4 — Ellipsis preservation
    // -------------------------------------------------------------------------

    // 26. Simple ellipsis preservation
    // Input: "and then ellipsis maybe"
    // replace: "and then ... maybe" → fixSpacing: "and then... maybe"
    // Wait — fixSpacing regex: \s+([.,?!:;]) — "." is in the set.
    // " ..." — the space before "." matches → removes space → "and then...maybe"
    // Then ensureSpaceAfter: "...m" — ";" not matching. Actually the pattern is ([.,?!:;])(\w).
    // "...m" — the last "." followed by "m" matches → "... m" → "and then... maybe"
    // CURRENT: PASS
    func testHybrid26_ellipsisPreservation() {
        XCTAssertEqual(TextPostProcessor.process("and then ellipsis maybe"), "and then... maybe")
    }

    // 27. Ellipsis should not be collapsed to single period
    // The collapseAdjacentPunctuation explicitly avoids "." before "." (only handles "." before [!?]).
    // Input text already containing "..." should pass through.
    // CURRENT: PASS — collapse doesn't touch ".."
    func testHybrid27_ellipsisNotCollapsed() {
        XCTAssertEqual(TextPostProcessor.process("wait ellipsis"), "wait...")
    }

    // 28. Ellipsis with whisper trailing period
    // Input: "and then ellipsis." → replace: "and then ...." → fixSpacing: "and then...."
    // collapse: ".." not handled (only "." before [!?]). So "and then...."
    // CURRENT: FAIL — produces "and then...." instead of "and then..."
    // BUG: whisper trailing period after ellipsis creates four dots
    func testHybrid28_ellipsisWithWhisperTrailingPeriod() {
        XCTAssertEqual(TextPostProcessor.process("and then ellipsis."), "and then...")
    }

    // 29. Ellipsis followed by more text, whisper adds comma after
    // Input: "and then, ellipsis, you know" — whisper wraps ellipsis word in commas
    // replace: "and then, ..., you know" → fixSpacing: "and then,..., you know"
    // Actually fixSpacing: \s+([.,?!:;]) — " ." matches before first dot → "and then,..., you know"
    // Hmm wait: "and then, ..., you know" — the space before "..." has " ." which matches.
    // → "and then,..., you know" — collapse step 1: ",." matches [,;:]\s*[.!?] → "."
    // → "and then..., you know" — ensureSpaceAfter: no issue → "and then..., you know"
    // Hmm actually: after collapse ",." → "." the string becomes "and then..., you know"
    // Wait: "and then,...," — the ",." at position [then,][...][,]
    // Let me be very careful: "and then, ..., you know"
    // fixSpacing: matches " ." (space before first ".") → "and then,..., you know"
    // No wait: the string is "and then, ..., you know". The regex \s+([.,?!:;]) would find " ."
    // (the space before the first dot of "..."). But also " ," at the end? No, there's no space before the trailing comma.
    // So: "and then,..., you know"
    // collapse step 1: [,;:]\s*([.!?]) — finds ",." → replaces with "." → "and then..., you know"
    // Wait that replaced the leading comma + first dot with just the dot? The ",...," pattern:
    // regex finds "," followed by "." → replaces with "." → but the original is ",...,"
    // The first match is the "," at position 8, followed by "." → match is ",." replaced by "."
    // Result: "and then..., you know" — looks correct actually!
    // CURRENT: PASS (though the approach is fragile)
    func testHybrid29_ellipsisWhisperCommasSurrounding() {
        XCTAssertEqual(TextPostProcessor.process("and then, ellipsis, you know"), "and then..., you know")
    }

    // 30. Ellipsis at end of sentence (clean, no conflict)
    // CURRENT: PASS
    func testHybrid30_ellipsisAtEnd() {
        XCTAssertEqual(TextPostProcessor.process("I wonder ellipsis"), "I wonder...")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 5 — Consecutive punctuation collapsing
    // -------------------------------------------------------------------------

    // 31. Comma followed by exclamation (whisper comma + spoken exclamation mark)
    // Input pre-processed: "Great,!" → collapse step 1: ",!" → "!" → "Great!"
    // But this is testing the input string directly. Let me use a realistic whisper input.
    // Input: "Great, exclamation mark" → replace: "Great, !" → fixSpacing: "Great,!"
    // collapse: ",!" → "!" → "Great!" → good
    // CURRENT: PASS
    func testHybrid31_commaExclamationCollapse() {
        XCTAssertEqual(TextPostProcessor.process("Great, exclamation mark"), "Great!")
    }

    // 32. Semicolon before period (whisper semicolon + spoken period)
    // Input: "done; period" → replace: "done; ." → fixSpacing: "done;."
    // collapse step 1: ";." → "." → "done."
    // CURRENT: PASS
    func testHybrid32_semicolonPeriodCollapse() {
        XCTAssertEqual(TextPostProcessor.process("done; period"), "done.")
    }

    // 33. Period before exclamation (whisper period + spoken exclamation)
    // Input: "wow. exclamation mark" → replace: "wow. !" → fixSpacing: "wow.!"
    // collapse step 2: ".!" → "!" → "wow!"
    // CURRENT: PASS
    func testHybrid33_periodExclamationCollapse() {
        XCTAssertEqual(TextPostProcessor.process("wow. exclamation mark"), "wow!")
    }

    // 34. Period before question mark
    // Input: "really. question mark" → replace: "really. ?" → fixSpacing: "really.?"
    // collapse step 2: ".?" → "?" → "really?"
    // CURRENT: PASS
    func testHybrid34_periodQuestionMarkCollapse() {
        XCTAssertEqual(TextPostProcessor.process("really. question mark"), "really?")
    }

    // 35. Double period (whisper period + spoken period) — e.g. from "period."
    // Input: ".." (a string that's just double period)
    // No replacements. fixSpacing: no \s before punct. collapse: ".." — step 1 no match, step 2 no match.
    // CURRENT: FAIL — produces ".." instead of "."
    // BUG: double period not collapsed
    func testHybrid35_doublePeriodCollapse() {
        XCTAssertEqual(TextPostProcessor.process("end.."), "end.")
    }

    // 36. Exclamation then period (spoken exclamation + whisper trailing period)
    // This is "!." — not handled by collapse rules.
    // collapse step 1: no [,;:] involved. step 2: "." before [!?] — no, it's "!" before ".".
    // CURRENT: FAIL — "!." not collapsed
    func testHybrid36_exclamationPeriodCollapse() {
        XCTAssertEqual(TextPostProcessor.process("wow!."), "wow!")
    }

    // 37. Question mark then period (spoken question + whisper trailing period)
    // "?." — not handled.
    // CURRENT: FAIL — "?." not collapsed
    func testHybrid37_questionMarkPeriodCollapse() {
        XCTAssertEqual(TextPostProcessor.process("really?."), "really?")
    }

    // 38. Colon before question mark
    // Input: "what: question mark" → replace: "what: ?" → fixSpacing: "what:?"
    // collapse step 1: ":?" → "?" → "what?"
    // CURRENT: PASS
    func testHybrid38_colonQuestionCollapse() {
        XCTAssertEqual(TextPostProcessor.process("what: question mark"), "what?")
    }

    // 39. Triple punctuation: comma + exclamation + period (all three layers)
    // Input: "Great, exclamation mark." → from test 12 above
    // replace: "Great, !." → fixSpacing: "Great,!."
    // collapse step 1: ",!" → "Great!." — step 2: "!." not handled → "Great!."
    // CURRENT: FAIL — produces "Great!." instead of "Great!"
    func testHybrid39_tripleCollapseCommaExclamationPeriod() {
        XCTAssertEqual(TextPostProcessor.process("Great, exclamation mark."), "Great!")
    }

    // 40. Comma + period (whisper comma + spoken period)
    // Input: "done, period" → replace: "done, ." → fixSpacing: "done,."
    // collapse step 1: ",." → "." → "done."
    // CURRENT: PASS
    func testHybrid40_commaPeriodCollapse() {
        XCTAssertEqual(TextPostProcessor.process("done, period"), "done.")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 6 — No false positives
    // -------------------------------------------------------------------------

    // 41. Word "period" as part of a compound concept should not trigger
    // Input: "the periodic table is great" — "periodic" contains "period" but \b won't match
    // because "periodic" has no word boundary after "period" (it's "period" + "ic")
    // Wait: \bperiod\b — in "periodic", there IS \b before "p" and the "d" is followed by "i",
    // so "period" ends at "d" but "i" follows — "d" to "i" is \w to \w, no word boundary. Safe.
    // CURRENT: PASS
    func testHybrid41_noFalsePositivePeriodic() {
        XCTAssertEqual(TextPostProcessor.process("the periodic table is great"), "the periodic table is great")
    }

    // 42. "comma-separated" should not trigger comma replacement
    // Input: "use comma-separated values" — "comma" is followed by "-" which is \W, so \b matches!
    // \bcomma\b — "comma" followed by "-": the boundary between "a" (word) and "-" (non-word) IS \b.
    // So this WILL falsely replace "comma" → ","
    // Result: "use ,-separated values" → fixSpacing: "use,-separated values"
    // ensureSpaceAfter: ",-" — comma not followed by \w... "-" is not \w? Actually "-" is not [a-zA-Z0-9_].
    // So ensureSpaceAfter doesn't fire. Result: "use,-separated values"
    // CURRENT: FAIL — produces "use,-separated values" instead of "use comma-separated values"
    // BUG: \b word boundary matches at hyphen, causing false positive
    func testHybrid42_noFalsePositiveCommaSeparated() {
        XCTAssertEqual(
            TextPostProcessor.process("use comma-separated values"),
            "use comma-separated values"
        )
    }

    // 43. "exclamation" alone should not trigger (only "exclamation mark" or "exclamation point")
    // CURRENT: PASS — pattern requires "exclamation mark" or "exclamation point", not just "exclamation"
    func testHybrid43_noFalsePositiveExclamationAlone() {
        XCTAssertEqual(
            TextPostProcessor.process("what an exclamation that was"),
            "what an exclamation that was"
        )
    }

    // 44. "colon" in "colonoscopy" should not trigger
    // \bcolon\b in "colonoscopy" — "colon" ends at "n", next char is "o" → \w to \w, no boundary. Safe.
    // CURRENT: PASS
    func testHybrid44_noFalsePositiveColonoscopy() {
        XCTAssertEqual(TextPostProcessor.process("schedule a colonoscopy"), "schedule a colonoscopy")
    }

    // 45. "dashing" should not trigger dash replacement
    // \bdash\b in "dashing" — "dash" ends at "h", next is "i" → no boundary. Safe.
    // CURRENT: PASS
    func testHybrid45_noFalsePositiveDashing() {
        XCTAssertEqual(TextPostProcessor.process("he looked dashing"), "he looked dashing")
    }

    // 46. "question" alone should not trigger (only "question mark")
    // CURRENT: PASS
    func testHybrid46_noFalsePositiveQuestionAlone() {
        XCTAssertEqual(
            TextPostProcessor.process("that is a good question"),
            "that is a good question"
        )
    }

    // 47. "hyphenated" should not trigger hyphen replacement
    // \bhyphen\b in "hyphenated" — "hyphen" ends at "n", next is "a" → no boundary. Safe.
    // CURRENT: PASS
    func testHybrid47_noFalsePositiveHyphenated() {
        XCTAssertEqual(TextPostProcessor.process("a hyphenated word"), "a hyphenated word")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 7 — Mixed case
    // -------------------------------------------------------------------------

    // 48. Uppercase "PERIOD" — regex is case insensitive
    // CURRENT: PASS
    func testHybrid48_uppercasePeriod() {
        XCTAssertEqual(TextPostProcessor.process("done PERIOD"), "done.")
    }

    // 49. Mixed case "Question Mark" — whisper often capitalizes
    // CURRENT: PASS — .caseInsensitive flag handles this
    func testHybrid49_mixedCaseQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("are you sure Question Mark"), "are you sure?")
    }

    // 50. Title case "Comma" mid-sentence — whisper sometimes capitalizes after its own period
    // Input: "Hello. Comma, world." — whisper added period after "Hello", capitalized "Comma"
    // replace: "Hello. , , world." → fixSpacing: "Hello.,, world."
    // collapse step 1: [.] is not in [,;:], so no match for ".,".
    // Hmm wait: the regex is [,;:]\s*([.!?]) — looking for comma/semi/colon before .!?
    // We have ".,," — that's period then commas. No match for either collapse rule.
    // CURRENT: FAIL — produces "Hello.,, world." instead of "Hello., world." or "Hello, world."
    // BUG: whisper period before spoken comma creates ".,," not handled
    func testHybrid50_titleCaseCommaAfterWhisperPeriod() {
        XCTAssertEqual(TextPostProcessor.process("Hello. Comma, world."), "Hello, world.")
    }

    // -------------------------------------------------------------------------
    // MARK: Category 8 — Edge cases
    // -------------------------------------------------------------------------

    // 51. Empty string
    // CURRENT: PASS
    func testHybrid51_emptyString() {
        XCTAssertEqual(TextPostProcessor.process(""), "")
    }

    // 52. Only a punctuation word
    // Input: "period" → replace: "." → fixSpacing: "." → collapse: "." → "."
    // CURRENT: PASS
    func testHybrid52_onlyPunctuationWord() {
        XCTAssertEqual(TextPostProcessor.process("period"), ".")
    }

    // 53. Only a punctuation word with whisper period
    // Input: "Period." → replace: ".." → fixSpacing: ".." → collapse: ".." not handled
    // CURRENT: FAIL — produces ".." instead of "."
    func testHybrid53_onlyPunctuationWordWithWhisperPeriod() {
        XCTAssertEqual(TextPostProcessor.process("Period."), ".")
    }

    // 54. Punctuation word at start of utterance
    // Input: "Comma then something" — whisper starts with "Comma"
    // replace: ", then something" → fixSpacing: ", then something" (no \s before the comma since it's at start)
    // Actually: "Comma then something" → replace \bcomma\b → ", then something"
    // The comma is now at position 0 with no space before it. fixSpacing won't touch it.
    // CURRENT: PASS (though starting with a comma is odd, it's technically correct replacement)
    func testHybrid54_punctuationWordAtStart() {
        XCTAssertEqual(TextPostProcessor.process("Comma then something"), ", then something")
    }

    // 55. Whisper adds question mark AND user said "question mark" — duplicate
    // Input: "Is it? Question mark." → replace: "Is it? ?." → fixSpacing: "Is it??."
    // collapse step 1: no [,;:] match. step 2: ".?" doesn't match (it's "?.") —
    // the regex is \.\s*([!?]) looking for period then !/?. We have "??." — no match.
    // CURRENT: FAIL — produces "Is it??." instead of "Is it?"
    // BUG: "??." not collapsed
    func testHybrid55_whisperQuestionAndSpokenQuestion() {
        XCTAssertEqual(TextPostProcessor.process("Is it? Question mark."), "Is it?")
    }

    // 56. Whisper adds exclamation AND user said "exclamation mark" — duplicate
    // Input: "Wow! Exclamation mark." → replace: "Wow! !." → fixSpacing: "Wow!!."
    // collapse: "!." not handled, "!!" not handled → "Wow!!."
    // CURRENT: FAIL — produces "Wow!!." instead of "Wow!"
    func testHybrid56_whisperExclamationAndSpokenExclamation() {
        XCTAssertEqual(TextPostProcessor.process("Wow! Exclamation mark."), "Wow!")
    }

    // 57. New line with whisper punctuation
    // Input: "first. New line second." → replace: "first. \n second."
    // fixSpacing: doesn't touch \n. Result: "first. \n second."
    // CURRENT: PASS (though leading space before \n could be debatable)
    func testHybrid57_newLineWithWhisperPunctuation() {
        XCTAssertEqual(TextPostProcessor.process("first. new line second."), "first. \n second.")
    }

    // 58. Dash with surrounding text
    // Input: "the thing dash the other thing" → replace: "the thing  — the other thing"
    // (dash replacement is " —" with leading space)
    // CURRENT: PASS
    func testHybrid58_dashInContext() {
        XCTAssertEqual(
            TextPostProcessor.process("the thing dash the other thing"),
            "the thing  — the other thing"
        )
    }

    // 59. Multiple sentences with hybrid conflicts throughout
    // Input: "Hello. Period. How are you? Question mark. Great, exclamation mark."
    // replace: "Hello. .. How are you? ?. Great, !."
    // fixSpacing: "Hello... How are you??. Great,!."
    // collapse step 1: ",!" → "Great!." | no other [,;:] matches
    // collapse step 2: ".!" — nope, we have "!." still
    // Result: "Hello... How are you??. Great!."
    // Wait: fixSpacing on "Hello. .. How are you? ?. Great, !."
    // \s+([.,?!:;]) matches: " ." (before first replacement dot) and " ?" and " !"
    // → "Hello... How are you??. Great,!."
    // Hmm: "Hello. .." — the space before the first "." of ".." is removed → "Hello..."
    // That looks like an ellipsis! Then "How are you??." and "Great,!."
    // collapse step 1: ",!" → "!" → "Great!."
    // collapse step 2: no "." before [!?] → stays
    // Result: "Hello... How are you??. Great!."
    // CURRENT: FAIL — produces "Hello... How are you??. Great!." instead of "Hello. How are you? Great!"
    func testHybrid59_multiSentenceHybridConflicts() {
        XCTAssertEqual(
            TextPostProcessor.process("Hello. Period. How are you? Question mark. Great, exclamation mark."),
            "Hello. How are you? Great!"
        )
    }

    // 60. Spoken "open quote" and "close quote" with whisper punctuation
    // Input: 'He said, open quote hello close quote period'
    // replace: 'He said, " hello " .' → fixSpacing: 'He said," hello ".'
    // CURRENT: PASS (spacing around quotes is imperfect but matches current behavior)
    func testHybrid60_quotesWithSpokenPeriod() {
        XCTAssertEqual(
            TextPostProcessor.process("He said, open quote hello close quote period"),
            "He said, \" hello \"."
        )
    }
}
