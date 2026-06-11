// Claude · 2026-06-07 · Session: 335a0545-b347-40c8-adbc-c0364e1a9aa4
import XCTest
@testable import SpeakFreeLib

/// Pure-helper tests for the Parakeet engine path.
///
/// The arithmetic/mapping invariants below are the FROZEN contract from PLAN §2 (trailing-silence
/// pad math, model-name→version map, language-hint rules). They are asserted as self-contained spec
/// invariants so this test target compiles regardless of the exact internal symbol names Unit 4
/// (ParakeetEngine) and Unit 5 (ParakeetModelManager) choose for their private helpers. The
/// integrator should additionally point these at the real helper symbols once Units 4/5 land —
/// see notesForIntegrator.
///
/// Any test that needs the real ~600 MB CoreML model is gated behind
/// `ParakeetModelManager.shared.isModelDownloaded(...)` with XCTSkip, mirroring the
/// `Transcriber.modelExists` skip pattern in AudioGoldenTests. Tests NEVER download models.
final class ParakeetEngineTests: XCTestCase {

    // Contract constants (PLAN §2 / research/01 §4). 16 kHz mono Float32.
    private let trailingSilenceSamples = 16_000   // 1 s pad to capture final-word punctuation
    private let maxSingleChunkSamples = 240_000   // single-chunk encoder cap (15 s)

    private let defaultModel = "parakeet-tdt-0.6b-v3"
    private let v2Model = "parakeet-tdt-0.6b-v2"

    // MARK: - Trailing-silence pad math (count + 16000 <= 240000)

    /// The pad is appended only when it fits under the single-chunk cap.
    private func shouldPadTrailingSilence(count: Int) -> Bool {
        count + trailingSilenceSamples <= maxSingleChunkSamples
    }

    /// Resulting sample count after applying the trailing-silence pad rule.
    private func paddedCount(count: Int) -> Int {
        shouldPadTrailingSilence(count: count) ? count + trailingSilenceSamples : count
    }

    func testPadAppliedWellUnderCap() {
        let count = 16_000  // 1 s of speech
        XCTAssertTrue(shouldPadTrailingSilence(count: count))
        XCTAssertEqual(paddedCount(count: count), 32_000)
    }

    func testPadAppliedAtExactBoundary() {
        // count + 16000 == 240000 exactly → still padded (<= is inclusive).
        let count = maxSingleChunkSamples - trailingSilenceSamples  // 224_000
        XCTAssertTrue(shouldPadTrailingSilence(count: count))
        XCTAssertEqual(paddedCount(count: count), maxSingleChunkSamples)
    }

    func testPadSkippedJustOverBoundary() {
        // count + 16000 == 240001 → would exceed cap, so NOT padded.
        let count = maxSingleChunkSamples - trailingSilenceSamples + 1  // 224_001
        XCTAssertFalse(shouldPadTrailingSilence(count: count))
        XCTAssertEqual(paddedCount(count: count), count)
    }

    func testPadSkippedAtAndAboveCap() {
        XCTAssertFalse(shouldPadTrailingSilence(count: maxSingleChunkSamples))
        XCTAssertEqual(paddedCount(count: maxSingleChunkSamples), maxSingleChunkSamples)

        let big = maxSingleChunkSamples + 50_000
        XCTAssertFalse(shouldPadTrailingSilence(count: big))
        XCTAssertEqual(paddedCount(count: big), big)
    }

    func testPaddedCountNeverExceedsCap() {
        for count in stride(from: 0, through: 260_000, by: 8_000) {
            XCTAssertLessThanOrEqual(paddedCount(count: count), max(count, maxSingleChunkSamples),
                "padded count must not push a sub-cap clip over the cap (count=\(count))")
        }
    }

    // MARK: - Model-name → version map

    /// Mirrors PLAN §2: "parakeet-tdt-0.6b-v2"→v2, "-v3"→v3. Asserted via the version *string*
    /// so the test does not depend on importing FluidAudio's AsrModelVersion type.
    private func versionString(for modelName: String) -> String? {
        switch modelName {
        case v2Model: return "v2"
        case defaultModel: return "v3"
        default: return nil
        }
    }

    func testVersionMapV2() {
        XCTAssertEqual(versionString(for: v2Model), "v2")
    }

    func testVersionMapV3() {
        XCTAssertEqual(versionString(for: defaultModel), "v3")
    }

    func testVersionMapUnknownIsNil() {
        XCTAssertNil(versionString(for: "parakeet-tdt-0.6b-v9"))
        XCTAssertNil(versionString(for: "large-v3-turbo"))  // a whisper model id
    }

    func testDefaultParakeetModelIsV3() {
        // PLAN §0.7 + Config accessor convention: nil parakeetModel → "parakeet-tdt-0.6b-v3".
        let resolved = Config.defaultConfig.parakeetModel ?? defaultModel
        XCTAssertEqual(resolved, defaultModel)
        XCTAssertEqual(versionString(for: resolved), "v3")
    }

    // MARK: - Language-hint mapping (nil for auto/en/v2; value for v3)

    /// Returns true when a non-nil FluidAudio language hint SHOULD be produced.
    /// PLAN §2 / research/01 §5: only v3 + an explicit non-"auto" code yields a hint.
    private func producesLanguageHint(languageCode: String, modelName: String) -> Bool {
        guard versionString(for: modelName) == "v3" else { return false }
        guard languageCode != "auto" else { return false }
        return true
    }

    func testNoHintForAutoOnV3() {
        XCTAssertFalse(producesLanguageHint(languageCode: "auto", modelName: defaultModel))
    }

    func testNoHintForAnyLanguageOnV2() {
        // v2 is English-only; never emits a hint regardless of requested language.
        XCTAssertFalse(producesLanguageHint(languageCode: "en", modelName: v2Model))
        XCTAssertFalse(producesLanguageHint(languageCode: "fr", modelName: v2Model))
        XCTAssertFalse(producesLanguageHint(languageCode: "auto", modelName: v2Model))
    }

    func testHintForExplicitLanguageOnV3() {
        XCTAssertTrue(producesLanguageHint(languageCode: "en", modelName: defaultModel))
        XCTAssertTrue(producesLanguageHint(languageCode: "fr", modelName: defaultModel))
        XCTAssertTrue(producesLanguageHint(languageCode: "es", modelName: defaultModel))
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
}
