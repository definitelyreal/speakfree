import XCTest
@testable import SpeakFreeLib

final class ReplacementsTests: XCTestCase {
    private func apply(_ rules: [String: String], _ text: String) -> String {
        Replacements(rules).apply(to: text)
    }

    func testASingleWordIsReplaced() {
        XCTAssertEqual(apply(["kama": "Karma"], "the kama project"), "the Karma project")
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(apply(["kama": "Karma"], "the KAMA project"), "the Karma project")
        XCTAssertEqual(apply(["KAMA": "Karma"], "the kama project"), "the Karma project")
    }

    func testAPhraseIsReplaced() {
        XCTAssertEqual(apply(["wag one": "wagwan"], "he said wag one to me"), "he said wagwan to me")
    }

    func testNumbersCountAsWords() {
        // The engine writes spoken numbers as digits: "wag one" is heard as "Wag 1."
        XCTAssertEqual(apply(["wag 1": "wagwan"], "so wag 1 everyone"), "so wagwan everyone")
        XCTAssertEqual(apply(["3 m": "3M"], "we sell to 3 M now"), "we sell to 3M now")
    }

    func testAPhraseMatchesThroughPunctuation() {
        XCTAssertEqual(apply(["wag one": "wagwan"], "he said wag, one to me"), "he said wagwan to me")
        XCTAssertEqual(apply(["at t": "AT&T"], "call AT&T today"), "call AT&T today")
    }

    func testAPhraseDoesNotMatchAcrossALineBreak() {
        XCTAssertEqual(apply(["wag one": "wagwan"], "wag\none"), "wag\none")
    }

    func testOnlyWholeWordsMatch() {
        XCTAssertEqual(apply(["cat": "dog"], "concatenate the category"), "concatenate the category")
        XCTAssertEqual(apply(["wag one": "wagwan"], "swag one"), "swag one")
    }

    func testSurroundingPunctuationIsKept() {
        XCTAssertEqual(apply(["kama": "Karma"], "Is it (kama)? Yes, kama."), "Is it (Karma)? Yes, Karma.")
    }

    func testTheLongestTriggerWins() {
        let rules = ["new york": "NY", "new york city": "NYC", "york": "Yorkshire"]
        XCTAssertEqual(apply(rules, "from new york city to york"), "from NYC to Yorkshire")
    }

    func testReplacedTextIsNotReplacedAgain() {
        XCTAssertEqual(apply(["a": "b", "b": "a"], "say a b"), "say b a")
        XCTAssertEqual(apply(["one": "one two", "two": "three"], "say one"), "say one two")
    }

    func testAnAllLowercaseReplacementIsCapitalisedAtTheStartOfASentence() {
        XCTAssertEqual(apply(["wag one": "wagwan"], "wag one mate. wag one again! and wag one"),
                       "Wagwan mate. Wagwan again! and wagwan")
    }

    func testAReplacementWithItsOwnCapitalsIsWrittenExactly() {
        XCTAssertEqual(apply(["i phone": "iPhone"], "i phone is here. i phone"), "iPhone is here. iPhone")
        XCTAssertEqual(apply(["kama": "Karma"], "kama"), "Karma")
    }

    func testNoRulesLeavesTextAlone() {
        XCTAssertTrue(Replacements([:]).isEmpty)
        XCTAssertEqual(apply([:], "nothing changes here."), "nothing changes here.")
        XCTAssertEqual(apply(["": "x", "  ": "y"], "nothing changes here."), "nothing changes here.")
    }

    func testTriggersAreNormalised() {
        XCTAssertEqual(Replacements.normalize("  Wag,  One. "), "wag one")
        XCTAssertEqual(Replacements.normalize("AT&T"), "at t")
        XCTAssertEqual(Replacements.normalize("Don't"), "don't")
        XCTAssertEqual(Replacements.normalize("?!"), "")
    }

    func testSegmentsMarkWhatWasReplaced() {
        let segments = Replacements(["kama": "Karma"]).segments(of: "the kama one")
        XCTAssertEqual(segments.map(\.text), ["the ", "Karma", " one"])
        XCTAssertEqual(segments.map(\.isReplacement), [false, true, false])
    }

    func testALargeRuleSetStaysFast() {
        // The pass must scale with the dictation, not with the number of rules.
        var rules: [String: String] = [:]
        for i in 0..<5_000 { rules["trigger\(i) word\(i)"] = "replacement\(i)" }
        rules["wag one"] = "wagwan"
        let replacements = Replacements(rules)
        let sentence = "the quick brown fox said wag one and jumped over the lazy dog, twice. "
        let text = String(repeating: sentence, count: 40)   // about 560 words
        let started = CFAbsoluteTimeGetCurrent()
        var output = ""
        for _ in 0..<20 { output = replacements.apply(to: text) }
        let perPass = (CFAbsoluteTimeGetCurrent() - started) / 20
        XCTAssertTrue(output.contains("said wagwan and"))
        XCTAssertLessThan(perPass, 0.005, "one pass over a 560-word dictation took \(perPass * 1000) ms")
    }

    // MARK: - In the text pipeline

    private func run(_ raw: String, rules: [String: String], glossary: String? = nil,
                     contextBefore: String? = nil) -> String {
        TextPipeline.run(
            TextPipeline.Input(raw: raw, punctuationMode: .off, cursorContextText: contextBefore,
                               glossaryWords: glossary, overrides: rules),
            isRealWord: { _ in false }).finalText
    }

    func testThePipelineAppliesPhraseReplacements() {
        XCTAssertEqual(run("he said wag one to me", rules: ["wag one": "wagwan"]),
                       "he said wagwan to me")
    }

    func testAReplacementIsNotThenRewrittenByTheVocabularyCorrector() {
        // "Karmaa" is one edit from the vocabulary word "Karma"; a replacement's output is final.
        XCTAssertEqual(run("the kama thing", rules: ["kama": "Karmaa"], glossary: "Karma"),
                       "the Karmaa thing")
    }

    func testAnExactReplacementKeepsItsCapitalMidSentence() {
        XCTAssertEqual(run("acme is here", rules: ["acme": "Acme"], contextBefore: "I think "),
                       "Acme is here")
        // A lowercase replacement capitalised only for a sentence start follows the cursor.
        XCTAssertEqual(run("wag one mate", rules: ["wag one": "wagwan"], contextBefore: "I think "),
                       "wagwan mate")
    }
}
