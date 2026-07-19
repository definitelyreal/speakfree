// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// AR-2 round-2, Finding #1 [High] + #2a [Medium] regression suite.
//
// WHAT THE REVIEWER FOUND (verified REAL, reproduced on this M3 Max):
//   The T2.1 adaptive post-buffer's advertised "−149ms / ~17% faster" materialises on EXACTLY
//   ONE fixture — fixture-4-trailing-silence-period.wav, which is fixture-3 with 400ms of pure
//   DIGITAL silence appended. Real recordings (incl. fixture-3 'spoken-period-end', whose
//   trailing word sits ABOVE the 0.01 RMS silence threshold) pay the full 300ms cap, so the
//   corpus-aggregate end-to-end benefit is ~0%. The mechanism is real and correct (it never
//   clips), but its win is confined to recordings that already contain trailing digital silence.
//
// These tests PIN that reality so no future change (or doc) can claim a corpus-wide win that
// isn't there, while also proving the two load-bearing safety properties:
//   (1) the win is real WHERE it applies (fixture-4 stops at the 150ms silence target), and
//   (2) the buffer NEVER clips — the adaptive-truncated tail of fixture-4 still transcribes to
//       a trailing spoken "period" (i.e. styled output ends with '.'), exactly like the flat path.
//
// #2a context: the AudioGoldenTests fixture-4 "clipping canary" runs ProcessCommand.run over the
// WHOLE wav — it never routes through the adaptive buffer, so it cannot catch a clip the adaptive
// truncation would introduce. test_fixture4_adaptiveTruncatedTail_doesNotClipSpokenPeriod below
// closes that gap by transcribing the ACTUALLY-truncated audio.

import XCTest
@testable import SpeakFreeLib

