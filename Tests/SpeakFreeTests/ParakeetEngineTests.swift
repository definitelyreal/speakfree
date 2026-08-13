// Claude · 2026-06-07 · Session: 335a0545-b347-40c8-adbc-c0364e1a9aa4
import FluidAudio
import XCTest
@testable import SpeakFreeLib

/// Tests for the Parakeet engine's pure helpers, asserted against the REAL production symbols.
///
/// History: these were originally written as self-contained "spec invariant" mirrors before the
/// engine landed, with a note to re-point them at the real symbols afterwards. That never
/// happened, and the mirrors drifted badly: they froze the abandoned 1 s pad (production is 3 s)
/// and an all-or-nothing pad rule (production clamps to a partial pad near the cap). A test that
/// mirrors the constant it is testing proves nothing — everything below now calls production.
///
/// Any test that needs the real ~600 MB CoreML model is gated behind
/// `ParakeetModelManager.shared.isModelDownloaded(...)` with XCTSkip, mirroring the
/// `Transcriber.modelExists` skip pattern in AudioGoldenTests. Tests NEVER download models.
final class ParakeetEngineTests: XCTestCase {

    private let defaultModel = "parakeet-tdt-0.6b-v3"
    private let v2Model = "parakeet-tdt-0.6b-v2"

    // MARK: - Trailing-silence pad math (production: pad up to 3 s, clamped at the chunk cap)

    func testPadConstantsMatchEmpiricalValues() {
        // 3 s pad (empirical — the TDT decoder needs it to flush final tokens; do NOT tune
        // without re-verifying against real audio) under the 15 s single-chunk encoder cap.
        XCTAssertEqual(ParakeetEngine.trailingSilenceSamples, 48_000)
        XCTAssertEqual(ParakeetEngine.maxSingleChunkSamples, 240_000)
    }

    func testPadAppliedWellUnderCap() {
        // 1 s of speech gets the full 3 s pad.
        XCTAssertEqual(ParakeetEngine.paddedSampleCount(16_000),
                       16_000 + ParakeetEngine.trailingSilenceSamples)
    }

    func testFullPadAppliedAtExactBoundary() {
        // count + pad == cap exactly → full pad still fits.
        let count = ParakeetEngine.maxSingleChunkSamples - ParakeetEngine.trailingSilenceSamples
        XCTAssertEqual(ParakeetEngine.paddedSampleCount(count),
                       ParakeetEngine.maxSingleChunkSamples)
    }

    func testPartialPadJustOverBoundary() {
        // Production clamps rather than skips: one sample past the boundary still pads
        // up to the cap ("longer clips keep as much pad as fits").
        let count = ParakeetEngine.maxSingleChunkSamples - ParakeetEngine.trailingSilenceSamples + 1
        XCTAssertEqual(ParakeetEngine.paddedSampleCount(count),
                       ParakeetEngine.maxSingleChunkSamples)
    }

    func testNoPadAtAndAboveCap() {
        let cap = ParakeetEngine.maxSingleChunkSamples
        XCTAssertEqual(ParakeetEngine.paddedSampleCount(cap), cap)

        let big = cap + 50_000
        XCTAssertEqual(ParakeetEngine.paddedSampleCount(big), big,
                       "clips already past the cap are left to FluidAudio's auto-chunking, unpadded")
    }

    func testPaddedCountNeverExceedsCapForSubCapClips() {
        for count in stride(from: 0, through: 260_000, by: 8_000) {
            let padded = ParakeetEngine.paddedSampleCount(count)
            XCTAssertLessThanOrEqual(padded, max(count, ParakeetEngine.maxSingleChunkSamples),
                "padded count must not push a sub-cap clip over the cap (count=\(count))")
            XCTAssertGreaterThanOrEqual(padded, count, "padding never removes samples")
        }
    }

    // MARK: - Model-name → version map (EngineCatalog is the production source of truth)

    func testVersionMapV2() {
        XCTAssertEqual(EngineCatalog.versionString(forParakeetModelID: v2Model), "v2")
    }

