// ai-suggestion:unverified · session:unknown · 2026-08-21
import XCTest
@testable import SpeakFreeLib

/// The whisper rescue/shadow thresholds and the comparison normalizer
/// (2026-08-20 confidence-fallback lane). The full rescue path needs live models;
/// these pin the pure decision pieces.
final class WhisperRescueTests: XCTestCase {
    typealias Status = Transcriber.SecondOpinionStatus

    /// Michael's copy rule (2026-08-22): two sentences, the first says what the audio
    /// contained, the second the action or outcome.
    func testSecondOpinionStatusMessages() {
        XCTAssertEqual(Status.rechecking(.garbled).message, "Garbled audio. Trying Whisper…")
        XCTAssertEqual(Status.rechecking(.silence).message, "Silence. Trying Whisper…")
        XCTAssertEqual(Status.failed(.garbled).message, "Garbled audio. Whisper found nothing.")
        XCTAssertEqual(Status.failed(.silence).message, "Silence. Nothing to transcribe.")
    }

    func testStatusCopyHasNoEmDashesAndOpensWithTheAudioSentence() {
        let all: [Status] = [.rechecking(.garbled), .rechecking(.silence),
                             .failed(.garbled), .failed(.silence)]
        for status in all {
            XCTAssertFalse(status.message.contains("—"), "no em-dashes in UI copy: \(status.message)")
            XCTAssertFalse(status.message.contains("–"), "no en-dashes either: \(status.message)")
            let sentences = status.message.split(separator: ".", omittingEmptySubsequences: true)
            XCTAssertGreaterThanOrEqual(sentences.count, 2, "two-part voice: \(status.message)")
        }
        XCTAssertTrue(Status.rechecking(.garbled).message.hasPrefix(Status.AudioDescriptor.garbled.sentence))
        XCTAssertTrue(Status.failed(.silence).message.hasPrefix(Status.AudioDescriptor.silence.sentence))
    }

    /// `RecordingOverlay.updateStreamingText` only ever GROWS the text (shorter
    /// updates are dropped as stale re-processing). The failure line replaces the
    /// "trying" line through that same path, so for each descriptor it must be at
    /// least as long, or the failure would never show.
    func testFailureLineIsNeverShorterThanTheTryingLine() {
        for audio in [Status.AudioDescriptor.garbled, .silence] {
            XCTAssertGreaterThanOrEqual(
                Status.failed(audio).message.count, Status.rechecking(audio).message.count,
                "failure copy for \(audio) would be dropped by the grow-only rule")
        }
    }

    /// Descriptor selection from the take's evidence: any sustained or voiced speech
    /// energy is "garbled" (the model had something to work with); otherwise the take
    /// reads as silence. Pure, so the copy decision is pinned without a rescue run.
    func testAudioDescriptorFollowsTheEvidence() {
        func evidence(peak: Float, windows: Int, voiced: Bool) -> Transcriber.AudioEvidence {
            Transcriber.AudioEvidence(durationSeconds: 4, peakWindowRMS: peak,
                                      speechWindowCount: windows, noiseFloorRMS: 0.002,
                                      hasVoicedSpeech: voiced)
        }
        // Sustained energy (peak >= 0.04 across >= 3 windows): garbled.
        XCTAssertEqual(Transcriber.audioDescriptor(for: evidence(peak: 0.08, windows: 12, voiced: false)), .garbled)
        // Below the sustained bar but a voiced pitch was found: still garbled.
        XCTAssertEqual(Transcriber.audioDescriptor(for: evidence(peak: 0.02, windows: 1, voiced: true)), .garbled)
        // Dead quiet: silence.
        XCTAssertEqual(Transcriber.audioDescriptor(for: evidence(peak: 0.001, windows: 0, voiced: false)), .silence)
        // A lone unvoiced burst (one energetic window, no pitch) is a click, not speech.
        XCTAssertEqual(Transcriber.audioDescriptor(for: evidence(peak: 0.09, windows: 1, voiced: false)), .silence)
    }

    func testTranscribingStatusExpandsSpinnerPill() {
        let idleSize = OverlayContentView.pillSize(for: .transcribing)
        let statusSize = OverlayContentView.pillSize(
            for: .transcribing,
            streamingText: Status.rechecking(.garbled).message)
        XCTAssertGreaterThan(statusSize.width, idleSize.width)
        XCTAssertGreaterThanOrEqual(statusSize.height, idleSize.height)
    }

    /// The text centres because the pill reserves the SAME room on both sides of it
    /// (spinner + gap on the left, mirrored on the right), and the status card is
    /// tall enough to give the cymatics grains a band above and below the line.
    func testStatusPillReservesSymmetricSideRoomAndGrainBands() {
        let message = Status.rechecking(.garbled).message
        let textWidth = ceil((message as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        ]).width)
        let size = OverlayContentView.pillSize(for: .transcribing, streamingText: message)
        XCTAssertEqual(size.width, textWidth + OverlayContentView.statusSidePad * 2, accuracy: 0.5)
        XCTAssertEqual(size.height, OverlayContentView.statusHeight, accuracy: 1e-9)
        XCTAssertGreaterThan(OverlayContentView.statusHeight, 48, "room for grains above/below a 13pt line")
    }

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
        // The dropped-sentence shape: 14.7s of audio that is ALL speech, 6 words out.
        XCTAssertTrue(Transcriber.sparseRescueEligible(
            parakeetWordCount: 6, durationSeconds: 14.7, speechDurationSeconds: 14.7))
        // Normal speech density is never "sparse".
        XCTAssertFalse(Transcriber.sparseRescueEligible(
            parakeetWordCount: 30, durationSeconds: 15, speechDurationSeconds: 15))
        // Short takes are excluded — 2 words in 3s is a normal quick command.
        XCTAssertFalse(Transcriber.sparseRescueEligible(
            parakeetWordCount: 2, durationSeconds: 3, speechDurationSeconds: 3))
        // Regression (rec-2026-08-21-172840): 6 words in a 19s take that carried only
        // 2.5s of actual speech (16.5s silence, 0.98 conf). Density against speech is
        // 2.4 words/s — a clean short utterance, NOT a dropped sentence. Must not rescue.
        XCTAssertFalse(Transcriber.sparseRescueEligible(
            parakeetWordCount: 6, durationSeconds: 19, speechDurationSeconds: 2.49))
        // A near-empty take (0 Parakeet words) stays eligible regardless of speech length,
        // so the empty-recovery catches (both historical accepts were 0-word) are preserved.
        XCTAssertTrue(Transcriber.sparseRescueEligible(
            parakeetWordCount: 0, durationSeconds: 12, speechDurationSeconds: 1.0))
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
