// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
// Synthetic policy controls, not a measured distribution of real-world speech.
// Fixture tails deliberately exercise strong speech, soft speech and digital silence.
// These preserve deterministic policy coverage; historical wall-clock baselines are not comparable.

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

    // MARK: - Engineered strong, soft and silent tails

    func test_syntheticTailBands_preservePolicyDecisions() throws {
        // Generated tail bands: strong speech extends; soft speech uses the base cap.
        let expected: [(String, Double)] = [
            ("fixture-1-clean.wav", PostBufferPolicy.defaultExtendedCapMs),
            ("fixture-2-spoken-comma.wav", PostBufferPolicy.defaultExtendedCapMs),
            ("fixture-3-spoken-period-end.wav", cap),
        ]
        for (name, want) in expected {
            let wait = adaptiveWaitMs(forSamples: try samples(name))
            XCTAssertEqual(wait, want, accuracy: 0.001,
                "[\(name)] expected \(want)ms under the speech-extension bands (2026-07-25). " +
                "Got \(wait)ms.")
        }

        // fixture-4 = fixture-3 + 400ms appended digital silence → the ONLY fixture that early-stops.
        let f4Wait = adaptiveWaitMs(forSamples: try samples("fixture-4-trailing-silence-period.wav"))
        XCTAssertEqual(f4Wait, silenceTarget, accuracy: 0.001,
            "fixture-4 (manufactured trailing silence) must stop at the \(silenceTarget)ms silence " +
            "target — this is the one place the win is real. Got \(f4Wait)ms.")
        XCTAssertLessThan(f4Wait, cap)
    }

    /// This median describes only four deliberately constructed policy controls.
    func test_syntheticControls_haveExpectedMedian_notARealWorldEstimate() throws {
        let names = [
            "fixture-1-clean.wav",
            "fixture-2-spoken-comma.wav",
            "fixture-3-spoken-period-end.wav",
            "fixture-4-trailing-silence-period.wav",
        ]
        var waits = try names.map { adaptiveWaitMs(forSamples: try samples($0)) }
        waits.sort()
        // The constructed waits are [90, 220, 1200, 1200]; their median is 710 ms.
        let median = (waits[1] + waits[2]) / 2.0
        let expectedMedian = (cap + PostBufferPolicy.defaultExtendedCapMs) / 2.0
        XCTAssertEqual(median, expectedMedian, accuracy: 0.001,
            "median adaptive post-buffer across the synthetic controls must be \(expectedMedian)ms " +
            "(soft-tail base cap + speech-tail extended cap averaged). Per-fixture waits: \(waits)")
        // Exactly ONE fixture beats the base cap (the trailing-silence canary — the latency win).
        XCTAssertEqual(waits.filter { $0 < cap }.count, 1,
            "exactly one fixture (the trailing-silence canary) should beat the base cap; got waits \(waits)")
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
        let originalSpeech = try samples("fixture-3-spoken-period-end.wav")
        XCTAssertGreaterThanOrEqual(kept.count, originalSpeech.count)
        XCTAssertEqual(Array(kept.prefix(originalSpeech.count)), originalSpeech,
            "Adaptive truncation must preserve every synthetic speech sample")
        let raw = try transcribe(samples: kept)
        XCTAssertNotNil(raw.range(of: #"\bperiod\b"#,
            options: [.regularExpression, .caseInsensitive]), "Synthetic last word must survive")
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
        XCTAssertNotNil(raw.range(of: #"\bperiod\b"#,
            options: [.regularExpression, .caseInsensitive]))
        let styled = TextPipeline.run(TextPipeline.Input(raw: raw, punctuationMode: .hybrid)).finalText
        XCTAssertTrue(styled.hasSuffix("."), "full fixture-4 must end with a spoken period, got: \(styled)")
    }

    // MARK: - helpers

    /// Whisper's CLI consumes a temporary WAV; no microphone or live app is involved.
    private func transcribe(samples: [Float]) throws -> String {
        var cfg = Config.defaultConfig
        cfg.engine = "whisper"
        cfg.modelSize = Self.transcriptionModel
        cfg.spokenPunctuation = .hybrid
        let engine = WhisperEngine()
        let transcriber = Transcriber(engine: engine, modelID: cfg.modelSize, language: cfg.language)
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
