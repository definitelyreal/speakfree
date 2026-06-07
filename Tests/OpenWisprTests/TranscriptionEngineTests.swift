// Claude · 2026-06-07 · Session: 335a0545-b347-40c8-adbc-c0364e1a9aa4
import XCTest
@testable import OpenWisprLib

// MARK: - Test double

/// A fully in-memory TranscriptionEngine that returns canned text and records every call.
/// Lets us verify Transcriber delegation, the hallucination filter, and streaming gating
/// without loading a real model. Conforms to the FROZEN protocol (PLAN §1) exactly.
final class FakeEngine: TranscriptionEngine {
    // Configurable behavior
    var cannedTranscript: String
    var supportsStreamingFlag: Bool
    var transcribeError: Error?
    var loadError: Error?

    // Recorded state / calls
    private(set) var isLoaded: Bool = false
    private(set) var loadModelCalls: [String] = []
    private(set) var unloadCallCount = 0
    private(set) var memoryMonitorCallCount = 0
    private(set) var transcribeCalls: [(samples: [Float], language: String, prompt: String?, suppressRegex: String?)] = []
    private(set) var streamingCalls: [(samples: [Float], language: String)] = []

    let engineID: String
    var keepModelLoaded: String = "auto"

    var supportsStreaming: Bool { supportsStreamingFlag }

    init(engineID: String = "fake",
         cannedTranscript: String = "hello world",
         supportsStreaming: Bool = true) {
        self.engineID = engineID
        self.cannedTranscript = cannedTranscript
        self.supportsStreamingFlag = supportsStreaming
    }

    func loadModel(modelID: String) async throws {
        loadModelCalls.append(modelID)
        if let loadError { throw loadError }
        isLoaded = true
    }

    func unloadModel() async {
        unloadCallCount += 1
        isLoaded = false
    }

    func startMemoryPressureMonitoring() {
        memoryMonitorCallCount += 1
    }

    func transcribe(samples: [Float],
                    language: String,
                    prompt: String?,
                    suppressRegex: String?) async throws -> String {
        transcribeCalls.append((samples, language, prompt, suppressRegex))
        if let transcribeError { throw transcribeError }
        return cannedTranscript
    }

    func transcribeStreaming(samples: [Float],
                             language: String,
                             prompt: String?,
                             suppressRegex: String?,
                             onPartialResult: @escaping (String) -> Void) async throws -> String {
        streamingCalls.append((samples, language))
        if !supportsStreamingFlag {
            throw TranscriptionEngineError.streamingUnsupported
        }
        if let transcribeError { throw transcribeError }
        onPartialResult(cannedTranscript)
        return cannedTranscript
    }
}

// MARK: - EngineFactory selection

final class EngineFactoryTests: XCTestCase {

    private func makeConfig(engine: String?) -> Config {
        var c = Config.defaultConfig
        c.engine = engine
        return c
    }

    private func clearEnvOverride() {
        unsetenv("SPEAKFREE_ENGINE")
    }

    override func setUp() {
        super.setUp()
        clearEnvOverride()
    }

    override func tearDown() {
        clearEnvOverride()
        super.tearDown()
    }

    func testDefaultsToWhisperWhenEngineNil() {
        let engine = EngineFactory.make(config: makeConfig(engine: nil))
        XCTAssertEqual(engine.engineID, "whisper")
    }

    func testDefaultsToWhisperForUnknownEngine() {
        let engine = EngineFactory.make(config: makeConfig(engine: "bogus-engine"))
        XCTAssertEqual(engine.engineID, "whisper")
    }

    func testSelectsParakeetWhenConfigEngineIsParakeet() {
        let engine = EngineFactory.make(config: makeConfig(engine: "parakeet"))
        XCTAssertEqual(engine.engineID, "parakeet")
    }

    func testEnvOverrideSelectsParakeetEvenWhenConfigIsWhisper() {
        setenv("SPEAKFREE_ENGINE", "parakeet", 1)
        defer { clearEnvOverride() }
        let engine = EngineFactory.make(config: makeConfig(engine: "whisper"))
        XCTAssertEqual(engine.engineID, "parakeet")
    }

    func testEnvOverrideSelectsWhisperEvenWhenConfigIsParakeet() {
        setenv("SPEAKFREE_ENGINE", "whisper", 1)
        defer { clearEnvOverride() }
        let engine = EngineFactory.make(config: makeConfig(engine: "parakeet"))
        XCTAssertEqual(engine.engineID, "whisper")
    }

    func testFactoryReturnsUnloadedEngine() {
        let engine = EngineFactory.make(config: makeConfig(engine: "whisper"))
        XCTAssertFalse(engine.isLoaded, "EngineFactory must return an unloaded engine")
    }
}

// MARK: - Transcriber delegation

final class TranscriberDelegationTests: XCTestCase {

    private let dummyURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
    private let samples: [Float] = Array(repeating: 0.1, count: 16_000)

