import XCTest
@testable import SpeakFreeLib

final class DualTranscriptMergerTests: XCTestCase {
    func testEmptyBluetoothFallsBackToPrimary() {
        assertPrimary("Testing one two three", bluetooth: "")
    }

    func testOneWordBluetoothCannotReplaceEmptyPrimary() {
        assertPrimary("", bluetooth: "Maybe")
    }

    func testBluetoothCanRescueAnEmptyPrimaryWithMultipleWords() {
        let result = DualCapture.mergeTranscripts(primary: "", bluetooth: "Testing one two")
        XCTAssertEqual(result.text, "Testing one two")
        XCTAssertEqual(result.reason, .bluetoothOnly)
    }

    func testIdenticalWordsKeepCompletePrimaryCasing() {
        let result = DualCapture.mergeTranscripts(
            primary: "testing one two three", bluetooth: "Testing one, two, three!")
        XCTAssertEqual(result.text, "testing one two three")
        XCTAssertEqual(result.reason, .identical)
        XCTAssertFalse(result.usedBluetooth)
    }

    func testBuiltInSuppliesPrefixBluetoothMissed() {
        let result = DualCapture.mergeTranscripts(
            primary: "Before bluetooth opened testing one two three",
            bluetooth: "testing one two three")
        XCTAssertEqual(result.text, "Before bluetooth opened testing one two three")
        XCTAssertTrue(result.usedBluetooth)
    }

    func testBuiltInSuppliesSuffixBluetoothMissed() {
        let result = DualCapture.mergeTranscripts(
            primary: "testing one two three after bluetooth closed",
            bluetooth: "testing one two three")
        XCTAssertEqual(result.text, "testing one two three after bluetooth closed")
        XCTAssertTrue(result.usedBluetooth)
    }

    func testBuiltInSuppliesBothBoundaries() {
        let result = DualCapture.mergeTranscripts(
            primary: "early words testing one two three late words",
            bluetooth: "testing one two three")
        XCTAssertEqual(result.text, "early words testing one two three late words")
        XCTAssertTrue(result.usedBluetooth)
    }

    func testBluetoothCorrectionWinsInsideStrongAnchors() {
        let result = DualCapture.mergeTranscripts(
            primary: "we made some defakes for the adr team today",
            bluetooth: "we made some deepfakes for the ADR team today")
        XCTAssertEqual(result.text, "we made some deepfakes for the ADR team today")
        XCTAssertTrue(result.usedBluetooth)
    }

    func testLateBluetoothSentenceCaseDoesNotCapitalizeMiddleAnchor() {
        let result = DualCapture.mergeTranscripts(
            primary: "I really want to feel the impact of each bonus coming in period.",
            bluetooth: "The impact of each bonus coming in period.")
        XCTAssertEqual(
            result.text,
            "I really want to feel the impact of each bonus coming in period.")
    }

    func testLateBluetoothCaseDoesNotCapitalizeAfterBut() {
        let result = DualCapture.mergeTranscripts(
            primary: "Make it look like this, but more built into our style.",
            bluetooth: "More built into our style.")
        XCTAssertEqual(result.text, "Make it look like this, but more built into our style.")
    }

    func testPrimaryAnchorPreservesAcronymCaseWithoutLowercaseHeuristic() {
        let result = DualCapture.mergeTranscripts(
            primary: "we should ask the API team about this tomorrow",
            bluetooth: "Api team about this tomorrow")
        XCTAssertEqual(result.text, "we should ask the API team about this tomorrow")
    }

    func testUnalignedBluetoothFallsBackConservatively() {
        assertPrimary(
            "the intended primary transcript remains complete",
            bluetooth: "unrelated hallucinated words from another source")
    }

    func testSparseGenericAnchorsDoNotAuthorizeDivergentMiddle() {
        assertPrimary(
            "we need to finish the correct proposal for our client",
            bluetooth: "we wandered through a completely different story for somebody")
    }

    func testLargeBluetoothBoundaryHallucinationsForcePrimaryFallback() {
        let result = DualCapture.mergeTranscripts(
            primary: "built in prefix testing one two three built in suffix",
            bluetooth: "hallucinated opening testing one two three hallucinated ending")
        XCTAssertEqual(result.text, "built in prefix testing one two three built in suffix")
        XCTAssertFalse(result.usedBluetooth)
    }

    func testRepeatedOverlapDoesNotDuplicateWords() {
        let result = DualCapture.mergeTranscripts(
            primary: "start now now testing one two three finish",
            bluetooth: "now testing one two three")
        XCTAssertEqual(result.text, "start now now testing one two three finish")
    }

    func testReorderedWordsFallBack() {
        assertPrimary(
            "alpha beta gamma delta epsilon",
            bluetooth: "epsilon delta gamma beta alpha")
    }

