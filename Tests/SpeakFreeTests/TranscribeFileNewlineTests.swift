// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// AR-1 round 2 — file-transcription newline structure (High finding).
//
// transcribeFile (the v1.5.0 file-transcription feature) writes a DOCUMENT
// (.txt/.md via FileTranscriptionController.writeOutput), NOT a live-dictation insertion.
// The Newline-policy-2b/Option-B space-join exists ONLY to keep Whisper multi-segment "\n"
// out of the TextInserter (live dictation). On the file path, segment + chunk breaks are
// document STRUCTURE and must survive — otherwise a multi-minute transcription collapses
// into one unbroken wall-of-text line.
//
// These tests pin:
//   (1) per-chunk multi-segment "\n" output reaches the saved transcript as newlines;
//   (2) multiple 5-minute chunks are joined with newlines (structural breaks), not spaces.
//
// The companion invariant — that the DICTATION path (Transcriber.transcribe →
// TextInserter) still space-joins multi-segment output — is pinned in
// PipelineIntegrationTests (test_newline2b_*) and is NOT regressed here.

import AVFoundation
import XCTest
@testable import SpeakFreeLib

final class TranscribeFileNewlineTests: XCTestCase {

    // MARK: - Test engine

    /// A non-whisper engine (so transcribeFile takes the chunk-and-delegate path) that returns
    /// scripted text. If `perCallTexts` is supplied it returns a distinct value per call (so the
    /// overlap-dedup heuristic can't collapse multiple chunks); otherwise it returns `canned`.
    private final class ScriptedFileEngine: TranscriptionEngine {
        let engineID: String = "parakeet"
        var keepModelLoaded: String = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        private(set) var isLoaded: Bool = false

        private let canned: String
        private let perCallTexts: [String]?
        private var callIndex = 0

        init(canned: String = "", perCallTexts: [String]? = nil) {
            self.canned = canned
            self.perCallTexts = perCallTexts
        }

        func loadModel(modelID: String) async throws { isLoaded = true }
        func unloadModel() async { isLoaded = false }
        func startMemoryPressureMonitoring() {}

        func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String {
            defer { callIndex += 1 }
            if let texts = perCallTexts {
                return texts[min(callIndex, texts.count - 1)]
            }
            return canned
        }

        func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?, onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    // MARK: - WAV synthesis helper

    /// Write a mono 16-bit PCM WAV of `seconds` at `sampleRate` to a unique temp URL.
    /// Non-silent (low-amplitude tone) so loadSamplesChunk doesn't drop it as empty.
    private func writeWAV(seconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribefile-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate, channels: 1, interleaved: false)!
        // Write as 16-bit PCM on disk; AVAudioFile converts from our float buffer.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameTotal = AVAudioFrameCount(seconds * sampleRate)
        // Write in blocks to keep buffers reasonable.
        let block: AVAudioFrameCount = 16_000
        var written: AVAudioFrameCount = 0
        var phase: Float = 0
        let inc: Float = 2 * .pi * 220 / Float(sampleRate)
        while written < frameTotal {
            let n = min(block, frameTotal - written)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            buf.frameLength = n
            let ch = buf.floatChannelData![0]
            for i in 0..<Int(n) {
                ch[i] = 0.05 * sin(phase)
                phase += inc
            }
            try file.write(from: buf)
            written += n
        }
        return url
    }

    private func makeTranscriber(_ engine: TranscriptionEngine) -> Transcriber {
        Transcriber(engine: engine, modelID: "parakeet-tdt-0.6b-v3", language: "en")
    }

    // MARK: - (1) per-chunk multi-segment newlines survive into the document

    /// A single-chunk file whose engine emits multi-segment "\n" output (the shape Whisper
    /// produces) must keep those segment breaks as newlines in the file-transcription result.
    /// Pre-fix this was space-joined, collapsing the saved document's structure.
    func test_transcribeFile_perChunkSegmentNewlines_survive() async throws {
        let engine = ScriptedFileEngine(canned: "First sentence.\nSecond sentence.\nThird sentence.")
        let transcriber = makeTranscriber(engine)
        let url = try writeWAV(seconds: 1.0, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = try await transcriber.transcribeFile(url: url, progressHandler: { _, _, _ in }, isCancelled: { false })

        XCTAssertTrue(out.contains("\n"),
                      "file-transcription output must preserve segment newlines as document structure; got: \(out.debugDescription)")
        XCTAssertEqual(out, "First sentence.\nSecond sentence.\nThird sentence.",
                       "each Whisper-style segment becomes its own line in the saved document")
    }

    // MARK: - (2) multiple 5-minute chunks join with newlines, not a space

    /// A file longer than one 5-minute window produces multiple chunks. They must be joined
    /// with a newline (a visible structural break in the saved file), NOT a space that would
    /// collapse a long lecture/meeting transcript into one unbroken line.
    ///
    /// Low sample rate keeps the synthesized WAV small while still exceeding chunkFrames
    /// (= sampleRate * 5 * 60), forcing >1 chunk.
    func test_transcribeFile_multipleChunks_joinWithNewline() async throws {
        let sampleRate: Double = 4_000      // chunkFrames = 4000 * 300 = 1.2M frames per 5-min window
        // 11 minutes > 2 chunks (5-min window, 10-s overlap step).
        let url = try writeWAV(seconds: 11 * 60, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }

        // Distinct text per chunk so the overlap-dedup heuristic can't merge them away.
        let engine = ScriptedFileEngine(perCallTexts: [
            "Chunk Alpha content here.",
            "Chunk Bravo content here.",
            "Chunk Charlie content here.",
            "Chunk Delta content here.",
        ])
        let transcriber = makeTranscriber(engine)

        var sawMultipleChunks = false
        let out = try await transcriber.transcribeFile(
            url: url,
            progressHandler: { _, total, _ in if total > 1 { sawMultipleChunks = true } },
            isCancelled: { false }
        )

        XCTAssertTrue(sawMultipleChunks, "test setup must produce >1 chunk")
        XCTAssertTrue(out.contains("\n"),
                      "multiple 5-minute chunks must be newline-joined (structural breaks), not space-joined; got: \(out.debugDescription)")
        XCTAssertTrue(out.contains("Chunk Alpha") && out.contains("Chunk Bravo"),
                      "distinct chunk contents must all appear in the saved document; got: \(out.debugDescription)")
        // The Alpha→Bravo boundary specifically must be a newline, never a bare space.
        XCTAssertFalse(out.contains("Chunk Alpha content here. Chunk Bravo"),
                       "chunk boundary must not collapse to a single space-joined line")
    }
}
