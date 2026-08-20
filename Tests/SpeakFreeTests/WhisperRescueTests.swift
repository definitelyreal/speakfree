import XCTest
@testable import SpeakFreeLib

/// The whisper rescue/shadow thresholds and the comparison normalizer
/// (2026-08-20 confidence-fallback lane). The full rescue path needs live models;
/// these pin the pure decision pieces.
final class WhisperRescueTests: XCTestCase {
    func testShadowThresholdSitsBetweenGarbledAndCleanBands() {
        // Corpus bands (2026-08-20, 1,055 takes): garbled-but-fluent 0.73–0.83,
        // clean p25 = 0.945. The threshold must catch the former and skip the latter.
        XCTAssertGreaterThan(Transcriber.whisperShadowConfidenceThreshold, 0.83)
        XCTAssertLessThan(Transcriber.whisperShadowConfidenceThreshold, 0.945)
    }

    func testNormalizedComparisonIgnoresCasePunctuationWhitespace() {
        XCTAssertEqual(
            TextPipeline.normalizedForComparison("All right — let's GO?"),
            TextPipeline.normalizedForComparison("all right, lets go"),
            "casing/punctuation/contraction-only deltas are the same dictation")
        XCTAssertNotEqual(
            TextPipeline.normalizedForComparison("reach out in a few weeks"),
            TextPipeline.normalizedForComparison("reject in a few weeks"),
            "real word substitutions must still differ")
    }
}
