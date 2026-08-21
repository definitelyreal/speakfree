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

// MARK: - Active-swap tiers (Michael approved the swap 2026-08-20)

final class SecondOpinionTierTests: XCTestCase {
    func testWordSaladBandActivelySwaps() {
        // Every known garbled take scored 0.73–0.83 (airplane forensics + corpus).
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.73), .activeSwap)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.83), .activeSwap)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.849), .activeSwap)
    }

    func testMixedBandStaysShadowOnly() {
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.85), .shadow)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.91), .shadow)
    }

    func testCleanTakesGetNoSecondOpinion() {
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.92), Transcriber.SecondOpinionTier.none)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.97), Transcriber.SecondOpinionTier.none)
    }

    func testEmptySentinelAndMissingConfidenceAreNotSwapped() {
        // 0.1 is the engine's empty sentinel — the empty-rescue path owns it.
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.1), Transcriber.SecondOpinionTier.none)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: nil), Transcriber.SecondOpinionTier.none)
    }
}