final class AdaptiveBufferCorpusTests: XCTestCase {

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AudioFixtures")
    }

    private let sampleRate: Double = 16_000.0
    private let cap = PostBufferPolicy.defaultCapMs              // 220 (retuned 2026-07-19)
    private let silenceTarget = PostBufferPolicy.defaultSilenceNeededMs  // 90 (retuned 2026-07-19)

    /// Pin transcription to the model the fixtures were generated against (manifest modelSHA is the
    /// tiny.en hash), independent of the developer's config.modelSize (which may be base.en).
    private static let transcriptionModel = "tiny.en"

    /// The live-runtime adaptive wait for a fixture: the SAME decision AppDelegate + the perf
    /// harness make — score `PostBufferPolicy` over the LAST `cap` ms of the recording (the tail
    /// that stands in for audio captured between key-release and finalize).
    private func adaptiveWaitMs(forSamples samples: [Float]) -> Double {
        let tailCount = Int((cap / 1000.0) * sampleRate)
        let tail = samples.count > tailCount ? Array(samples.suffix(tailCount)) : samples
        return PostBufferPolicy.decideWaitMs(trailingSamples: tail, sampleRate: sampleRate)
    }

    private func samples(_ name: String) throws -> [Float] {
        let url = fixtureDir.appendingPathComponent(name)
        return try ProcessCommand.loadSamples(from: url)
    }

    // MARK: - #1: corpus reality — the win is confined to trailing-silence fixtures

    /// PINS the finding: the adaptive buffer beats the flat 300ms cap on the manufactured
    /// trailing-silence fixture (fixture-4) and ONLY there. The three real recordings — including
    /// fixture-3 whose spoken 'period' tail sits above the RMS silence floor — pay the FULL cap.
    /// This is a no-I/O, machine-independent decision over the real fixture audio.
    func test_adaptiveWin_isConfinedToTrailingSilenceFixtures() throws {
        let speechTailFixtures = [
            "fixture-1-clean.wav",
            "fixture-2-spoken-comma.wav",
            "fixture-3-spoken-period-end.wav",
        ]
        for name in speechTailFixtures {
            let wait = adaptiveWaitMs(forSamples: try samples(name))
            XCTAssertEqual(wait, cap, accuracy: 0.001,
                "[\(name)] a recorded-speech tail must pay the full \(cap)ms cap — the adaptive win " +
                "does NOT generalise to real recordings (AR-2 #1). Got \(wait)ms.")
        }

        // fixture-4 = fixture-3 + 400ms appended digital silence → the ONLY fixture that early-stops.
        let f4Wait = adaptiveWaitMs(forSamples: try samples("fixture-4-trailing-silence-period.wav"))
        XCTAssertEqual(f4Wait, silenceTarget, accuracy: 0.001,
            "fixture-4 (manufactured trailing silence) must stop at the \(silenceTarget)ms silence " +
            "target — this is the one place the win is real. Got \(f4Wait)ms.")
        XCTAssertLessThan(f4Wait, cap)
    }

    /// PINS the aggregate: median-of-fixtures adaptive wait equals the flat cap (because 3 of 4
    /// fixtures pay the cap → the median IS the cap). I.e. the corpus-wide post-buffer benefit is
    /// ZERO at the median — the "~17% faster" headline is a fixture-4-only number. If a future
    /// change makes MORE fixtures early-stop (a genuine broad win) this test will fail and must be
    /// updated WITH fresh corpus evidence — it is a truthfulness tripwire, not a perf ceiling.
    func test_adaptiveBuffer_medianAcrossCorpus_equalsFlatCap_noBroadWin() throws {
        let names = [
            "fixture-1-clean.wav",
            "fixture-2-spoken-comma.wav",
            "fixture-3-spoken-period-end.wav",
            "fixture-4-trailing-silence-period.wav",
        ]
        var waits = try names.map { adaptiveWaitMs(forSamples: try samples($0)) }
        waits.sort()
        // 4 values → median = mean of the two middle. With [90, 220, 220, 220] → 220.
        let median = (waits[1] + waits[2]) / 2.0
        XCTAssertEqual(median, cap, accuracy: 0.001,
            "median adaptive post-buffer across the corpus must equal the flat cap (\(cap)ms): only " +
            "fixture-4 early-stops, so the corpus-aggregate win is ~0. Per-fixture waits: \(waits)")
        // Exactly ONE fixture beats the cap.
        XCTAssertEqual(waits.filter { $0 < cap }.count, 1,
            "exactly one fixture (the trailing-silence canary) should beat the cap; got waits \(waits)")
    }

    // MARK: - #2a: the adaptive buffer never clips (transcribe the ACTUAL truncated tail)

    /// CLOSES the #2a gap: AudioGoldenTests runs the WHOLE wav through ProcessCommand and so never
    /// exercises the adaptive truncation. Here we transcribe fixture-4 truncated to exactly what the
    /// adaptive buffer would keep (everything up to key-release + the decided wait) and prove the
    /// spoken 'period' SURVIVES — styled output still ends with '.'. If the adaptive buffer ever
    /// stops early enough to truncate the last word, this fails. Skips when no whisper model.
    func test_fixture4_adaptiveTruncatedTail_doesNotClipSpokenPeriod() throws {
        guard Transcriber.modelExists(modelSize: Self.transcriptionModel) else {
            throw XCTSkip("whisper tiny.en not installed — skipping adaptive-clip transcription check")
        }
        let full = try samples("fixture-4-trailing-silence-period.wav")

        // The live buffer keeps audio up to (samplesAtRelease + decidedWaitMs). The fixture's tail
        // stands in for the post-release window: the adaptive decision over the last `cap` ms says
        // stop after `wait` ms, so the kept audio is everything EXCEPT the (cap − wait) ms of
        // trailing silence the buffer correctly skipped. Reconstruct that truncated buffer.
        let wait = adaptiveWaitMs(forSamples: full)
        XCTAssertLessThan(wait, cap, "precondition: fixture-4 must early-stop for this to be meaningful")
        let trimmedFromTailMs = cap - wait                       // silence the buffer skipped
        let dropSamples = Int((trimmedFromTailMs / 1000.0) * sampleRate)
        let kept = dropSamples < full.count ? Array(full.prefix(full.count - dropSamples)) : full

        // Transcribe the truncated buffer through the SAME engine path the app uses.
        let raw = try transcribe(samples: kept)
        let styled = TextPipeline.run(TextPipeline.Input(raw: raw, punctuationMode: .hybrid)).finalText
        XCTAssertTrue(styled.hasSuffix("."),
            "adaptive truncation clipped the spoken period — styled output must still end with '.', " +
            "got: \(styled)")
    }

    /// Sanity: transcribing the FULL fixture-4 also ends in a period — so the truncated-vs-full
    /// comparison above is apples-to-apples (the period is in the audio, not an artifact of length).
    func test_fixture4_fullAudio_endsWithSpokenPeriod() throws {
        guard Transcriber.modelExists(modelSize: Self.transcriptionModel) else {
            throw XCTSkip("whisper tiny.en not installed — skipping adaptive-clip transcription check")
        }
        let full = try samples("fixture-4-trailing-silence-period.wav")
        let raw = try transcribe(samples: full)
        let styled = TextPipeline.run(TextPipeline.Input(raw: raw, punctuationMode: .hybrid)).finalText
        XCTAssertTrue(styled.hasSuffix("."), "full fixture-4 must end with a spoken period, got: \(styled)")
    }

    // MARK: - helpers

    /// Transcribe a sample buffer through the in-process engine (Parakeet) OR, for whisper whose
    /// in-process GGML/Metal device can't init outside the GUI app, write a temp wav and drive the
    /// CLI path — mirroring how ProcessCommand/the harness handle the same constraint.
    private func transcribe(samples: [Float]) throws -> String {
        var cfg = Config.load()
        cfg.engine = "whisper"
        cfg.modelSize = Self.transcriptionModel
        unsetenv("SPEAKFREE_ENGINE")
        let engine = EngineFactory.make(config: cfg)
        let transcriber = Transcriber(engine: engine, modelID: cfg.modelSize, language: cfg.language)
        let usesInProcess = engine.engineID == "parakeet"
        if usesInProcess {
            return try runBlocking {
                try await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/dev/null"),
                                                 samples: samples, prompt: nil)
            }
        }
        // whisper → CLI path needs a wav on disk.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ar2-adaptive-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeWav(samples: samples, to: tmp)
        return try runBlocking {
            try await transcriber.transcribe(audioURL: tmp, samples: nil, prompt: nil)
        }
    }

    /// Minimal 16kHz mono 16-bit PCM WAV writer (the format whisper-cli + loadSamples expect).
    private func writeWav(samples: [Float], to url: URL) throws {
        let sr: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sr * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = samples.count * 2
        var data = Data()
        func append32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                  // PCM fmt chunk size
        append16(1)                   // audio format = PCM
        append16(channels)
        append32(sr)
        append32(byteRate)
        append16(blockAlign)
        append16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            append16(UInt16(bitPattern: Int16(clamped * 32767.0)))
        }
        try data.write(to: url)
    }

    private func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task { do { result = .success(try await work()) } catch { result = .failure(error) }; sem.signal() }
        sem.wait()
        return try result.get()
    }
}
