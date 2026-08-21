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
    func testConfidenceAloneNeverSwaps() {
        // Revised 2026-08-21: the 23-take active-band adjudication measured the
        // confidence-triggered swap helping 30% and harming 43% — withdrawn. Every
        // sub-0.92 confidence is shadow-only now; replacement is empty/sparse rescue.
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.73), .shadow)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.83), .shadow)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.85), .shadow)
        XCTAssertEqual(Transcriber.secondOpinionTier(aggregateConfidence: 0.91), .shadow)
    }

    func testSparseRescueGates() {
        // The dropped-sentence shape: 14.7s of audio, 6 words out.
        XCTAssertTrue(Transcriber.sparseRescueEligible(parakeetWordCount: 6, durationSeconds: 14.7))
        // Normal speech density is never "sparse".
        XCTAssertFalse(Transcriber.sparseRescueEligible(parakeetWordCount: 30, durationSeconds: 15))
        // Short takes are excluded — 2 words in 3s is a normal quick command.
        XCTAssertFalse(Transcriber.sparseRescueEligible(parakeetWordCount: 2, durationSeconds: 3))
        // Adjudication row 0048940D: whisper collapsed to "Oh!" — a SHORTER candidate
        // must never replace (this row was PARAKEET_BETTER).
        XCTAssertFalse(Transcriber.sparseRescueAccepts(parakeetWordCount: 6, whisperWordCount: 1))
        XCTAssertTrue(Transcriber.sparseRescueAccepts(parakeetWordCount: 6, whisperWordCount: 14))
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

// MARK: - Stats display helpers (Michael 2026-08-20 two-line format)

final class UsageStatsDisplayTests: XCTestCase {
    func testDaysHoursMinutesFormatting() {
        XCTAssertEqual(UsageStats.formatDaysHoursMinutes(59), "0 minutes")
        XCTAssertEqual(UsageStats.formatDaysHoursMinutes(3_660), "1 hour 1 minute")
        XCTAssertEqual(UsageStats.formatDaysHoursMinutes(90_000), "1 day 1 hour 0 minutes")
    }

    func testHandTravelAssumption() {
        // 2 cm per keystroke: 1M keystrokes = 20 km ≈ 12.4 miles. The constant is the
        // stated assumption; this pins it so a silent change shows up in review.
        XCTAssertEqual(UsageStats.handTravelMetresPerKeystroke, 0.02)
    }
}

// MARK: - Active-swap vetoes (2026-08-21 adjudication of 64 mixed-band takes)

final class ActiveSwapVetoTests: XCTestCase {
    func testLongTakeIsVetoed() {
        XCTAssertNotNil(Transcriber.activeSwapVeto(
            parakeet: "some text", whisper: "other text", durationSeconds: 25))
    }

    func testWhisperLosingCommandWordsIsVetoed() {
        // Adjudication row 19E56FFF: whisper normalized spoken "comma" away.
        XCTAssertNotNil(Transcriber.activeSwapVeto(
            parakeet: "mark what you need comma then send it",
            whisper: "mark what you need, then send it",
            durationSeconds: 8))
    }

    func testWhisperLosingProtectedTermIsVetoed() {
        // Adjudication row 1FD7F685: Fable -> "favorable", Codex -> "codecs".
        XCTAssertNotNil(Transcriber.activeSwapVeto(
            parakeet: "use the Fable credits in Codex",
            whisper: "use the favorable credits in codecs",
            durationSeconds: 8))
    }

    func testCleanShortSwapIsAllowed() {
        XCTAssertNil(Transcriber.activeSwapVeto(
            parakeet: "Okay climb up I will go to my lab at this fear",
            whisper: "Okay, so I'm in an airplane and I switched my input to AirPods",
            durationSeconds: 15))
    }
}
