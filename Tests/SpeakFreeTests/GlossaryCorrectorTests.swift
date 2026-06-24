import XCTest
@testable import SpeakFreeLib

final class GlossaryCorrectorTests: XCTestCase {

    // Curated names mirroring Michael's real glossary shape.
    let glossary = ["Rohrlich", "Bexx", "Maryna", "Pessah", "Doxbox", "Viktor"]

    // Deterministic real-word fixture: these are legitimate words the spell
    // checker would accept (so they must NEVER be corrected to a name).
    let realWords: Set<String> = ["marina", "victor", "could", "election", "doctor", "the", "boat", "was", "beautiful", "hey", "how", "are", "you"]
    func isRealWord(_ w: String) -> Bool { realWords.contains(w.lowercased()) }

    private func correct(_ text: String) -> String {
        GlossaryCorrector.correct(text, glossary: glossary, isRealWord: isRealWord)
    }

    // MARK: - Corrects near-miss misspellings

    func test_correctsNearMiss() {
        XCTAssertEqual(correct("Rorlick"), "Rohrlich")   // 2 edits, 8-char name
        XCTAssertEqual(correct("Pesa"), "Pessah")        // within bound
        XCTAssertEqual(correct("Doxbox"), "Doxbox")      // 1 edit
    }

    func test_correctsWithinSentence_preservesPunctuationAndSpacing() {
        XCTAssertEqual(correct("Hey Rorlick, how are you?"),
                       "Hey Rohrlich, how are you?")
        XCTAssertEqual(correct("tell Pesa and Maryna"),
                       "tell Pessah and Maryna")
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
        XCTAssertEqual(correct("bexx is coming"), "Bexx is coming")   // mid-sentence lowercased name → curated case
        XCTAssertEqual(correct("BEXX"), "Bexx")
        XCTAssertEqual(correct("Viktor"), "Viktor")                   // already correct
    }

    // MARK: - Skips

    func test_skipsShortTokens() {
        // 3 chars or fewer never eligible (avoids noise) — "Bex" stays.
        XCTAssertEqual(correct("Bex"), "Bex")
    }

    func test_skipsDissimilarMisspelling() {
        // A misspelled word not close to any glossary term is left alone.
        XCTAssertEqual(correct("Pneumonia"), "Pneumonia")
        XCTAssertEqual(correct("transcription"), "transcription")
    }

    func test_skipsAmbiguousMatch() {
        // A token within bound of TWO glossary terms is ambiguous → skip.
        // "Baxx" is 1 edit from "Bexx"; craft a glossary where two terms tie.
        let g = ["Bexx", "Baxx"]
        XCTAssertEqual(GlossaryCorrector.correct("Boxx", glossary: g, isRealWord: { _ in false }),
                       "Boxx", "equidistant from two terms → not corrected")
    }

    func test_emptyGlossary_noop() {
        XCTAssertEqual(GlossaryCorrector.correct("anything here", glossary: [], isRealWord: { _ in false }),
                       "anything here")
    }

    func test_multiWordGlossaryTermIgnored() {
        // Single-word correction only; a multi-word term is skipped entirely.
        let g = ["San Pessah"]
        XCTAssertEqual(GlossaryCorrector.correct("San Pesa", glossary: g, isRealWord: { _ in false }),
                       "San Pesa")
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
        let out = GlossaryCorrector.correct("Rohrli and ROHRLI",
                                            glossary: [],
                                            overrides: ["rohrli": "Rohrlich"],
                                            isRealWord: { _ in true })
        XCTAssertEqual(out, "Rohrlich and Rohrlich")
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
        XCTAssertEqual(TextPipeline.glossaryTerms("Claude, Zander, Bexx"),
                       ["Claude", "Zander", "Bexx"])
        XCTAssertEqual(TextPipeline.glossaryTerms(nil), [])
        XCTAssertEqual(TextPipeline.glossaryTerms(""), [])
    }
}
