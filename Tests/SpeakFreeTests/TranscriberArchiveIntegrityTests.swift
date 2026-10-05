// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
import XCTest
@testable import SpeakFreeLib

private final class ArchiveEngine: TranscriptionEngine {
    let engineID: String
    var text: String
    var error: Error?
    var lastDiagnostics: TranscriptionDiagnostics?
    var isLoaded = true
    var supportsStreaming = false
    var supportsPrompt = false
    var keepModelLoaded = "always"
    var calls = 0
    init(_ id: String = "parakeet", text: String) { engineID = id; self.text = text }
    func loadModel(modelID: String) async throws {}
    func unloadModel() async {}
    func startMemoryPressureMonitoring() {}
    func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String {
        calls += 1
        if let error { throw error }
        return text
    }
    func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                             onPartialResult: @escaping (String) -> Void) async throws -> String { text }
}

final class TranscriberArchiveIntegrityTests: XCTestCase {
    private var directory: URL!
    private var previousConfig: URL?
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/26-10-02-pinned-audio/transcriber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("models"), withIntermediateDirectories: true)
        previousConfig = Config.configDirOverride; Config.configDirOverride = directory
        // A Whisper model on disk. The injected CLI boundary below never loads it or runs a process.
        try Data().write(to: directory.appendingPathComponent("models/ggml-large-v3-turbo.bin"))
    }
    override func tearDownWithError() throws {
        Config.configDirOverride = previousConfig
        try? FileManager.default.removeItem(at: directory)
    }
    /// A tone that rises and falls at syllable rate. A perfectly steady tone has no speech
    /// envelope, so WhisperHallucinationGuard (2026-10-04) would rightly refuse Whisper text on it.
    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map {
            let t = Double($0) / 16_000
            return Float(0.14 * (0.55 + 0.45 * sin(2 * Double.pi * 3 * t)) * sin(2 * Double.pi * 150 * t))
        }
    }
    private var url: URL { directory.appendingPathComponent("take.wav") }
    private func transcriber(_ engine: ArchiveEngine) -> Transcriber {
        Transcriber(engine: engine, modelID: "test-model", language: "en")
    }
    func testInvalidArchiveKeepsMemoryEngineText() async throws {
        let engine = ArchiveEngine(text: "memory words remain available")
        let transcriber = transcriber(engine)
        var cliCalls = 0
        transcriber.cliTranscriptionOverride = { _ in cliCalls += 1; return "stale file words" }
        let text = try await transcriber.transcribe(audioURL: url, samples: tone(2), audioFileIsValid: false)
        XCTAssertEqual(text, engine.text)
        engine.text = ""
        var statuses: [Transcriber.TakeStatus] = []
        transcriber.onTakeStatus = { statuses.append($0) }
        let empty = try await transcriber.transcribe(audioURL: url, samples: tone(2), audioFileIsValid: false)
        XCTAssertEqual(empty, "")
        XCTAssertEqual(statuses, [.missed])
        XCTAssertEqual(cliCalls, 0)
    }
    func testInvalidArchiveBlocksWhisperEngineErrorFallbackAndNoSamplesCLI() async throws {
        let engine = ArchiveEngine("whisper", text: "unused")
        engine.error = TranscriptionEngineError.transcriptionFailed
        let transcriber = transcriber(engine)
        var cliCalls = 0
        transcriber.cliTranscriptionOverride = { _ in cliCalls += 1; return "stale file words" }
        for samples: [Float]? in [tone(1), nil] {
            do {
                _ = try await transcriber.transcribe(audioURL: url, samples: samples, audioFileIsValid: false)
                XCTFail("invalid WAV must not be a CLI input")
            } catch TranscriberError.audioArchiveUnavailable {} catch { XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(cliCalls, 0)
        _ = try await transcriber.transcribe(audioURL: url, samples: tone(1), audioFileIsValid: true)
        XCTAssertEqual(cliCalls, 1)
    }
    func testPersistedInvalidMarkerRejectsCanonicalDirectoryAndFileAliases() async throws {
        let writer = try WavWriter(url: url); try writer.append(tone(1)); try writer.finish()
        let fileAlias = directory.appendingPathComponent("other.wav")
        let directoryAlias = directory.appendingPathComponent("alias-directory")
        try FileManager.default.createSymbolicLink(at: fileAlias, withDestinationURL: url)
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
        try AudioArchiveIntegrity.markInvalid(url)
        AudioArchiveIntegrity.forget(url) // restart simulation: only the persisted marker remains.
        let engine = ArchiveEngine(text: "must never read the marked archive")
        let transcriber = transcriber(engine)
        var cliCalls = 0
        transcriber.cliTranscriptionOverride = { _ in cliCalls += 1; return "forbidden file words" }
        for path in [url, directoryAlias.appendingPathComponent(url.lastPathComponent), fileAlias] {
            XCTAssertTrue(AudioArchiveIntegrity.isInvalid(path), path.lastPathComponent)
            do {
                _ = try await transcriber.transcribeFile(url: path, progressHandler: { _, _, _ in }, isCancelled: { false })
                XCTFail("persisted marker must reject file inference through aliases")
            } catch TranscriberError.audioArchiveUnavailable {} catch { XCTFail("unexpected error: \(error)") }
            do {
                _ = try await transcriber.transcribe(audioURL: path, samples: tone(1))
                XCTFail("decoded stale samples must not bypass the persisted marker through aliases")
            } catch TranscriberError.audioArchiveUnavailable {} catch { XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(engine.calls, 0)
        XCTAssertEqual(cliCalls, 0)
    }

    func testPersistedInvalidMarkerRejectsFileTranscriptionBeforeEngineUse() async throws {
        try AudioArchiveIntegrity.markInvalid(url)
        AudioArchiveIntegrity.forget(url)
        let engine = ArchiveEngine(text: "memory remains usable")
        let transcriber = transcriber(engine)
        do {
            _ = try await transcriber.transcribeFile(url: url, progressHandler: { _, _, _ in }, isCancelled: { false })
            XCTFail("persisted invalid marker must reject file inference")
        } catch TranscriberError.audioArchiveUnavailable {} catch { XCTFail("unexpected error: \(error)") }
        do {
            _ = try await transcriber.transcribe(audioURL: url, samples: tone(1))
            XCTFail("default file-backed caller must not bypass marker with decoded stale samples")
        } catch TranscriberError.audioArchiveUnavailable {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(engine.calls, 0)
        let text = try await transcriber.transcribe(audioURL: url, samples: tone(1), audioFileIsValid: false)
        XCTAssertEqual(text, "memory remains usable")
        XCTAssertEqual(engine.calls, 1)
    }
}
