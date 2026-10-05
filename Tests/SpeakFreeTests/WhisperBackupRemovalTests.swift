// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-10-05
import XCTest
@testable import SpeakFreeLib

/// The Whisper backup behind Parakeet was removed on 2026-10-05 ("Kill the whisper backup").
/// Across 22,179 archived takes it typed text 16 times, 13 of them invented, and it added 2 to
/// 4 s per run. These pin that a Parakeet take never reaches Whisper, that config files written
/// while the backup existed still load, and that Whisper still works as a chosen engine.
final class WhisperBackupRemovalTests: XCTestCase {
    /// Counts engine calls and lets a test set the confidence a take reports.
    private final class CountingEngine: TranscriptionEngine {
        let engineID: String
        var text: String
        var error: Error?
        var calls = 0
        var lastDiagnostics: TranscriptionDiagnostics?
        var keepModelLoaded = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        var isLoaded = true
        init(_ engineID: String, text: String) { self.engineID = engineID; self.text = text }
        func loadModel(modelID: String) async throws {}
        func unloadModel() async {}
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String {
            calls += 1
            if let error { throw error }
            return text
        }
        func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                                 onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    private var root: URL!
    private var previousConfigDir: URL?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("whisper-backup-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        // The model the backup used to run, "on disk", so nothing but the removal can stop it.
        FileManager.default.createFile(atPath: root.appendingPathComponent("models/ggml-large-v3-turbo.bin").path,
                                       contents: Data())
        previousConfigDir = Config.configDirOverride
        Config.configDirOverride = root
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = previousConfigDir
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTake(_ samples: [Float], name: String) throws -> URL {
        let url = root.appendingPathComponent("recording-2026-10-05-\(name).wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        return url
    }

    private func sidecar(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("whisper.txt")
    }

    // MARK: - An empty Parakeet take never calls Whisper

    func testEmptyParakeetTakeNeverCallsWhisperAndSaysDidntCatchThat() async throws {
        let samples = SyntheticAudio.voice(seconds: 4, peak: 0.3)
        let evidence = Transcriber.audioEvidence(in: samples)
        XCTAssertTrue(evidence.hasSustainedSpeechEnergy && evidence.hasVoicedSpeech,
                      "the take must look like real speech, the shape the backup used to rescue")
        let url = try writeTake(samples, name: "empty")
        let engine = CountingEngine("parakeet", text: "")
        let transcriber = Transcriber(engine: engine, modelID: "parakeet-tdt-0.6b-v2", language: "en")
        var whisperCalls = 0
        transcriber.cliTranscriptionOverride = { _ in whisperCalls += 1; return "Thank you." }
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }

        let text = try await transcriber.transcribe(audioURL: url, samples: samples)

        XCTAssertEqual(text, "")
        XCTAssertEqual(whisperCalls, 0, "no Whisper run of any kind on a Parakeet take")
        XCTAssertEqual(statuses, [.missed])
        XCTAssertEqual(Transcriber.TakeStatus.missed.message, "Didn't catch that. Try again.")
        XCTAssertEqual(engine.calls, 1 + Transcriber.maxEmptyRetriesOnVoicedSpeech,
                       "Parakeet's own empty-result retries are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(url).path), "no .whisper.txt sidecar")
    }

    /// Soft speech: voiced (so Parakeet retries) but below the sustained-energy bar. An empty
    /// result still says "Didn't catch that." instead of disappearing silently.
    func testEmptyParakeetTakeOnSoftVoicedSpeechSaysDidntCatchThat() async throws {
        let candidates = stride(from: Float(0.02), through: 0.12, by: 0.005).map {
            SyntheticAudio.voice(seconds: 3, peak: $0)
        }
        let soft = try XCTUnwrap(candidates.first {
            let e = Transcriber.audioEvidence(in: $0)
            return e.hasVoicedSpeech && !e.hasSustainedSpeechEnergy
        }, "need a voiced take below the sustained-energy bar")
        XCTAssertFalse(CaptureStaticJudge.isStatic(samples: soft))
        let url = try writeTake(soft, name: "soft")
        let engine = CountingEngine("parakeet", text: "")
        let transcriber = Transcriber(engine: engine, modelID: "parakeet-tdt-0.6b-v2", language: "en")
        var whisperCalls = 0
        transcriber.cliTranscriptionOverride = { _ in whisperCalls += 1; return "words" }
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: soft)
        XCTAssertEqual(text, "")
        XCTAssertEqual(statuses, [.missed])
        XCTAssertEqual(whisperCalls, 0)
        XCTAssertEqual(engine.calls, 1 + Transcriber.maxEmptyRetriesOnVoicedSpeech)
    }

    /// The archive state no longer matters to an empty Parakeet take: there is no file-based
    /// backup to block, so a damaged archive reads as an ordinary miss.
    func testEmptyParakeetTakeWithUnusableArchiveIsAnOrdinaryMiss() async throws {
        let samples = SyntheticAudio.voice(seconds: 3, peak: 0.3)
        let url = try writeTake(samples, name: "invalid-archive")
        let transcriber = Transcriber(engine: CountingEngine("parakeet", text: ""),
                                      modelID: "parakeet-tdt-0.6b-v2", language: "en")
        var whisperCalls = 0
        transcriber.cliTranscriptionOverride = { _ in whisperCalls += 1; return "words" }
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples, audioFileIsValid: false)
        XCTAssertEqual(text, "")
        XCTAssertEqual(statuses, [.missed])
        XCTAssertEqual(whisperCalls, 0)
    }