    // MARK: - Omission guard (adversarial review 2026-07-21)
    // A BT track that is a pure subsequence of the primary scores coverage 1.0 —
    // the gate cannot see dropped words. Importing its middle would DELETE them.

    func testBluetoothDroppedNegationNeverDeletesIt() {
        let result = DualCapture.mergeTranscripts(
            primary: "please do not send the final report today",
            bluetooth: "please do send the final report today")
        XCTAssertEqual(result.text, "please do not send the final report today",
                       "a BT dropout must never delete a spoken negation")
        XCTAssertEqual(result.reason, .bluetoothOmission)
        XCTAssertFalse(result.usedBluetooth)
    }

    func testBluetoothDroppedInteriorWordFallsBackToPrimary() {
        let result = DualCapture.mergeTranscripts(
            primary: "testing one two three three finish",
            bluetooth: "testing one two three finish")
        XCTAssertEqual(result.text, "testing one two three three finish",
                       "a repeated spoken word must survive when BT heard fewer copies")
        XCTAssertEqual(result.reason, .bluetoothOmission)
    }

    func testContractionSubstitutionStillMerges() {
        // Both gaps non-empty = substitution, not omission: "did not"→"didn't" keeps
        // the meaning and remains merge-eligible.
        let result = DualCapture.mergeTranscripts(
            primary: "well I did not send it to them today",
            bluetooth: "well I didn't send it to them today")
        XCTAssertEqual(result.text, "well I didn't send it to them today")
        XCTAssertEqual(result.reason, .aligned)
    }

    func testBluetoothInsertionOfHeardWordStillMerges() {
        // BT-only gap = the close mic heard a word the far mic missed. Allowed.
        let result = DualCapture.mergeTranscripts(
            primary: "please send the report to them tomorrow",
            bluetooth: "please send the daily report to them tomorrow")
        XCTAssertEqual(result.text, "please send the daily report to them tomorrow")
        XCTAssertEqual(result.reason, .aligned)
    }

    // MARK: - Negation guard (adversarial round 2, 2026-07-21)
    // The omission guard sees dropouts; a SUBSTITUTION that replaces a negation
    // ("not"→"please") passes both gates and inverts meaning. Never import it.

    func testSubstitutionThatLosesNegationFallsBack() {
        let result = DualCapture.mergeTranscripts(
            primary: "please do not forward this message",
            bluetooth: "please do please forward this message")
        XCTAssertEqual(result.text, "please do not forward this message")
        XCTAssertEqual(result.reason, .negationRisk)
        XCTAssertFalse(result.usedBluetooth)
    }

    func testSubstitutionThatLosesContractedNegationFallsBack() {
        let result = DualCapture.mergeTranscripts(
            primary: "they won't come to the meeting today",
            bluetooth: "they will come to the meeting today")
        XCTAssertEqual(result.text, "they won't come to the meeting today")
        XCTAssertEqual(result.reason, .negationRisk)
    }

    func testNegationPreservingSubstitutionStillMerges() {
        // "did not"→"didn't" keeps a negation on both sides of the gap — mergeable.
        let result = DualCapture.mergeTranscripts(
            primary: "well I did not send it to them today",
            bluetooth: "well I didn't send it to them today")
        XCTAssertEqual(result.text, "well I didn't send it to them today")
        XCTAssertEqual(result.reason, .aligned)
    }

    // MARK: - Suffix seam punctuation (adversarial review 2026-07-21)

    func testTerminalPunctuationSurvivesWhenBluetoothOmitsIt() {
        let result = DualCapture.mergeTranscripts(
            primary: "I want to feel the impact of this change.",
            bluetooth: "the impact of this change")
        XCTAssertEqual(result.text, "I want to feel the impact of this change.",
                       "primary's terminal period must survive a BT track without one")
        XCTAssertTrue(result.usedBluetooth)
    }

    func testSeamCommaFromPrimarySurvivesMerge() {
        let result = DualCapture.mergeTranscripts(
            primary: "we can feel the impact of this, and then finish",
            bluetooth: "the impact of this")
        XCTAssertEqual(result.text, "we can feel the impact of this, and then finish",
                       "primary punctuation right after the last anchor must survive")
    }

    func testQuestionMarkSurvivesWithBluetoothMiddleWin() {
        // BT wins a substitution in the middle AND the primary's terminal "?" survives.
        let result = DualCapture.mergeTranscripts(
            primary: "did you send the defakes files to the whole team yet?",
            bluetooth: "you send the deepfakes files to the whole team yet")
        XCTAssertEqual(result.text, "did you send the deepfakes files to the whole team yet?")
        XCTAssertEqual(result.reason, .aligned)
    }

    private func assertPrimary(
        _ primary: String, bluetooth: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let result = DualCapture.mergeTranscripts(primary: primary, bluetooth: bluetooth)
        XCTAssertEqual(result.text, primary, file: file, line: line)
        XCTAssertFalse(result.usedBluetooth, file: file, line: line)
    }
}
