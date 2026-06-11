import XCTest
@testable import OpenWisprLib

final class TextPipelineTests: XCTestCase {

    // MARK: - run(): end-to-end

    func test_passthrough_with_no_context_or_glossary() {
        let input = TextPipeline.Input(raw: "Hello world.", punctuationMode: .hybrid)
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
        let input = TextPipeline.Input(raw: "hello comma world", punctuationMode: .off)
        let result = TextPipeline.run(input)
        XCTAssertEqual(result.processedText, "hello comma world")
        XCTAssertEqual(result.finalText, "hello comma world")
        // No instruction line when mode is .off
        XCTAssertNil(result.promptHints)
    }

    func test_run_appliesStyle_textingStripsTrailingPeriod() {
        // texting style strips trailing single period — verify the styleMode hook fires.
        let input = TextPipeline.Input(raw: "ok cool.", punctuationMode: .hybrid, styleMode: .texting)
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
            punctuationMode: .off,        // suppress instruction line for clarity
            cursorContextText: rawCursor
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
            punctuationMode: .off,  // suppress instruction line so any comma == cursor-derived
            cursorContextText: commaHeavyCursor
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
            punctuationMode: .off,
            glossaryWords: "OpenWispr, Whisper, EdDSA"
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertTrue(prompt.contains("Glossary: OpenWispr, Whisper, EdDSA."),
                      "Glossary line should appear when glossaryWords is non-empty. Got: \(prompt)")
    }

    func test_promptHints_instructionLineAppearsWhenPunctuationNotOff() {
        for mode in [PunctuationMode.spoken, .hybrid] {
            let input = TextPipeline.Input(raw: "hello", punctuationMode: mode)
            let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
            XCTAssertTrue(prompt.contains("Spoken punctuation:"),
                          "Instruction line should appear for mode \(mode). Got: \(prompt)")
        }

        // ...and absent for .off
        XCTAssertNil(TextPipeline.assemblePromptHints(input: TextPipeline.Input(punctuationMode: .off)),
                     "No instruction, no context, no glossary -> nil prompt")
    }

    // MARK: - comma-feedback-loop regression (Task 2 — locks the v1.2.11 fix)

    func test_commaHeavyCursorContext_doesNotAmplifyCommas() {
        // Reproduce the spiral: a comma-heavy cursor context (a prior degraded dictation)
        // must NOT cause the prompt to feed comma-heavy text to Whisper.
        let pollutedContext = "First, comma, then, comma, then, more, commas, everywhere"
        let input = TextPipeline.Input(
            raw: "Plain sentence with one comma, like this.",
            punctuationMode: .hybrid,
            cursorContextText: pollutedContext
        )
        let result = TextPipeline.run(input)
        let hints = result.promptHints ?? ""
        // Prompt must not parrot the raw comma-spam — only extract words.
        XCTAssertFalse(hints.contains(","), "prompt must not carry raw commas from cursor context")
        XCTAssertFalse(hints.contains("comma, comma"), "prompt must not parrot comma-spam phrasing")
    }

