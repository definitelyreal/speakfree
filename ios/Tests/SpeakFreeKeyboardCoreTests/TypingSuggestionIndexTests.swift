// ai-suggestion:unverified · session:unknown · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class TypingSuggestionIndexTests: XCTestCase {
    private let index = TypingSuggestionIndex(entries: [
        VocabularyEntry(word: "the", frequency: 100),
        VocabularyEntry(word: "there", frequency: 80),
        VocabularyEntry(word: "their", frequency: 70),
        VocabularyEntry(word: "therapy", frequency: 10),
        VocabularyEntry(word: "then", frequency: 60),
        VocabularyEntry(word: "hello", frequency: 50),
        VocabularyEntry(word: "help", frequency: 40),
        VocabularyEntry(word: "spelling", frequency: 30),
        VocabularyEntry(word: "we're", frequency: 20),
    ])

    func testPrefixSuggestionsAreCaseInsensitiveFrequencyRankedAndLimited() {
        XCTAssertEqual(
            index.prefixSuggestions(for: "THE", limit: 3).map(\.word),
            ["there", "their", "then"]
        )
        XCTAssertEqual(index.prefixSuggestions(for: "hello").map(\.word), [])
        XCTAssertEqual(index.prefixSuggestions(for: "").map(\.word), [])
        XCTAssertEqual(index.prefixSuggestions(for: "he", limit: 0).map(\.word), [])
    }

    func testDuplicateEntriesAreAggregatedCaseInsensitively() {
        let duplicateIndex = TypingSuggestionIndex(entries: [
            VocabularyEntry(word: "Hello", frequency: 2),
            VocabularyEntry(word: "hello", frequency: 3),
            VocabularyEntry(word: "help", frequency: 4),
        ])

        let suggestions = duplicateIndex.prefixSuggestions(for: "hel", limit: 2)
        XCTAssertEqual(suggestions.map(\.word), ["Hello", "help"])
        XCTAssertEqual(suggestions.first?.frequency, 5)
    }

    func testCorrectionHandlesTranspositionSubstitutionInsertionAndDeletion() {
        XCTAssertEqual(index.bestCorrection(for: "teh")?.word, "the")
        XCTAssertEqual(index.bestCorrection(for: "hellp")?.word, "hello")
        XCTAssertEqual(index.bestCorrection(for: "ther" )?.word, "the")
        XCTAssertEqual(index.bestCorrection(for: "speling")?.word, "spelling")
    }

    func testCorrectionIsConservativeForShortExactAndDistantWords() {
        XCTAssertNil(index.bestCorrection(for: "te"))
        XCTAssertNil(index.bestCorrection(for: "the"))
        XCTAssertNil(index.bestCorrection(for: "zzzzz"))
    }

    func testLongWordsMayUseTwoEditsButShortWordsMayNot() {
        XCTAssertEqual(index.bestCorrection(for: "speling")?.word, "spelling")
        XCTAssertNil(index.bestCorrection(for: "hlrp"))
    }

    func testCorrectionRankingPrefersDistanceThenFrequencyThenSpelling() {
        let rankingIndex = TypingSuggestionIndex(entries: [
            VocabularyEntry(word: "cat", frequency: 5),
            VocabularyEntry(word: "cot", frequency: 10),
            VocabularyEntry(word: "cut", frequency: 10),
        ])
        XCTAssertEqual(
            rankingIndex.correctionSuggestions(for: "cit", limit: 3).map(\.word),
            ["cot", "cut", "cat"]
        )
    }

    func testCurlyAndStraightApostrophesNormalizeTogether() {
        XCTAssertEqual(index.prefixSuggestions(for: "we’").map(\.word), ["we're"])
        XCTAssertEqual(index.correctionSuggestions(for: "we’re"), [])
    }

    func testInvalidVocabularyRowsAreIgnored() {
        let emptyIndex = TypingSuggestionIndex(entries: [
            VocabularyEntry(word: "123", frequency: .infinity),
            VocabularyEntry(word: "", frequency: -1),
        ])
        XCTAssertTrue(emptyIndex.isEmpty)
    }
}
