import XCTest
@testable import SpeakFreeLib

final class GlossaryCorrectorTests: XCTestCase {

    // Invented curated names in the shape of a typical user glossary.
    let glossary = ["Vohrbach", "Jaxx", "Maryna", "Tessah", "Zipbox", "Viktor"]

    // Deterministic real-word fixture: these are legitimate words the spell
    // checker would accept (so they must NEVER be corrected to a name).
    let realWords: Set<String> = ["marina", "victor", "could", "election", "doctor", "the", "boat", "was", "beautiful", "hey", "how", "are", "you"]
    func isRealWord(_ w: String) -> Bool { realWords.contains(w.lowercased()) }

    private func correct(_ text: String) -> String {
        GlossaryCorrector.correct(text, glossary: glossary, isRealWord: isRealWord)
    }

    // MARK: - Corrects near-miss misspellings

    func test_correctsNearMiss() {
        XCTAssertEqual(correct("Vorback"), "Vohrbach")   // 2 edits, 8-char name
        XCTAssertEqual(correct("Tesa"), "Tessah")        // within bound
        XCTAssertEqual(correct("Zipbox"), "Zipbox")      // 1 edit
    }

    func test_correctsWithinSentence_preservesPunctuationAndSpacing() {
        XCTAssertEqual(correct("Hey Vorback, how are you?"),
                       "Hey Vohrbach, how are you?")
        XCTAssertEqual(correct("tell Tesa and Maryna"),
                       "tell Tessah and Maryna")
    }

    // MARK: - The critical guard: NEVER mangle a real word

    func test_realWordNeverTouched_evenIfSimilarToName() {
        // "marina" is a real word and similar to the name "Maryna" — must stay.
        XCTAssertEqual(correct("the marina was beautiful"), "the marina was beautiful")
        // "victor" (lowercase, real word) similar to glossary "Viktor" — must stay.
        XCTAssertEqual(correct("he was the victor"), "he was the victor")
        // "election" similar to nothing here, and is real — untouched.
        XCTAssertEqual(correct("the election"), "the election")
    }

    // MARK: - Exact glossary term → normalize to curated casing

    func test_exactTerm_normalizesCase() {
        XCTAssertEqual(correct("jaxx is coming"), "Jaxx is coming")   // mid-sentence lowercased name → curated case
        XCTAssertEqual(correct("JAXX"), "Jaxx")
        XCTAssertEqual(correct("Viktor"), "Viktor")                   // already correct
    }

    // MARK: - Exact-path real-word guard (audit 2026-07-01)
    // Vocabulary comes from imported name lists, so names that are also common words
    // are routine. The exact-match path must never recapitalize a real word:
    // with "Will" in the glossary, "i will send it" was becoming "I Will send it"
    // in every dictation.

    func test_exactTerm_realWordNeverRecapitalized() {
        let g = ["Will", "Mark", "Grace"]
        let real: (String) -> Bool = { ["will", "mark", "grace", "i", "send", "it", "done"].contains($0.lowercased()) }
        XCTAssertEqual(GlossaryCorrector.correct("i will send it", glossary: g, isRealWord: real),
                       "i will send it")
        XCTAssertEqual(GlossaryCorrector.correct("mark it done", glossary: g, isRealWord: real),
                       "mark it done")
    }

    func test_exactTerm_nonWordNameStillNormalized() {
        // The guard must not break the intended behavior for distinctive names.
        let g = ["Jaxx", "Will"]
        let real: (String) -> Bool = { ["will", "tell", "that", "called"].contains($0.lowercased()) }
        XCTAssertEqual(GlossaryCorrector.correct("tell jaxx that will called", glossary: g, isRealWord: real),
                       "tell Jaxx that will called")
    }

    func test_exactTerm_alreadyCanonicalUntouchedEvenIfRealWord() {
        // Dictating the actual name capitalized keeps working ("ask Will tomorrow").
        let g = ["Will"]
        let real: (String) -> Bool = { _ in true }
        XCTAssertEqual(GlossaryCorrector.correct("ask Will tomorrow", glossary: g, isRealWord: real),
                       "ask Will tomorrow")
    }