    func test_promptHints_screenContextWordsAreSpaceJoined() {
        // Screen-context words are space-joined (same guard as cursor context) so the
        // "Context words:" line carries no commas — applying the v1.2.11 comma-loop fix
        // to both context paths equally.
        let input = TextPipeline.Input(
            raw: "hello",
            punctuationMode: .off,
            screenContextText: "alpha beta gamma delta"
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertTrue(prompt.hasPrefix("Context words: "),
                      "Screen-context line should be the only line and start with the label. Got: \(prompt)")
        // Space-joined: no commas in the hint line.
        XCTAssertFalse(prompt.contains(","), "Screen-context hint line must be space-joined (no commas). Got: \(prompt)")
        // The four words should all appear (Set order is non-deterministic but each word appears exactly once).
        for word in ["alpha", "beta", "gamma", "delta"] {
            XCTAssertTrue(prompt.contains(word), "Screen-context word '\(word)' should appear in prompt. Got: \(prompt)")
        }
    }

    // MARK: - T2.6: Input.init defaults

    func test_input_init_defaults_omitOptionals() {
        // Verify only raw + punctuationMode are required; all optional fields default correctly.
        let minimal = TextPipeline.Input(raw: "test", punctuationMode: .off)
        XCTAssertEqual(minimal.raw, "test")
        XCTAssertEqual(minimal.punctuationMode, .off)
        XCTAssertNil(minimal.cursorContextText, "cursorContextText defaults to nil")
        XCTAssertNil(minimal.screenContextText, "screenContextText defaults to nil")
        XCTAssertEqual(minimal.styleMode, .none, "styleMode defaults to .none")
        XCTAssertNil(minimal.glossaryWords, "glossaryWords defaults to nil")

        // raw defaults to "" when omitted (context-only Input for prompt assembly).
        let contextOnly = TextPipeline.Input(punctuationMode: .hybrid)
        XCTAssertEqual(contextOnly.raw, "", "raw defaults to \"\" when omitted")
    }

    func test_input_init_contextOnly_omitRaw_givesSamepromptAsEmptyRaw() {
        // TextPipeline.Input(punctuationMode:) and TextPipeline.Input(raw:"", punctuationMode:)
        // must produce identical prompt hints — raw is irrelevant to assemblePromptHints.
        let withEmpty = TextPipeline.Input(
            raw: "",
            punctuationMode: .hybrid,
            glossaryWords: "OpenWispr Parakeet"
        )
        let withDefault = TextPipeline.Input(
            punctuationMode: .hybrid,
            glossaryWords: "OpenWispr Parakeet"
        )
        XCTAssertEqual(
            TextPipeline.assemblePromptHints(input: withEmpty),
            TextPipeline.assemblePromptHints(input: withDefault),
            "Context-only Input (raw omitted) must produce the same prompt as explicit raw: \"\""
        )
    }

    // MARK: - T2.6: precomputedPrompt eliminates double assemblePromptHints

    func test_run_precomputedPrompt_usedVerbatim() {
        // When precomputedPrompt is supplied, run() places it in Result.promptHints without
        // calling assemblePromptHints again — the returned hints equal the supplied value.
        let input = TextPipeline.Input(raw: "hello world", punctuationMode: .hybrid)
        let sentinelPrompt: String? = "SENTINEL-PRECOMPUTED-PROMPT"
        let result = TextPipeline.run(input, precomputedPrompt: sentinelPrompt)
        XCTAssertEqual(result.promptHints, sentinelPrompt,
                       "precomputedPrompt must be stored verbatim in Result.promptHints")
        // Post-processing should still run on the raw text.
        XCTAssertEqual(result.finalText, "hello world")
    }

    func test_run_precomputedPrompt_nilPreserved() {
        // .some(nil) means "caller computed nil (no hints)"; run() must store nil, not recompute.
        // This tests the String?? wrapping: .some(nil) differs from .none (not provided).
        let input = TextPipeline.Input(
            raw: "hello",
            punctuationMode: .hybrid,
            glossaryWords: "something"  // would produce a non-nil prompt if computed
        )
        let result = TextPipeline.run(input, precomputedPrompt: .some(nil))
        XCTAssertNil(result.promptHints,
                     ".some(nil) precomputedPrompt must store nil (caller decided no hints)")
    }

    func test_run_noPrecomputedPrompt_computesFromInput() {
        // Default (no precomputedPrompt) must still compute hints from the input.
        let input = TextPipeline.Input(
            raw: "hello",
            punctuationMode: .hybrid,
            glossaryWords: "OpenWispr"
        )
        let result = TextPipeline.run(input) // no precomputedPrompt
        XCTAssertTrue(result.promptHints?.contains("Glossary: OpenWispr") ?? false,
                      "Without precomputedPrompt, assemblePromptHints must run and include glossary")
    }

    // MARK: - T2.6: prompt budget enforcement

    func test_promptBudget_longPromptTruncatedToAtMost800Chars() {
        // Build a prompt guaranteed to exceed the budget: a spoken instruction line
        // + a very long glossary + screen context.
        let longGlossary = (0..<100).map { "GlossaryWord\($0)" }.joined(separator: " ")
        let input = TextPipeline.Input(
            punctuationMode: .hybrid,  // adds instruction line
            glossaryWords: longGlossary
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertLessThanOrEqual(prompt.count, TextPipeline.promptBudget,
                                  "Assembled prompt must not exceed promptBudget (\(TextPipeline.promptBudget)) chars. Got \(prompt.count)")
    }

    func test_promptBudget_shortPromptNotTruncated() {
        // A typical short prompt must pass through unchanged (no silent truncation of real content).
        let input = TextPipeline.Input(
            raw: "hello",
            punctuationMode: .hybrid,
            glossaryWords: "OpenWispr"
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        XCTAssertTrue(prompt.count < TextPipeline.promptBudget,
                      "Short prompt must be under budget; got \(prompt.count) chars: \(prompt)")
        // Content must be preserved intact (instruction line and glossary both present).
        XCTAssertTrue(prompt.contains("Spoken punctuation:"), "Instruction line must survive in short prompt")
        XCTAssertTrue(prompt.contains("OpenWispr"), "Glossary must survive in short prompt")
    }

    /// AR-2 Medium finding — priority inversion fix.
    ///
    /// When the assembled prompt exceeds the budget, `suffix(promptBudget)` keeps the LAST N chars,
    /// meaning sections near the END of the assembled string survive truncation. The correct order
    /// (highest-priority last / closest to end) is: instruction → screen context → glossary →
    /// cursor context. This test pins that glossary terms survive an overflow while screen-context
    /// words are truncated away — confirming user-curated vocabulary outranks ambient screen words.
    func test_promptBudget_glossaryOutranksScreenContextOnOverflow() {
        // Build a screen-context block large enough to overflow the budget on its own when combined
        // with glossary and cursor context. Use 30-char marker words so 20 of them produce ~655
        // chars for screen context alone; adding glossary (~160) and cursor (~95) gives ~910 chars
        // total → overflows the 800-char budget by ~110, cutting the first screen words.
        //
        // Each section uses a unique marker prefix so we can count survivors by section.
        // All words are >3 chars (pass the length filter) and unique (no Set-dedup loss).

        // 20 screen-context words, ~30 chars each; assembled to ~655-char context line.
        let screenWords = (0..<20).map { String(format: "SCREENCONTEXTWORDXXLONGSUFFIX%02d", $0) }.joined(separator: " ")

        // 10 glossary terms — user-curated, must survive truncation.
        let glossary = (0..<10).map { "GLOSSTERM\($0)ABCD" }.joined(separator: " ")

        // 5 cursor-context words — highest priority, must always survive.
        let cursorWords = (0..<5).map { "CURSORWORD\($0)PQRS" }.joined(separator: " ")

        let input = TextPipeline.Input(
            punctuationMode: .off,           // suppress instruction line to isolate screen vs glossary
            cursorContextText: cursorWords,
            screenContextText: screenWords,
            glossaryWords: glossary
        )

        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""

        // Sanity: the full assembly must exceed the budget so truncation actually fired.
        XCTAssertEqual(prompt.count, TextPipeline.promptBudget,
                       "Prompt must be exactly at the budget after truncation (full assembly exceeds 800). " +
                       "Got \(prompt.count) — if < 800, increase screen word length so the assembly overflows.")

        // GLOSSARY MUST SURVIVE: user-curated terms are placed after screen context in the
        // assembled string, so they survive truncation longer. All 10 glossary terms must be present.
        let glossaryTermsSurviving = (0..<10).filter { prompt.contains("GLOSSTERM\($0)ABCD") }.count
        XCTAssertEqual(glossaryTermsSurviving, 10,
            "All 10 glossary terms must survive budget truncation — glossary outranks screen context. " +
            "Only \(glossaryTermsSurviving)/10 survived. Prompt tail: \(prompt.suffix(300))")

        // SCREEN CONTEXT MUST BE (PARTIALLY) DROPPED: screen words are placed BEFORE glossary,
        // so they are the first to be cut when the budget overflows. Not all 20 can survive.
        let screenWordsSurviving = (0..<20).filter { prompt.contains(String(format: "SCREENCONTEXTWORDXXLONGSUFFIX%02d", $0)) }.count
        XCTAssertLessThan(screenWordsSurviving, 20,
            "Some screen-context words must be truncated when budget overflows — screen context is " +
            "lower priority than glossary. All 20 survived, indicating the priority order is wrong.")

        // CURSOR CONTEXT MUST SURVIVE: it is placed last (closest to the end of the prompt) and is
        // the highest-priority section. All cursor words must be present.
        let cursorWordsSurviving = (0..<5).filter { prompt.contains("CURSORWORD\($0)PQRS") }.count
        XCTAssertEqual(cursorWordsSurviving, 5,
            "All 5 cursor-context words must survive truncation (highest priority, closest to prompt end). " +
            "Only \(cursorWordsSurviving)/5 survived. Prompt tail: \(prompt.suffix(200))")
    }

    // MARK: - T2.6: both contexts populated

    func test_promptHints_bothContextsPopulated() {
        // Verify both screen-context and cursor-context hint lines appear when both are provided.
        let input = TextPipeline.Input(
            raw: "hello",
            punctuationMode: .off,  // suppress instruction line
            cursorContextText: "apple banana cherry dragon",
            screenContextText: "elephant funnel gravel hammer"
        )
        let prompt = TextPipeline.assemblePromptHints(input: input) ?? ""
        // Both "Context words:" sections must be present.
        let contextCount = prompt.components(separatedBy: "Context words:").count - 1
        XCTAssertEqual(contextCount, 2,
                       "Both screen-context and cursor-context must produce a 'Context words:' line. Got: \(prompt)")
        // No commas in either section (both space-joined).
        XCTAssertFalse(prompt.contains(","), "Both context sections must be space-joined (no commas). Got: \(prompt)")
    }

    // MARK: - T2.6: processedText differs from raw for spoken/hybrid modes

    func test_run_spoken_processedTextDiffersFromRaw() {
        // "period" spoken-command → "."; processedText must differ from raw.
        let raw = "hello period"
        let input = TextPipeline.Input(raw: raw, punctuationMode: .spoken)
        let result = TextPipeline.run(input)
        XCTAssertNotEqual(result.processedText, raw,
                          ".spoken mode: TextPostProcessor must transform 'period' word, processedText should differ from raw")
        // The raw "period" word should be removed and replaced by ".".
        XCTAssertFalse(result.processedText.contains("period"),
                       ".spoken mode: 'period' spoken command must be consumed by TextPostProcessor. Got: \(result.processedText)")
        XCTAssertTrue(result.processedText.hasSuffix("."),
                      ".spoken mode: processedText should end with '.' after spoken 'period'. Got: \(result.processedText)")
    }

    func test_run_hybrid_processedTextDiffersFromRaw() {
        // .hybrid mode also applies spoken-command substitution.
        let input = TextPipeline.Input(raw: "is that right question mark", punctuationMode: .hybrid)
        let result = TextPipeline.run(input)
        XCTAssertFalse(result.processedText.contains("question mark"),
                       ".hybrid mode: 'question mark' must be consumed by TextPostProcessor. Got: \(result.processedText)")
        XCTAssertTrue(result.processedText.hasSuffix("?"),
                      ".hybrid mode: processedText should end with '?' after spoken 'question mark'. Got: \(result.processedText)")
    }

    // MARK: - Mid-sentence insertion lowercasing (Michael 2026-06-11)

    func test_isMidSentence_positions() {
        // Mid-sentence: continuing after a word, comma, colon, dash, open paren
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: "I'd love"))
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: "make it,"))
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: "make it, "))
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: "note:"))
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: "wait \u{2014}"))
        XCTAssertTrue(TextPipeline.isMidSentence(contextBefore: "see ("))
        // Fresh sentence: empty field, terminator, terminator+quote, newline
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: nil))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: ""))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "Done."))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "Done. "))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "Really?"))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "Stop!"))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "He said \u{201C}stop.\u{201D}"))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "new line\n"))
        XCTAssertFalse(TextPipeline.isMidSentence(contextBefore: "para\n\n"))
    }

    func test_run_midSentence_lowercasesLeadingCapital() {
        // The exact failure Michael hit: dictating a continuation mid-sentence,
        // whisper sentence-cases it ("If you think…"), insertion must lowercase.
        let input = TextPipeline.Input(raw: "If you think there are other people",
                                       punctuationMode: .hybrid,
                                       cursorContextText: "I'd love if you could make it, and")
        let result = TextPipeline.run(input)
        XCTAssertTrue(result.finalText.hasPrefix("if you think"),
                      "mid-sentence insertion must start lowercase. Got: \(result.finalText)")
    }

    func test_run_freshSentence_keepsCapital() {
        let input = TextPipeline.Input(raw: "If you think so, come.",
                                       punctuationMode: .hybrid,
                                       cursorContextText: "That was great. ")
        let result = TextPipeline.run(input)
        XCTAssertTrue(result.finalText.hasPrefix("If you think"),
                      "fresh sentence keeps its capital. Got: \(result.finalText)")
    }

    func test_run_midSentence_keepsDeliberateCase() {
        // "I" and contractions stay capitalized
        let i = TextPipeline.run(TextPipeline.Input(raw: "I'll be there",
                                                    punctuationMode: .hybrid,
                                                    cursorContextText: "and then "))
        XCTAssertTrue(i.finalText.hasPrefix("I'll"), "pronoun I keeps case. Got: \(i.finalText)")
        // Glossary names stay capitalized
        let g = TextPipeline.run(TextPipeline.Input(raw: "Bexx is coming too",
                                                    punctuationMode: .hybrid,
                                                    cursorContextText: "and maybe ",
                                                    glossaryWords: "Claude, Zander, Bexx"))
        XCTAssertTrue(g.finalText.hasPrefix("Bexx"), "glossary name keeps case. Got: \(g.finalText)")
        // All-caps and internal-caps words stay
        let a = TextPipeline.run(TextPipeline.Input(raw: "OK let's do it",
                                                    punctuationMode: .hybrid,
                                                    cursorContextText: "and "))
        XCTAssertTrue(a.finalText.hasPrefix("OK"), "all-caps word keeps case. Got: \(a.finalText)")
        let ic = TextPipeline.run(TextPipeline.Input(raw: "AirPods sound weird",
                                                     punctuationMode: .hybrid,
                                                     cursorContextText: "my "))
        XCTAssertTrue(ic.finalText.hasPrefix("AirPods"), "internal-caps word keeps case. Got: \(ic.finalText)")
    }

    func test_run_noContext_unchanged() {
        // No cursor context (unknown field) — never touch the case.
        let input = TextPipeline.Input(raw: "If you think so", punctuationMode: .hybrid)
        let result = TextPipeline.run(input)
        XCTAssertTrue(result.finalText.hasPrefix("If"),
                      "no context = no case adjustment. Got: \(result.finalText)")
    }
}
