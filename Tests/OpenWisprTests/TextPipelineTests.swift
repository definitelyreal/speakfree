import XCTest
@testable import OpenWisprLib

final class TextPipelineTests: XCTestCase {

    // MARK: - run(): end-to-end

    func test_passthrough_with_no_context_or_glossary() {
        let input = TextPipeline.Input(
            raw: "Hello world.",
            cursorContextText: nil,
            screenContextText: nil,
            punctuationMode: .hybrid,
            styleMode: .none,
            glossaryWords: nil
        )
        let result = TextPipeline.run(input)
        XCTAssertEqual(result.finalText, "Hello world.")
        // Hybrid mode produces the instruction line; without context/glossary the
        // prompt should be exactly that one line.
        XCTAssertEqual(result.promptHints,
                       "Spoken punctuation: say the word \"period\" or \"comma\" or \"question mark\" to insert punctuation.")
    }

    func test_run_punctuationOff_skipsProcessAndReturnsRaw() {
        // .off mode: TextPostProcessor.process is skipped entirely; raw passes through
        // to styleMode application (which is a no-op for .none).
        let input = TextPipeline.Input(
            raw: "hello comma world",
            cursorContextText: nil,
            screenContextText: nil,
            punctuationMode: .off,
            styleMode: .none,
            glossaryWords: nil
        )
        let result = TextPipeline.run(input)
        XCTAssertEqual(result.processedText, "hello comma world")
        XCTAssertEqual(result.finalText, "hello comma world")
        // No instruction line when mode is .off
        XCTAssertNil(result.promptHints)
    }

    func test_run_appliesStyle_textingStripsTrailingPeriod() {
        // texting style strips trailing single period — verify the styleMode hook fires.
        let input = TextPipeline.Input(
            raw: "ok cool.",
            cursorContextText: nil,
            screenContextText: nil,
            punctuationMode: .hybrid,
            styleMode: .texting,
            glossaryWords: nil
        )
        let result = TextPipeline.run(input)
        XCTAssertFalse(result.finalText.hasSuffix("."),
                       "Texting style should strip a single trailing period, got: \(result.finalText)")
    }

    // MARK: - assemblePromptHints(): the v1.2.11 cursor-context fix

    func test_promptHints_rawCursorTextNeverEntersPrompt() {
        // Raw text "I said, well, you know, whatever," should NOT appear verbatim
        // in the prompt. Only words of length > 3 should be extracted.
        let rawCursor = "I said, well, you know, whatever, exactly,"
        let input = TextPipeline.Input(
            raw: "anything",
            cursorContextText: rawCursor,
            screenContextText: nil,
            punctuationMode: .off,        // suppress instruction line for clarity
            styleMode: .none,
            glossaryWords: nil
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertFalse(prompt.contains(rawCursor),
                       "Raw cursor text must never appear verbatim in the prompt. Got: \(prompt)")
        // Words ≤ 3 chars ("I") must NOT appear; words > 3 chars MAY appear.
        XCTAssertFalse(prompt.contains(" I "), "Short words (<=3) should be filtered out")
    }

    func test_promptHints_noCommasFromCommaHeavyCursorContext() {
        // Regression guard for v1.2.11 comma feedback loop.
        //
        // The scenario that triggered the original bug: a prior degraded dictation
        // produced text where commas were tokenized as their own words (e.g.
        // "yeah , well , so , thanks"). With raw-text cursor passthrough, whisper
        // saw an avalanche of commas and amplified them. The v1.2.11 fix:
        // tokenize cursor context on whitespace, drop short tokens (len <= 3),
        // and SPACE-join the remainder — so standalone "," (len 1) is dropped
        // and the resulting "Context words:" line has no commas.
        let commaHeavyCursor = "yeah , well , so , thanks , anyway , indeed , alright , fine"
        let input = TextPipeline.Input(
            raw: "hello",
            cursorContextText: commaHeavyCursor,
            screenContextText: nil,
            punctuationMode: .off,  // suppress instruction line so any comma == cursor-derived
            styleMode: .none,
            glossaryWords: nil
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertFalse(prompt.isEmpty)
        // The cursor-context line is space-joined ("word1 word2 word3.") not
        // comma-joined; the entire prompt should contain no commas because
        // no other section is active and standalone "," tokens were dropped
        // by the length-filter.
        XCTAssertFalse(prompt.contains(","),
                       "Comma-heavy cursor context must not produce commas in prompt (v1.2.11 fix). Got: \(prompt)")
    }

    func test_promptHints_glossaryLineAppearsWhenWordsProvided() {
        let input = TextPipeline.Input(
            raw: "hello",
            cursorContextText: nil,
            screenContextText: nil,
            punctuationMode: .off,
            styleMode: .none,
            glossaryWords: "OpenWispr, Whisper, EdDSA"
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertTrue(prompt.contains("Glossary: OpenWispr, Whisper, EdDSA."),
                      "Glossary line should appear when glossaryWords is non-empty. Got: \(prompt)")
    }

    func test_promptHints_instructionLineAppearsWhenPunctuationNotOff() {
        for mode in [PunctuationMode.spoken, .hybrid] {
            let input = TextPipeline.Input(
                raw: "hello",
                cursorContextText: nil,
                screenContextText: nil,
                punctuationMode: mode,
                styleMode: .none,
                glossaryWords: nil
            )
            let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
            XCTAssertTrue(prompt.contains("Spoken punctuation:"),
                          "Instruction line should appear for mode \(mode). Got: \(prompt)")
        }

        // ...and absent for .off
        let off = TextPipeline.Input(
            raw: "hello",
            cursorContextText: nil,
            screenContextText: nil,
            punctuationMode: .off,
            styleMode: .none,
            glossaryWords: nil
        )
        XCTAssertNil(TextPipeline.assemblePromptHints(input: off),
                     "No instruction, no context, no glossary -> nil prompt")
    }

    func test_promptHints_screenContextWordsAreCommaJoined() {
        // Sanity: the screen-context line uses comma-joined words (per existing code),
        // while cursor-context uses space-joined. Distinguishes the two code paths.
        let input = TextPipeline.Input(
            raw: "hello",
            cursorContextText: nil,
            screenContextText: "alpha beta gamma delta",
            punctuationMode: .off,
            styleMode: .none,
            glossaryWords: nil
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertTrue(prompt.hasPrefix("Context words: "),
                      "Screen-context line should be the only line and start with the label. Got: \(prompt)")
        // Screen-context joiner is ", "; with 4 long words there must be at least one comma.
        XCTAssertTrue(prompt.contains(","), "Screen-context line should be comma-joined. Got: \(prompt)")
    }
}
