import XCTest
@testable import SpeakFreeLib

final class LevenshteinDistanceTests: XCTestCase {

    // MARK: - distance()

    func testIdenticalStrings() {
        XCTAssertEqual(LevenshteinDistance.distance("hello", "hello"), 0)
    }

    func testSingleCharDifference() {
        // substitution: cat -> car
        XCTAssertEqual(LevenshteinDistance.distance("cat", "car"), 1)
    }

    func testInsertion() {
        // insertion: cat -> cats
        XCTAssertEqual(LevenshteinDistance.distance("cat", "cats"), 1)
    }

    func testDeletion() {
        // deletion: cats -> cat
        XCTAssertEqual(LevenshteinDistance.distance("cats", "cat"), 1)
    }

    func testCompletelyDifferent() {
        XCTAssertEqual(LevenshteinDistance.distance("abc", "xyz"), 3)
    }

    func testEmptyFirstString() {
        XCTAssertEqual(LevenshteinDistance.distance("", "abc"), 3)
    }

    func testEmptySecondString() {
        XCTAssertEqual(LevenshteinDistance.distance("abc", ""), 3)
    }

    func testBothEmpty() {
        XCTAssertEqual(LevenshteinDistance.distance("", ""), 0)
    }

    // MARK: - isSimilar()

    func testSimilarWords() {
        // "definitely" vs "definately" — edit distance 2, max length 10 -> 20 % < 40 %
        XCTAssertTrue(LevenshteinDistance.isSimilar("definitely", "definately"))
    }

    func testSimilarWordsReversed() {
        XCTAssertTrue(LevenshteinDistance.isSimilar("definately", "definitely"))
    }

    func testSimilarCaseInsensitive() {
        XCTAssertTrue(LevenshteinDistance.isSimilar("Hello", "hello"))
    }

    func testDissimilarWords() {
        // "a" vs "about" — completely different lengths, should not be similar
        XCTAssertFalse(LevenshteinDistance.isSimilar("a", "about"))
    }

    func testDissimilarShortWords() {
        // "the" vs "cat" — distance 3, max 3 -> 100 % >= 40 %
        XCTAssertFalse(LevenshteinDistance.isSimilar("the", "cat"))
    }

    func testEmptyStringNotSimilar() {
        XCTAssertFalse(LevenshteinDistance.isSimilar("", "hello"))
        XCTAssertFalse(LevenshteinDistance.isSimilar("hello", ""))
        XCTAssertFalse(LevenshteinDistance.isSimilar("", ""))
    }

    func testPlausibleTypo() {
        // "recieve" -> "receive" — distance 2, max 7 -> ~29 % < 40 %
        XCTAssertTrue(LevenshteinDistance.isSimilar("recieve", "receive"))
    }

    func testTotallyDifferentLongWords() {
        // "beautiful" vs "dangerous" — distance 7, max 9 -> ~78 % >= 40 %
        XCTAssertFalse(LevenshteinDistance.isSimilar("beautiful", "dangerous"))
    }
}