    func testDelegatesToInjectedEngine() async throws {
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "delegated text")
        let transcriber = Transcriber(engine: fake, modelID: "parakeet-tdt-0.6b-v3", language: "en")

        let result = try await transcriber.transcribe(audioURL: dummyURL, samples: samples, prompt: nil)

        XCTAssertEqual(result, "delegated text")
        XCTAssertEqual(fake.transcribeCalls.count, 1)
        XCTAssertEqual(fake.transcribeCalls.first?.language, "en")
    }

    func testLazyLoadsModelOnFirstTranscribe() async throws {
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "loaded")
        let transcriber = Transcriber(engine: fake, modelID: "parakeet-tdt-0.6b-v3", language: "en")

        XCTAssertFalse(fake.isLoaded)
        _ = try await transcriber.transcribe(audioURL: dummyURL, samples: samples, prompt: nil)

        XCTAssertTrue(fake.isLoaded)
        XCTAssertEqual(fake.loadModelCalls, ["parakeet-tdt-0.6b-v3"],
                       "Transcriber must lazy-load the injected engine with the configured modelID")
    }

    func testAppliesHallucinationFilterReturnsEmptyForKnownHallucination() async throws {
        // "Thank you." is in the hallucination set — Transcriber must filter it to "".
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "Thank you.")
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        let result = try await transcriber.transcribe(audioURL: dummyURL, samples: samples, prompt: nil)
        XCTAssertEqual(result, "", "Known hallucination must be filtered to empty string")
    }

    func testPassesRealTranscriptThroughHallucinationFilter() async throws {
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "the quick brown fox jumped")
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        let result = try await transcriber.transcribe(audioURL: dummyURL, samples: samples, prompt: nil)
        XCTAssertEqual(result, "the quick brown fox jumped")
    }

    func testStripsBulletAndArrowGlyphs() async throws {
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "buy → milk and ★ eggs today")
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        let result = try await transcriber.transcribe(audioURL: dummyURL, samples: samples, prompt: nil)
        XCTAssertFalse(result.contains("→"))
        XCTAssertFalse(result.contains("★"))
        XCTAssertTrue(result.contains("milk"))
    }

    func testNonWhisperEngineFailureRethrowsInsteadOfFallingBackToCLI() async {
        // Parakeet (non-whisper) engine failure must NOT silently fall back to the whisper CLI.
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "unused")
        fake.transcribeError = TranscriptionEngineError.transcriptionFailed
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        do {
            _ = try await transcriber.transcribe(audioURL: dummyURL, samples: samples, prompt: nil)
            XCTFail("Expected non-whisper engine failure to rethrow")
        } catch {
            // Expected — any thrown error is acceptable; the point is it did NOT fall back silently.
        }
    }

    // MARK: - Streaming gating

    func testStreamingDelegatesWhenSupported() async throws {
        let fake = FakeEngine(engineID: "whisper", cannedTranscript: "partial then final", supportsStreaming: true)
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        var partials: [String] = []
        let final = try await transcriber.transcribeStreaming(
            samples: samples,
            language: "en",
            prompt: nil,
            suppressRegex: nil,
            onPartialResult: { partials.append($0) }
        )

        XCTAssertEqual(final, "partial then final")
        XCTAssertEqual(fake.streamingCalls.count, 1)
        XCTAssertEqual(partials, ["partial then final"])
    }

    func testStreamingThrowsStreamingUnsupportedWhenEngineDoesNotSupportIt() async {
        let fake = FakeEngine(engineID: "parakeet", cannedTranscript: "unused", supportsStreaming: false)
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        do {
            _ = try await transcriber.transcribeStreaming(
                samples: samples,
                language: "en",
                prompt: nil,
                suppressRegex: nil,
                onPartialResult: { _ in }
            )
            XCTFail("Expected streamingUnsupported to be thrown")
        } catch let error as TranscriptionEngineError {
            switch error {
            case .streamingUnsupported:
                break  // expected
            default:
                XCTFail("Expected .streamingUnsupported, got \(error)")
            }
        } catch {
            XCTFail("Expected TranscriptionEngineError.streamingUnsupported, got \(error)")
        }
    }

    // MARK: - Lifecycle passthroughs

    func testLifecyclePassthroughsForwardToEngine() async {
        let fake = FakeEngine(engineID: "parakeet")
        let transcriber = Transcriber(engine: fake, modelID: "m", language: "en")

        XCTAssertEqual(transcriber.supportsStreaming, fake.supportsStreaming)
        XCTAssertEqual(transcriber.isLoaded, fake.isLoaded)

        transcriber.keepModelLoaded = "always"
        XCTAssertEqual(fake.keepModelLoaded, "always")
        XCTAssertEqual(transcriber.keepModelLoaded, "always")

        transcriber.startMemoryPressureMonitoring()
        XCTAssertEqual(fake.memoryMonitorCallCount, 1)

        await transcriber.unloadModel()
        XCTAssertEqual(fake.unloadCallCount, 1)
    }
}
