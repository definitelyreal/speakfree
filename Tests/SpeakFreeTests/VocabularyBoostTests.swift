// Claude · 2026-07-22 · Session: vocab-boost-eval worktree loop
//
// Unit tests for the VocabularyBoost guard chain and splicing — the pure pieces
// (no models, no audio). The end-to-end behavior is covered by the offline
// vocab-eval harness against the real corpus; these tests pin the invariants the
// 2026-07-03 failure taught us:
//   1. spans containing spoken-punctuation command words are NEVER rescored;
//   2. real-English-word spans are NEVER rescored (unless curated-aliased);
//   3. non-word garbles ARE eligible;
//   4. splicing only changes regions the rescorer explicitly claimed, and
//      reattaches trailing punctuation.

import XCTest
import FluidAudio
@testable import SpeakFreeLib

final class VocabularyBoostTests: XCTestCase {

    private func term(_ text: String, aliases: [String] = []) -> CustomVocabularyTerm {
        CustomVocabularyTerm(text: text, weight: 1.5,
                             aliases: aliases.isEmpty ? nil : aliases,
                             tokenIds: nil, ctcTokenIds: [1, 2, 3])
    }

    // MARK: - Guard chain

    func testPunctuationCommandSpanIsVetoed() {
        // "colon" garbled and matched toward a name must never be rescored.
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["colon"], term: term("Rohrlich")))
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["new", "line"], term: term("Maryna")))
        // …even when a curated alias claims the words (punctuation veto outranks aliases).
        XCTAssertNotNil(VocabularyBoost.vetoReason(
            originalSpan: ["new", "line"], term: term("Newline Inc", aliases: ["new line"])))
    }

    func testRealWordSpanIsVetoed() {
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["makes"], term: term("Mareesa")))
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["render."], term: term("Zander")))
        // Modern compound missing from web2 — caught by NSSpellChecker (iteration-2 fix).
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["timeline"], term: term("Trimble")))
    }

    func testCuratedAliasOverridesRealWordVeto() {
        XCTAssertNil(VocabularyBoost.vetoReason(
            originalSpan: ["marina"], term: term("Maryna", aliases: ["marina", "marin"])))
    }

    func testGarbleIsEligible() {
        XCTAssertNil(VocabularyBoost.vetoReason(originalSpan: ["rorlik"], term: term("Rohrlich")))
        XCTAssertNil(VocabularyBoost.vetoReason(originalSpan: ["pebblebet"], term: term("Pebblebed")))
        // Possessives and trailing punctuation still eligible.
        XCTAssertNil(VocabularyBoost.vetoReason(originalSpan: ["Xeander's"], term: term("Zander's")))
    }

    func testAcronymSpanIsVetoed() {
        // it2 false positive: TDT emitted the acronym 'AAF' (audio format), rescorer
        // proposed the name 'Naam'. ALL-CAPS spans are recognized acronyms — keep them.
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["AAF"], term: term("Naam")))
        // …but a term that IS that acronym may still claim it (EC2 case-fix path).
        XCTAssertNil(VocabularyBoost.vetoReason(originalSpan: ["EC-2"], term: term("EC2")))
    }

    func testLengthLossSpanIsVetoed() {
        // it2 false positive: 'Xanderbot' → 'Zander' swallowed the spoken "bot".
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["Xanderbot"], term: term("Zander")))
    }

    // MARK: - Splicing

    private func rescoring(_ original: String, _ replacement: String)
        -> VocabularyBoost.ProposedReplacement {
        VocabularyBoost.ProposedReplacement(
            original: original, replacement: replacement, score: -9.0, reason: "test")
    }

    func testSpliceAppliesAcceptedAndPreservesPunctuation() {
        let terms = ["rohrlich": term("Rohrlich")]
        let (text, decisions) = VocabularyBoost.spliceAcceptedReplacements(
            batchText: "Talk to rorlik, tomorrow.",
            rescoredText: "Talk to Rohrlich, tomorrow.",
            replacements: [rescoring("rorlik,", "Rohrlich")],
            termByText: terms)
        XCTAssertEqual(text, "Talk to Rohrlich, tomorrow.")
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions[0].accepted)
    }

    func testSpliceVetoesRealWordAndKeepsBatchText() {
        let terms = ["zander": term("Zander")]
        let (text, decisions) = VocabularyBoost.spliceAcceptedReplacements(
            batchText: "the most sense to render.",
            rescoredText: "the most sense to Zander",
            replacements: [rescoring("render.", "Zander")],
            termByText: terms)
        XCTAssertEqual(text, "the most sense to render.")
        XCTAssertEqual(decisions.count, 1)
        XCTAssertFalse(decisions[0].accepted)
    }

    func testSpliceIgnoresUnclaimedDiffRegions() {
        // Rescored text differs somewhere the rescorer did NOT claim → batch text wins.
        let (text, decisions) = VocabularyBoost.spliceAcceptedReplacements(
            batchText: "it still is paralleling physics",
            rescoredText: "it still is parallel. ing physics",
            replacements: [],
            termByText: [:])
        XCTAssertEqual(text, "it still is paralleling physics")
        XCTAssertEqual(decisions.count, 1)
        XCTAssertFalse(decisions[0].accepted)
        XCTAssertEqual(decisions[0].reason, "unmatched-diff-region")
    }

    // MARK: - Prefilter

    private func context(_ terms: [CustomVocabularyTerm]) -> CustomVocabularyContext {
        CustomVocabularyContext(terms: terms)
    }

    func testPrefilterSkipsAllRealWordText() {
        let ctx = context([term("Rohrlich"), term("Zander")])
        XCTAssertFalse(VocabularyBoost.hasEligibleToken(
            batchText: "See what you think makes the most sense to render.", vocabulary: ctx))
    }

    func testPrefilterCatchesGarbleToken() {
        let ctx = context([term("Rohrlich")])
        XCTAssertTrue(VocabularyBoost.hasEligibleToken(
            batchText: "Please ping rorlik about the screener.", vocabulary: ctx))
    }

    func testPrefilterCatchesAliasPhraseOfRealWords() {
        let ctx = context([term("Maryna", aliases: ["marina"])])
        XCTAssertTrue(VocabularyBoost.hasEligibleToken(
            batchText: "I talked to marina about the boat.", vocabulary: ctx))
    }

    // MARK: - Codex-review hardening (2026-07-22)

    func testWhitespaceIsPreservedWhenEverythingIsVetoed() {
        // [CX1] a vetoed run must return the batch text BYTE-identical, including
        // odd whitespace the LCS word-join would collapse.
        let batch = "the  most sense\nto render."
        let (text, _) = VocabularyBoost.spliceAcceptedReplacements(
            batchText: batch,
            rescoredText: "the most sense to Zander",
            replacements: [rescoring("render.", "Zander")],
            termByText: ["zander": term("Zander")])
        XCTAssertEqual(text, batch)
    }

    func testWhitespaceOutsideAcceptedSpanIsPreserved() {
        let batch = "Talk  to rorlik,\ntomorrow."
        let (text, decisions) = VocabularyBoost.spliceAcceptedReplacements(
            batchText: batch,
            rescoredText: "Talk to Rohrlich, tomorrow.",
            replacements: [rescoring("rorlik,", "Rohrlich")],
            termByText: ["rohrlich": term("Rohrlich")])
        XCTAssertEqual(text, "Talk  to Rohrlich,\ntomorrow.")
        XCTAssertTrue(decisions[0].accepted)
    }

    func testDigitSpanIsVetoed() {
        // [CX19] numbers/versions/model ids are never garbled names.
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["v2"], term: term("Naam")))
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["2026"], term: term("Bexx")))
    }

    func testMixedCaseAcronymIsVetoed() {
        // [CX21] LLMs / eBPF / iOS style tokens are decoder-recognized acronyms.
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["LLMs"], term: term("Naam")))
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["eBPF"], term: term("Bexx")))
    }

    func testContractionIsRealWord() {
        // [CX18] "don't" must be protected even though stripping the apostrophe
        // yields the non-word "dont".
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["don't"], term: term("Doxbox")))
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["day-to-day"], term: term("Doxbox")))
    }

    func testMixedSpanWithRealWordIsVetoed() {
        // [CX14] a span containing ANY real word must not be swallowed by a term.
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["to", "rorlik"], term: term("Rohrlich")))
    }

    func testLengthGainIsVetoed() {
        // [CX15] a short garble must not balloon into a much longer term.
        XCTAssertNotNil(VocabularyBoost.vetoReason(originalSpan: ["xa"], term: term("Pebblebed")))
    }

    func testDuplicateTermKeysDoNotTrap() {
        // [CX13] duplicate textLowercased values must not crash the splice.
        let t1 = term("Bexx")
        let terms = ["bexx": t1]
        let (text, _) = VocabularyBoost.spliceAcceptedReplacements(
            batchText: "ping becks now",
            rescoredText: "ping Bexx now",
            replacements: [rescoring("becks", "Bexx")],
            termByText: terms)
        XCTAssertEqual(text, "ping becks now")  // "becks" is a real word → vetoed
    }

    func testMultiWordTermWithPunctuationWordIsNotLoaded() {
        // [CX35] "New Line Cinema" must not enter the vocabulary.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-boost-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("vocabulary.txt")
        try? "New Line Cinema\nRohrlich\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(VocabularyBoost.loadTermSpecs(vocabularyFile: f).map { $0.text },
                       ["Rohrlich"])
    }

    func testTokenizePreservingGapsRoundTrips() {
        for s in ["a b", " a  b\nc ", "", "  ", "one", "\ttab\tsep\t"] {
            let (words, gaps) = VocabularyBoost.tokenizePreservingGaps(s)
            XCTAssertEqual(gaps.count, words.count + 1, "gap invariant for \(s.debugDescription)")
            var rebuilt = gaps[0]
            for (i, w) in words.enumerated() { rebuilt += w + gaps[i + 1] }
            XCTAssertEqual(rebuilt, s)
        }
    }

    func testPrefilterProtectsAcronymAndDigitTokens() {
        // [CX37]/[CX39] tokens the guard would veto do not trigger the CTC pass.
        let ctx = context([term("Naam"), term("Bexx")])
        XCTAssertFalse(VocabularyBoost.hasEligibleToken(
            batchText: "The AAF spec and v2 build ship in 2026.", vocabulary: ctx))
    }

    func testTermLoadingSkipsPunctuationAndComments() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-boost-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("vocabulary.txt")
        try? """
        # comment
        Rohrlich
        comma
        Gaubert # brain
        CLAUDE.md
        EC2 # manual
        """.write(to: f, atomically: true, encoding: .utf8)
        let specs = VocabularyBoost.loadTermSpecs(vocabularyFile: f)
        XCTAssertEqual(specs.map { $0.text }, ["Rohrlich", "Gaubert", "EC2"])
    }
}