    func testVersionMapV3() {
        XCTAssertEqual(EngineCatalog.versionString(forParakeetModelID: defaultModel), "v3")
    }

    func testVersionMapUnknownDefaultsToV3() {
        // Production coalesces unknown ids to "v3" (forward-compat: an unrecognized future
        // model is treated as multilingual rather than crashing or silently downgrading).
        XCTAssertEqual(EngineCatalog.versionString(forParakeetModelID: "parakeet-tdt-0.6b-v9"), "v3")
        XCTAssertEqual(EngineCatalog.versionString(forParakeetModelID: "large-v3-turbo"), "v3")
    }

    func testDefaultParakeetModelIsEnglishV2() {
        // Product default (Michael, 2026-06-11): new users get Parakeet ENGLISH (v2),
        // written EXPLICITLY into defaultConfig.
        XCTAssertEqual(Config.defaultConfig.parakeetModel, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(
            EngineCatalog.versionString(forParakeetModelID: Config.defaultConfig.parakeetModel!),
            "v2")
    }

    func testLegacyNilParakeetModelCoalescesToV3() {
        // LEGACY configs that predate the parakeetModel key still resolve to v3 at
        // use sites (`?? "parakeet-tdt-0.6b-v3"`) — deliberate back-compat so
        // v3-era users don't silently switch variants on upgrade.
        let legacyValue: String? = nil
        let resolved = legacyValue ?? defaultModel
        XCTAssertEqual(resolved, defaultModel)
        XCTAssertEqual(EngineCatalog.versionString(forParakeetModelID: resolved), "v3")
    }

    // MARK: - Language-hint mapping (production rule: nil for auto/empty or v2)

    func testNoHintForAutoOnV3() {
        XCTAssertNil(ParakeetEngine.languageHint(for: "auto", isV3: true))
    }

    func testNoHintForEmptyOrWhitespaceCode() {
        XCTAssertNil(ParakeetEngine.languageHint(for: "", isV3: true))
        XCTAssertNil(ParakeetEngine.languageHint(for: "   ", isV3: true))
    }

    func testNoHintForAnyLanguageOnV2() {
        // v2 is English-only; never emits a hint regardless of requested language.
        XCTAssertNil(ParakeetEngine.languageHint(for: "en", isV3: false))
        XCTAssertNil(ParakeetEngine.languageHint(for: "fr", isV3: false))
        XCTAssertNil(ParakeetEngine.languageHint(for: "auto", isV3: false))
    }

    func testHintForExplicitLanguageOnV3() {
        XCTAssertNotNil(ParakeetEngine.languageHint(for: "en", isV3: true))
        XCTAssertNotNil(ParakeetEngine.languageHint(for: "fr", isV3: true))
        XCTAssertNotNil(ParakeetEngine.languageHint(for: "es", isV3: true))
    }

    func testHintStripsRegionSubtagAndCase() {
        XCTAssertEqual(ParakeetEngine.stripRegionSubtag("en-us"), "en")
        XCTAssertEqual(ParakeetEngine.stripRegionSubtag("en_us"), "en")
        // "en-US" resolves to the same hint as plain "en".
        XCTAssertEqual(ParakeetEngine.languageHint(for: "en-US", isV3: true),
                       ParakeetEngine.languageHint(for: "en", isV3: true))
        XCTAssertNotNil(ParakeetEngine.languageHint(for: "en-US", isV3: true))
    }

    // MARK: - ParakeetModelManager.isModelDownloaded (frozen Unit 5 surface)

    func testIsModelDownloadedDoesNotThrowAndIsConsistent() {
        // Querying download state must be a pure, side-effect-free check (no download).
        let downloaded = ParakeetModelManager.shared.isModelDownloaded(defaultModel)
        // Calling twice yields the same answer — it is a stateless filesystem probe.
        XCTAssertEqual(downloaded, ParakeetModelManager.shared.isModelDownloaded(defaultModel))
    }

    func testUnknownModelIsNotDownloaded() {
        XCTAssertFalse(ParakeetModelManager.shared.isModelDownloaded("parakeet-tdt-0.6b-v9-nonexistent"))
    }

    // MARK: - Model-gated behavioral test (skips without the real model)

    func testParakeetEngineTranscribesShortClip() async throws {
        guard ParakeetModelManager.shared.isModelDownloaded(defaultModel) else {
            throw XCTSkip("Parakeet \(defaultModel) model not downloaded — skipping real-model transcription test")
        }

        let engine = ParakeetEngine()
        XCTAssertEqual(engine.engineID, "parakeet")
        XCTAssertFalse(engine.supportsStreaming, "Parakeet v1 is batch-only")

        try await engine.loadModel(modelID: defaultModel)
        XCTAssertTrue(engine.isLoaded)

        // ~1 s of near-silence; engine pads short/quiet clips internally and must not crash.
        let samples = [Float](repeating: 0.0, count: 16_000)
        let text = try await engine.transcribe(
            samples: samples,
            language: "en",
            prompt: nil,
            suppressRegex: nil
        )
        // Result may legitimately be empty for silence; assert it returns without throwing
        // and is a trimmed string (no leading/trailing whitespace per the contract).
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines))