    /// The old sparse-rescue shape (one word over seconds of speech) and the old shadow shape
    /// (low confidence) keep Parakeet's text, run nothing in the background, write no sidecar.
    func testSparseAndLowConfidenceTakesKeepParakeetTextWithNoBackgroundWhisper() async throws {
        let backgroundWhisper = expectation(description: "no Whisper run, now or in the background")
        backgroundWhisper.isInverted = true

        let sparseSamples = SyntheticAudio.voice(seconds: 10, peak: 0.3)
        let sparseURL = try writeTake(sparseSamples, name: "sparse")
        let sparseEngine = CountingEngine("parakeet", text: "Okay")
        let sparse = Transcriber(engine: sparseEngine, modelID: "parakeet-tdt-0.6b-v2", language: "en")
        sparse.cliTranscriptionOverride = { _ in backgroundWhisper.fulfill(); return "a much longer sentence here" }
        let sparseText = try await sparse.transcribe(audioURL: sparseURL, samples: sparseSamples)
        XCTAssertEqual(sparseText, "Okay")

        let shadowSamples = SyntheticAudio.voice(seconds: 3, peak: 0.3)
        let shadowURL = try writeTake(shadowSamples, name: "low-confidence")
        let shadowEngine = CountingEngine("parakeet", text: "These are several ordinary words")
        shadowEngine.lastDiagnostics = TranscriptionDiagnostics(aggregateConfidence: 0.8)
        let shadow = Transcriber(engine: shadowEngine, modelID: "parakeet-tdt-0.6b-v2", language: "en")
        shadow.cliTranscriptionOverride = { _ in backgroundWhisper.fulfill(); return "different words" }
        let shadowText = try await shadow.transcribe(audioURL: shadowURL, samples: shadowSamples)
        XCTAssertEqual(shadowText, "These are several ordinary words")

        await fulfillment(of: [backgroundWhisper], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(sparseURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(shadowURL).path))
        withExtendedLifetime((sparse, shadow)) {}
    }

    func testTakeStatusCopyHasNoDashes() {
        for status in [Transcriber.TakeStatus.missed, .staticNoise, .likelyHallucination] {
            XCTAssertFalse(status.message.contains("\u{2014}"), status.message)
            XCTAssertFalse(status.message.contains("\u{2013}"), status.message)
            XCTAssertTrue(status.message.hasPrefix("Didn't catch that."), status.message)
        }
    }

    // MARK: - Old configs load cleanly

    func testConfigWithRemovedBackupKeysLoadsCleanly() throws {
        // A real config as this build writes it, plus the two keys the backup used to store.
        var base = Config.defaultConfig
        base.engine = "parakeet"
        base.parakeetModel = "parakeet-tdt-0.6b-v2"
        base.keepModelLoaded = "always"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        object["whisperFallback"] = false
        object["whisperFallbackOfferDeclinedAt"] = 1_727_000_000.5
        let data = try JSONSerialization.data(withJSONObject: object)
        let file = root.appendingPathComponent("config.json")
        try data.write(to: file)

        let decoded = try Config.decode(from: data)
        XCTAssertEqual(decoded.engine, "parakeet")

        let loaded = Config.load()
        XCTAssertEqual(loaded.engine, "parakeet", "the file was read, not replaced by defaults")
        XCTAssertEqual(loaded.parakeetModel, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(loaded.keepModelLoaded, "always")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json.bak").path),
                       "a parse failure would have backed the file up")

        let (readOnly, exists) = Config.loadWithoutCreating()
        XCTAssertTrue(exists)
        XCTAssertEqual(readOnly.engine, "parakeet")

        // The next save drops the removed keys and keeps everything else.
        try loaded.save()
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("whisperFallback"), saved)
        XCTAssertEqual(Config.load().engine, "parakeet")
    }

    // MARK: - Whisper is still a chosen engine

    func testChoosingTheWhisperEngineStillWorks() async throws {
        // `speakfree set-engine whisper` and the Settings picker both store engine = "whisper".
        var config = Config.defaultConfig
        config.engine = "whisper"
        config.modelSize = "large-v3-turbo"
        try config.save()
        XCTAssertEqual(Config.load().engine, "whisper")
        XCTAssertTrue(EngineCatalog.engines.contains { $0.id == "whisper" }, "still offered in Settings")

        let previous = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"]
        unsetenv("SPEAKFREE_ENGINE")
        defer { if let previous { setenv("SPEAKFREE_ENGINE", previous, 1) } }
        XCTAssertEqual(EngineFactory.make(config: Config.load()).engineID, "whisper")

        // The Whisper engine's own text is typed.
        let samples = SyntheticAudio.voice(seconds: 3, peak: 0.3)
        let url = try writeTake(samples, name: "whisper-engine")
        let engine = CountingEngine("whisper", text: "Send the notes to Sam tonight.")
        let transcriber = Transcriber(engine: engine, modelID: "large-v3-turbo", language: "en")
        var cliCalls = 0
        transcriber.cliTranscriptionOverride = { _ in cliCalls += 1; return "Send the notes to Sam tonight." }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(text, "Send the notes to Sam tonight.")
        XCTAssertEqual(cliCalls, 0)

        // Whisper's own whisper-cli fallback (in-process engine failed) is part of the engine, not
        // the removed backup, and still runs.
        engine.error = TranscriptionEngineError.transcriptionFailed
        let fallback = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(fallback, "Send the notes to Sam tonight.")
        XCTAssertEqual(cliCalls, 1)

        // Empty Whisper output on speech stays silent (no "missed" line, as before the removal).
        engine.error = nil
        engine.text = ""
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let empty = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(empty, "")
        XCTAssertEqual(statuses, [])
    }
}
