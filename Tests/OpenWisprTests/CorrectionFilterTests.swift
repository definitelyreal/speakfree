import XCTest
@testable import OpenWisprLib

final class CorrectionFilterTests: XCTestCase {

    // MARK: - isSimilar rejects short words

    func testRejectsShortWords() {
        // Words under 4 chars should not be "similar" to much longer words
        XCTAssertFalse(LevenshteinDistance.isSimilar("a", "about"))
        XCTAssertFalse(LevenshteinDistance.isSimilar("the", "a"))
        XCTAssertFalse(LevenshteinDistance.isSimilar("e", "easy"))
    }

    // MARK: - isSimilar accepts good corrections

    func testAcceptsGoodCorrections() {
        XCTAssertTrue(LevenshteinDistance.isSimilar("definately", "definitely"))
        XCTAssertTrue(LevenshteinDistance.isSimilar("recieve", "receive"))
        XCTAssertTrue(LevenshteinDistance.isSimilar("seperate", "separate"))
        XCTAssertTrue(LevenshteinDistance.isSimilar("occured", "occurred"))
    }

    // MARK: - isSimilar rejects unrelated words

    func testRejectsUnrelatedWords() {
        XCTAssertFalse(LevenshteinDistance.isSimilar("hello", "world"))
        XCTAssertFalse(LevenshteinDistance.isSimilar("computer", "banana"))
        XCTAssertFalse(LevenshteinDistance.isSimilar("love", "night"))
    }

    // MARK: - Real garbage entries from corrupted dictionary

    func testRejectsRealGarbageEntries() {
        // These are real entries from a corrupted dictionary
        XCTAssertFalse(shouldAcceptCorrection("a", "about"))
        XCTAssertFalse(shouldAcceptCorrection("the", "a"))
        XCTAssertFalse(shouldAcceptCorrection("co", "co-h"))
        XCTAssertFalse(shouldAcceptCorrection("e", "easy"))
        XCTAssertFalse(shouldAcceptCorrection("l", "love"))
        XCTAssertFalse(shouldAcceptCorrection("n", "night"))
        XCTAssertFalse(shouldAcceptCorrection("w", "would"))
    }

    // MARK: - Combined filter accepts real typos

    func testAcceptsRealTyposWithFullFilter() {
        XCTAssertTrue(shouldAcceptCorrection("definately", "definitely"))
        XCTAssertTrue(shouldAcceptCorrection("recieve", "receive"))
        XCTAssertTrue(shouldAcceptCorrection("seperate", "separate"))
        XCTAssertTrue(shouldAcceptCorrection("occured", "occurred"))
        XCTAssertTrue(shouldAcceptCorrection("accomodate", "accommodate"))
        XCTAssertTrue(shouldAcceptCorrection("beleive", "believe"))
    }

    // MARK: - Combined filter rejects short-word swaps

    func testRejectsShortWordSwapsWithFullFilter() {
        XCTAssertFalse(shouldAcceptCorrection("to", "too"))
        XCTAssertFalse(shouldAcceptCorrection("is", "it"))
        XCTAssertFalse(shouldAcceptCorrection("an", "and"))
        XCTAssertFalse(shouldAcceptCorrection("or", "of"))
    }

    // MARK: - Punctuation stripping

    func testPunctuationStrippedBeforeComparison() {
        // Words with trailing punctuation should still match
        XCTAssertTrue(shouldAcceptCorrection("definately,", "definitely,"))
        XCTAssertTrue(shouldAcceptCorrection("\"recieve\"", "\"receive\""))
    }

    func testPunctuationOnlyRejects() {
        XCTAssertFalse(shouldAcceptCorrection("...", "!!!"))
        XCTAssertFalse(shouldAcceptCorrection(",", "."))
    }

    // MARK: - Helper mimicking CorrectionMonitor logic

    /// Mimics CorrectionMonitor.findSingleCorrection's per-word filter logic.
    private func shouldAcceptCorrection(_ wrong: String, _ right: String) -> Bool {
        let minLength = 4
        let stripped1 = wrong.trimmingCharacters(in: .punctuationCharacters)
        let stripped2 = right.trimmingCharacters(in: .punctuationCharacters)
        guard stripped1.count >= minLength && stripped2.count >= minLength else { return false }
        return LevenshteinDistance.isSimilar(stripped1, stripped2)
    }
}