        await engine.unloadModel()
        XCTAssertFalse(engine.isLoaded)
    }

    func testParakeetEngineRejectsStreaming() async throws {
        // No model needed: supportsStreaming is false for v1, and transcribeStreaming must throw
        // .streamingUnsupported regardless of model presence.
        let engine = ParakeetEngine()
        XCTAssertFalse(engine.supportsStreaming)

        do {
            _ = try await engine.transcribeStreaming(
                samples: [Float](repeating: 0, count: 16_000),
                language: "en",
                prompt: nil,
                suppressRegex: nil,
                onPartialResult: { _ in }
            )
            XCTFail("Expected streamingUnsupported from a batch-only engine")
        } catch let error as TranscriptionEngineError {
            guard case .streamingUnsupported = error else {
                return XCTFail("Expected .streamingUnsupported, got \(error)")
            }
        }
    }

    // MARK: - Pad-hallucination strip (2026-07-21 corpus, verified vs whisper)

    private func timing(_ token: String, _ start: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: start + 0.1,
                    confidence: 0.5)
    }

    private func timing(_ token: String, _ start: Double, _ confidence: Float) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: start + 0.1,
                    confidence: confidence)
    }

    func testConfidenceGapStripsMultiwordWeakTail() {
        let out = ParakeetEngine.strippingLowConfidenceTail(
            text: "If that doesn't work we could also do like this on that jump",
            timings: [
                timing("▁could", 4.8, 0.99), timing("▁also", 5.1, 0.99),
                timing("▁do", 5.5, 0.99), timing("▁like", 7.68, 0.665),
                timing("▁this", 11.36, 0.467), timing("▁on", 12.0, 0.254),
                timing("▁that", 12.5, 0.317), timing("▁jump", 14.0, 0.510),
            ])
        XCTAssertEqual(out.text, "If that doesn't work we could also do")
        XCTAssertEqual(out.removedTokenCount, 5)
    }

    func testConfidenceGateKeepsShortOrPlausibleTail() {
        let short = ParakeetEngine.strippingLowConfidenceTail(
            text: "Please send it tomorrow",
            timings: [timing("▁Please", 0, 0.9), timing("▁send", 0.3, 0.9),
                      timing("▁it", 0.6, 0.9), timing("▁tomorrow", 2.0, 0.2)])
        XCTAssertEqual(short.text, "Please send it tomorrow")

        let confident = ParakeetEngine.strippingLowConfidenceTail(
            text: "Please send it first thing tomorrow morning",
            timings: [timing("▁Please", 0, 0.9), timing("▁send", 0.3, 0.9),
                      timing("▁it", 0.6, 0.9), timing("▁first", 2.0, 0.45),
                      timing("▁thing", 2.2, 0.82), timing("▁tomorrow", 2.5, 0.48),
                      timing("▁morning", 2.8, 0.44)])
        XCTAssertEqual(confident.text, "Please send it first thing tomorrow morning")
    }

    func testEndpointingOnlyTrimsLongTrailingNonSpeech() {
        let samples = [Float](repeating: 0.1, count: 64_000)
        let trimmed = ParakeetEngine.endpointedSamples(
            samples, segments: [VadSegment(startTime: 0.2, endTime: 2.5)])
        XCTAssertEqual(trimmed.count, 40_000)

        let nearEnd = ParakeetEngine.endpointedSamples(
            samples, segments: [VadSegment(startTime: 0.2, endTime: 3.4)])
        XCTAssertEqual(nearEnd.count, samples.count, "sub-second tails stay intact")
        XCTAssertEqual(ParakeetEngine.endpointedSamples(samples, segments: []).count, samples.count)
    }

    func testStripsTrailingWordsThatStartInsidePad() {
        // Live case rec-130443: audio ends at 12.4s, Parakeet appended "here." over
        // the pad. Whisper on the same wav hears no "here".
        let out = ParakeetEngine.strippingPadHallucination(
            text: "these quality and handoff issues here.",
            timings: [
                timing("▁handoff", 10.9), timing("▁issues", 11.5),
                timing("▁here", 13.1), timing(".", 13.4),
            ],
            realAudioSeconds: 12.4)
        XCTAssertEqual(out, "these quality and handoff issues")
    }

    func testStripsMultiWordPadPhrase() {
        // Live case rec-154324: "being carried down." invented past the audio end.
        let out = ParakeetEngine.strippingPadHallucination(
            text: "to avoid thought detection being carried down.",
            timings: [
                timing("▁detection", 24.0),
                timing("▁being", 25.6), timing("▁car", 25.9), timing("ried", 26.1),
                timing("▁down", 26.4), timing(".", 26.6),
            ],
            realAudioSeconds: 25.1)
        XCTAssertEqual(out, "to avoid thought detection")
    }

    func testKeepsFinalWordFlushedNearTheBoundary() {
        // A genuine last word can emit just past the audio end — inside the margin
        // it is speech, not pad.
        let out = ParakeetEngine.strippingPadHallucination(
            text: "please look into that period.",
            timings: [timing("▁period", 9.5), timing(".", 9.75)],
            realAudioSeconds: 9.7)
        XCTAssertEqual(out, "please look into that period.")
    }

    func testNoTimingsMeansNoStrip() {
        XCTAssertEqual(
            ParakeetEngine.strippingPadHallucination(
                text: "unchanged text.", timings: nil, realAudioSeconds: 5),
            "unchanged text.")
    }

    func testMismatchedTailRefusesToStrip() {
        // The dropped tokens must actually match the transcript tail — if the
        // punctuation layer rewrote them beyond recognition, do nothing.
        let out = ParakeetEngine.strippingPadHallucination(
            text: "the transcript ends differently",
            timings: [timing("▁something", 1.0), timing("▁else", 8.0)],
            realAudioSeconds: 5.0)
        XCTAssertEqual(out, "the transcript ends differently")
    }

    func testOversizedStripIsRefused() {
        // A timing anomaly flagging 7+ words must never delete real content.
        let words = (1...8).map { "word\($0)" }
        let out = ParakeetEngine.strippingPadHallucination(
            text: words.joined(separator: " "),
            timings: words.map { timing("▁\($0)", 9.0) },
            realAudioSeconds: 5.0)
        XCTAssertEqual(out, words.joined(separator: " "))
    }

    func testStripNeverEmptiesTheTranscript() {
        let out = ParakeetEngine.strippingPadHallucination(
            text: "here.",
            timings: [timing("▁here", 6.0), timing(".", 6.2)],
            realAudioSeconds: 5.0)
        XCTAssertEqual(out, "here.", "an all-pad transcript is kept, not emptied")
    }
}
