// Claude · 2026-07-15 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
//
// Round-1 adversarial-review fixes for the audio/engines surface (AU-*, EN-*). Each test below
// pins one behavioral fix and fails against the pre-fix code where a seam exists. Threading-only
// fixes (AU-B TOCTOU, AU-D queue hop, EN-B source queue) have no pure seam and are covered by code
// review, not tests — see the per-fix report.
import XCTest
@testable import SpeakFreeLib

final class AdversarialR1AudioEnginesTests: XCTestCase {

    // MARK: - EN-A: "subscribe" narrowed to phrase forms

    /// The bare "subscribe" substring used to drop ANY sentence containing the word. A real
    /// dictation must now survive; classic YouTube-outro hallucinations must still be filtered.
    func testEN_A_legitimateSubscribeSentenceSurvives() async throws {
        let engine = FakeEngine(cannedTranscript: "Please subscribe Alex to the release updates.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let result = try await transcriber.transcribe(
            audioURL: URL(fileURLWithPath: "/dev/null"), samples: [0.1, 0.2, 0.1])
        XCTAssertEqual(
            result, "Please subscribe Alex to the release updates.",
            "A legitimate imperative containing 'subscribe' must not be filtered")
    }

    func testEN_A_subscribePhraseHallucinationsStillFiltered() async throws {
        for phrase in ["Like and subscribe!", "Subscribe to my channel.", "Don't forget to subscribe."] {
            let engine = FakeEngine(cannedTranscript: phrase)
            let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
            let result = try await transcriber.transcribe(
                audioURL: URL(fileURLWithPath: "/dev/null"), samples: [0.1, 0.2, 0.1])
            XCTAssertEqual(result, "", "Hallucination phrase '\(phrase)' must be filtered to empty")
        }
    }

    // MARK: - EN-C: StreamingTextAssembler divergence resets instead of positional slicing

    func testEN_C_happyPathPrefixUnchanged() {
        var asm = StreamingTextAssembler()
        _ = asm.append("Hello world.")
        let display = asm.append("Hello world. Second one.")
        XCTAssertEqual(asm.committedStreamingText, "Hello world.\nSecond one.")
        XCTAssertEqual(display, "Hello world.\nSecond one.")
    }

    func testEN_C_divergenceResetsToFreshPartial() {
        var asm = StreamingTextAssembler()
        _ = asm.append("Hello world.")
        // whisper re-transcribed the audio: the committed prefix no longer matches. The overlay
        // must adopt the fresh partial wholesale, NOT positionally slice it into a garble
        // (pre-fix this produced "Hello world.\ns round.").
        let display = asm.append("Hey world is round.")
        XCTAssertEqual(asm.committedStreamingText, "Hey world is round.")
        XCTAssertEqual(display, "Hey world is round.")
        XCTAssertFalse(asm.committedStreamingText.contains("Hello"),
                       "Stale committed prefix must be discarded on divergence")
    }

    // MARK: - EN-D: trimSilence keeps a 3-window leading buffer

    /// A quiet lead followed by a loud tail: the leading safety buffer is now 3 windows (~300ms),
    /// so ≥4800 below-threshold lead samples survive the trim. The pre-fix 1-window buffer kept
    /// only ~2400, so this assertion fails against the old code.
    func testEN_D_quietLeadSurvivesThreeWindowBuffer() {
        let quiet = Float(0.0002)   // below the adaptive threshold → treated as silence
        let loud = Float(0.2)
        var samples = [Float](repeating: quiet, count: 8000)   // 0.5s quiet lead
        samples += [Float](repeating: loud, count: 16000)      // 1.0s loud tail

        let trimmed = WhisperEngine().trimSilence(samples)

        XCTAssertLessThan(trimmed.count, samples.count, "Some leading silence should be trimmed")
        XCTAssertGreaterThanOrEqual(trimmed.count, 4800, "At least the 3-window lead must remain")
        // The first 4800 retained samples must all be the quiet-lead value (3 windows preserved).
        for v in trimmed.prefix(4800) {
            XCTAssertEqual(v, quiet, accuracy: 1e-6,
                           "The 3-window leading buffer must preserve the quiet lead, not clip into it")
        }
    }

    // MARK: - EN-E: Parakeet vocab must be non-empty AND parseable

    func testEN_E_vocabValidity() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sf-vocab-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let vocab = dir.appendingPathComponent("parakeet_vocab.json")

        // Missing
        XCTAssertFalse(ParakeetModelManager.parakeetVocabIsValid(inDir: dir), "missing vocab → invalid")

        // Empty (0 bytes) — the interrupted-download case
        try Data().write(to: vocab)
        XCTAssertFalse(ParakeetModelManager.parakeetVocabIsValid(inDir: dir), "empty vocab → invalid")

        // Present but not JSON
        try Data("{ not json".utf8).write(to: vocab)
        XCTAssertFalse(ParakeetModelManager.parakeetVocabIsValid(inDir: dir), "unparseable vocab → invalid")

        // Valid JSON
        try Data("[\"a\", \"b\", \"c\"]".utf8).write(to: vocab)
        XCTAssertTrue(ParakeetModelManager.parakeetVocabIsValid(inDir: dir), "non-empty parseable vocab → valid")
    }

    // MARK: - EN-F: streaming SHA256 of a downloaded file

    func testEN_F_sha256HexMatchesKnownDigest() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("sf-sha-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }
        // Known SHA256("hello") with no trailing newline.
        XCTAssertEqual(
            try ParakeetDirectDownloader.sha256Hex(ofFileAt: file),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