    func test_override_stillBeatsRealWordGuard() {
        // Curated overrides remain the explicit escape hatch for real-word garbles.
        let g = ["Karma"]
        let real: (String) -> Bool = { _ in true }
        XCTAssertEqual(GlossaryCorrector.correct("kama is here", glossary: g,
                                                 overrides: ["kama": "Karma"], isRealWord: real),
                       "Karma is here")
    }

    // MARK: - Skips

    func test_skipsShortTokens() {
        // 3 chars or fewer never eligible (avoids noise) — "Jax" stays.
        XCTAssertEqual(correct("Jax"), "Jax")
    }

    func test_skipsDissimilarMisspelling() {
        // A misspelled word not close to any glossary term is left alone.
        XCTAssertEqual(correct("Pneumonia"), "Pneumonia")
        XCTAssertEqual(correct("transcription"), "transcription")
    }

    func test_skipsAmbiguousMatch() {
        // A token within bound of TWO glossary terms is ambiguous → skip.
        // "Joxx" is 1 edit from "Jaxx"; craft a glossary where two terms tie.
        let g = ["Jaxx", "Joxx"]
        XCTAssertEqual(GlossaryCorrector.correct("Jexx", glossary: g, isRealWord: { _ in false }),
                       "Jexx", "equidistant from two terms → not corrected")
    }

    func test_emptyGlossary_noop() {
        XCTAssertEqual(GlossaryCorrector.correct("anything here", glossary: [], isRealWord: { _ in false }),
                       "anything here")
    }

    func test_multiWordGlossaryTermIgnored() {
        // Single-word correction only; a multi-word term is skipped entirely.
        let g = ["San Tessah"]
        XCTAssertEqual(GlossaryCorrector.correct("San Tesa", glossary: g, isRealWord: { _ in false }),
                       "San Tesa")
    }

    // MARK: - Curated exact overrides (the cases fuzzy can't safely fix)

    func test_override_appliesToRealWordGarble() {
        // "Kama" reads as a real word, so the fuzzy real-word guard would skip it.
        // A curated override forces it (the user confirmed Kama→Karma).
        let out = GlossaryCorrector.correct("Hey Kama, are you around?",
                                            glossary: glossary,
                                            overrides: ["kama": "Karma"],
                                            isRealWord: { _ in true })  // everything "real" → guard would block all fuzzy
        XCTAssertEqual(out, "Hey Karma, are you around?")
    }

    func test_override_appliesToShortToken() {
        // "CRF" is 3 chars — below the fuzzy length gate — so only an override fixes it.
        let out = GlossaryCorrector.correct("update the CRF please",
                                            glossary: [],
                                            overrides: ["crf": "CRM"],
                                            isRealWord: { _ in true })
        XCTAssertEqual(out, "update the CRM please")
    }

    func test_override_caseInsensitiveKey_runsWithEmptyGlossary() {
        let out = GlossaryCorrector.correct("Vohrba and VOHRBA",
                                            glossary: [],
                                            overrides: ["vohrba": "Vohrbach"],
                                            isRealWord: { _ in true })
        XCTAssertEqual(out, "Vohrbach and Vohrbach")
    }

    func test_override_doesNotTouchUnlistedWords() {
        let out = GlossaryCorrector.correct("the marina was nice",
                                            glossary: glossary,
                                            overrides: ["kama": "Karma"],
                                            isRealWord: isRealWord)
        XCTAssertEqual(out, "the marina was nice")
    }

    func test_glossaryTermsSplitFromCommaJoined() {
        // TextPipeline splits Config.loadVocabulary()'s ", "-joined string back to terms.
        XCTAssertEqual(TextPipeline.glossaryTerms("Claude, Zander, Jaxx"),
                       ["Claude", "Zander", "Jaxx"])
        XCTAssertEqual(TextPipeline.glossaryTerms(nil), [])
        XCTAssertEqual(TextPipeline.glossaryTerms(""), [])
    }
}
