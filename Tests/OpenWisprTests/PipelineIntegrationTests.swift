// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T0.4 — Pipeline integration harness. Drives the record → transcribe → insert core
// (FinalizePipeline, extracted from AppDelegate.finalizeRecording) with a scripted
// FakeScriptedEngine + a MockInserter seam — no real inference, no AX, no clipboard.
//
// Also covers the streaming-overlay assembly (StreamingTextAssembler, extracted from
// AppDelegate.buildStableDisplayText) with multi-partial cases.

import ApplicationServices
import XCTest
@testable import OpenWisprLib

// MARK: - Test doubles

/// Scripted engine: returns canned transcription text (or throws a scripted error) with
/// zero real inference. Conforms to the same `TranscriptionEngine` protocol the app's
/// WhisperEngine / ParakeetEngine conform to, so it slots into a real `Transcriber`.
final class FakeScriptedEngine: TranscriptionEngine {
    var engineID: String
    var isLoaded: Bool = true
    var supportsStreaming: Bool
    var keepModelLoaded: String = "auto"

    /// Final-pass result. If `error` is set, `transcribe` throws it instead.
    var scriptedFinal: String
    var error: Error?
    /// Ordered partials emitted via `onPartialResult` before `transcribeStreaming` returns.
    var scriptedPartials: [String] = []

    private(set) var transcribeCallCount = 0
    private(set) var lastSamples: [Float] = []
    private(set) var lastPrompt: String?

    init(engineID: String = "whisper",
         supportsStreaming: Bool = true,
         scriptedFinal: String = "",
         error: Error? = nil) {
        self.engineID = engineID
        self.supportsStreaming = supportsStreaming
        self.scriptedFinal = scriptedFinal
        self.error = error
    }

    func loadModel(modelID: String) async throws { isLoaded = true }
    func unloadModel() async { isLoaded = false }
    func startMemoryPressureMonitoring() {}

    func transcribe(samples: [Float],
                    language: String,
                    prompt: String?,
                    suppressRegex: String?) async throws -> String {
        transcribeCallCount += 1
        lastSamples = samples
        lastPrompt = prompt
        if let error = error { throw error }
        return scriptedFinal
    }

    func transcribeStreaming(samples: [Float],
                             language: String,
                             prompt: String?,
                             suppressRegex: String?,
                             onPartialResult: @escaping (String) -> Void) async throws -> String {
        if let error = error { throw error }
        for p in scriptedPartials { onPartialResult(p) }
        return scriptedPartials.last ?? scriptedFinal
    }
}

/// Records what *would* be inserted instead of touching AX / clipboard / CGEvents.
final class MockInserter: TextInserting {
    /// Controls the `shouldPrependSpace` decision (the cursor-context check we can't do headless).
    var prependSpace: Bool = false
    /// Controls the return value of `insert` (true = pasted, false = focus lost).
    var insertReturns: Bool = true

    private(set) var prependQueried = false
    private(set) var insertedTexts: [String] = []
    private(set) var insertCallCount = 0
    /// Set when `insert` is invoked with onFocusLost and `insertReturns == false`.
    private(set) var focusLostFired = false

    func shouldPrependSpace(before element: AXUIElement?) -> Bool {
        prependQueried = true
        return prependSpace
    }

    @discardableResult
    func insert(text: String, refocusing element: AXUIElement?, onFocusLost: (() -> Void)?) -> Bool {
        insertCallCount += 1
        insertedTexts.append(text)
        if !insertReturns {
            focusLostFired = true
            onFocusLost?()
        }
        return insertReturns
    }
}

// MARK: - Tests

final class PipelineIntegrationTests: XCTestCase {

    private let audioURL = URL(fileURLWithPath: "/tmp/speakfree-test.wav")

    /// Build the same `makeInput` closure shape `finalizeRecording` builds.
    private func makeInputClosure(
        punctuation: PunctuationMode = .hybrid,
        style: TextPostProcessor.StyleMode = .none,
        glossary: String? = nil,
        cursorContext: String? = nil,
        screenContext: String? = nil
    ) -> (String) -> TextPipeline.Input {
        return { raw in
            TextPipeline.Input(
                raw: raw,
                cursorContextText: cursorContext,
                screenContextText: screenContext,
                punctuationMode: punctuation,
                styleMode: style,
                glossaryWords: glossary
            )
        }
    }

    /// Loud (non-silent) samples above the too-short threshold.
    private func loudSamples(count: Int = FinalizePipeline.minSamples + 16000) -> [Float] {
        return (0..<count).map { _ in 0.2 }
    }

    /// Drive the finalize core through a real `Transcriber` wrapping a FakeScriptedEngine — i.e. the
    /// transcription seam is the production Transcriber, not a stub closure.
    private func runViaTranscriber(
        samples: [Float],
        engine: FakeScriptedEngine,
        inserter: MockInserter,
        makeInput: @escaping (String) -> TextPipeline.Input
    ) async -> FinalizePipeline.Outcome {
        let transcriber = Transcriber(engine: engine, modelID: "tiny.en", language: "en")
        return await FinalizePipeline.run(
            samples: samples,
            audioURL: audioURL,
            makeInput: makeInput,
            transcribe: { url, samples, prompt in
                try await transcriber.transcribe(audioURL: url, samples: samples, prompt: prompt)
            },
            inserter: inserter,
            element: nil
        )
    }

    // MARK: finalizeRecording happy path

    func test_happyPath_textReachesInserterThroughTextPipeline() async {
        // FakeScriptedEngine returns scripted text; it must flow through TextPipeline (post-processing,
        // style) and land in the MockInserter verbatim.
        let engine = FakeScriptedEngine(scriptedFinal: "hello world period")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .spoken)
        )
        // Spoken "period" → ".". This proves the text traversed the full TextPipeline
        // (TextPostProcessor converted the spoken word), not the raw engine string.
        guard case let .inserted(insertedText, pasted) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "hello world.")
        XCTAssertTrue(pasted)
        XCTAssertEqual(inserter.insertedTexts, ["hello world."])
        XCTAssertEqual(engine.transcribeCallCount, 1)
    }

    func test_happyPath_prependsSpaceWhenInserterRequests() async {
        // When shouldPrependSpace returns true, the inserted text gets a leading space.
        let engine = FakeScriptedEngine(scriptedFinal: "world")
        let inserter = MockInserter()
        inserter.prependSpace = true
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertEqual(insertedText, " world")
        XCTAssertTrue(inserter.prependQueried)
        XCTAssertEqual(inserter.insertedTexts, [" world"])
    }

    func test_happyPath_focusLostReportsNotPasted() async {
        // When the inserter can't restore focus, insert returns false and onFocusLost fires.
        let engine = FakeScriptedEngine(scriptedFinal: "saved to clipboard")
        let inserter = MockInserter()
        inserter.insertReturns = false
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .inserted(_, pasted) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertFalse(pasted)
        XCTAssertTrue(inserter.focusLostFired)
    }

    func test_happyPath_promptHintsBuiltBeforeTranscription() async {
        // The prompt-hints (built from makeInput("")) must reach the engine — proves the
        // assemble-prompt-then-transcribe ordering from finalizeRecording is preserved.
        let engine = FakeScriptedEngine(scriptedFinal: "hi")
        let inserter = MockInserter()
        _ = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            // spoken punctuation produces a non-nil prompt-hints instruction line
            makeInput: makeInputClosure(punctuation: .spoken, glossary: "Kubernetes, speakfree")
        )
        XCTAssertNotNil(engine.lastPrompt)
        XCTAssertTrue(engine.lastPrompt?.contains("Glossary") ?? false,
                      "prompt should carry glossary hints; got \(String(describing: engine.lastPrompt))")
    }

    // MARK: error path (engine throws)

    func test_errorPath_engineThrows_genericFailure() async {
        // Use a non-whisper engine id so the throw rethrows cleanly (whisper would attempt a
        // real CLI fallback, which isn't what this path is asserting).
        let engine = FakeScriptedEngine(engineID: "parakeet", supportsStreaming: false,
                                        error: TranscriptionEngineError.transcriptionFailed)
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure()
        )
        XCTAssertEqual(outcome, .failed(modelMissing: false))
        XCTAssertEqual(inserter.insertCallCount, 0, "nothing should be inserted on failure")
    }

    func test_errorPath_modelAssetsMissing_flagsModelMissing() async {
        // A non-whisper engine that throws modelAssetsMissing rethrows (no CLI fallback),
        // and the pipeline must flag modelMissing so the app shows the download alert.
        let engine = FakeScriptedEngine(engineID: "parakeet", supportsStreaming: false,
                                error: TranscriptionEngineError.modelAssetsMissing("parakeet-v2"))
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure()
        )
        XCTAssertEqual(outcome, .failed(modelMissing: true))
        XCTAssertEqual(inserter.insertCallCount, 0)
    }

    // MARK: too-short recording path

    func test_tooShort_skipsBeforeTranscription() async {
        let engine = FakeScriptedEngine(scriptedFinal: "should never run")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: Array(repeating: 0.2, count: FinalizePipeline.minSamples - 1),
            engine: engine, inserter: inserter, makeInput: makeInputClosure()
        )
        XCTAssertEqual(outcome, .tooShort(sampleCount: FinalizePipeline.minSamples - 1))
        XCTAssertEqual(engine.transcribeCallCount, 0, "must not transcribe a too-short tap")
        XCTAssertEqual(inserter.insertCallCount, 0)
    }

    func test_tooShort_boundaryExactlyMinSamplesProceeds() async {
        // Exactly minSamples is NOT too short (guard is `< minSamples`). Use a phrase that
        // survives the hallucination filter (short filler words like "ok" are filtered).
        let engine = FakeScriptedEngine(scriptedFinal: "this is fine")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: Array(repeating: 0.2, count: FinalizePipeline.minSamples),
            engine: engine, inserter: inserter, makeInput: makeInputClosure(punctuation: .off)
        )
        guard case .inserted = outcome else { return XCTFail("expected .inserted at boundary, got \(outcome)") }
        XCTAssertEqual(engine.transcribeCallCount, 1)
    }

    // MARK: silent / empty-transcription paths

    func test_silent_deadAudioSkipsTranscription() async {
        // All-zero samples above the length threshold → RMS below silence threshold → skipped.
        let engine = FakeScriptedEngine(scriptedFinal: "should never run")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: Array(repeating: Float(0), count: FinalizePipeline.minSamples + 16000),
            engine: engine, inserter: inserter, makeInput: makeInputClosure()
        )
        guard case .silent = outcome else { return XCTFail("expected .silent, got \(outcome)") }
        XCTAssertEqual(engine.transcribeCallCount, 0)
        XCTAssertEqual(inserter.insertCallCount, 0)
    }

    func test_emptyTranscription_nothingInserted() async {
        // Engine returns text the hallucination filter empties → empty finalText → no insert.
        let engine = FakeScriptedEngine(scriptedFinal: "[BLANK_AUDIO]")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        XCTAssertEqual(outcome, .emptyTranscription)
        XCTAssertEqual(inserter.insertCallCount, 0)
    }

    func test_emptyTranscription_whitespaceOnlyResult() async {
        let engine = FakeScriptedEngine(scriptedFinal: "   ")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        XCTAssertEqual(outcome, .emptyTranscription)
        XCTAssertEqual(inserter.insertCallCount, 0)
    }

    // MARK: buildStableDisplayText / StreamingTextAssembler — multi-partial streaming

    func test_streaming_singlePartialNoSentenceEnd() {
        var asm = StreamingTextAssembler()
        XCTAssertEqual(asm.append("hello there"), "hello there")
        // No sentence-ending punctuation → nothing committed yet.
        XCTAssertEqual(asm.committedStreamingText, "")
    }

    func test_streaming_commitsCompletedSentence() {
        var asm = StreamingTextAssembler()
        let display = asm.append("Hello world. And")
        // First sentence committed; trailing fragment shown but not committed.
        XCTAssertEqual(asm.committedStreamingText, "Hello world.")
        XCTAssertTrue(display.hasPrefix("Hello world."))
        XCTAssertTrue(display.contains("And"))
    }

    func test_streaming_multiPartialAssemblyAcrossSentences() {
        var asm = StreamingTextAssembler()
        _ = asm.append("First sentence.")
        XCTAssertEqual(asm.committedStreamingText, "First sentence.")
        // Next partial extends with the committed prefix flattened to a space.
        let display = asm.append("First sentence. Second sentence.")
        XCTAssertEqual(asm.committedStreamingText, "First sentence.\nSecond sentence.")
        // Committed sentences are line-separated so existing lines don't reflow.
        XCTAssertTrue(display.contains("\n"))
    }

    func test_streaming_shorterPartialDoesNotRegress() {
        var asm = StreamingTextAssembler()
        _ = asm.append("A longer first sentence here.")
        let committed = asm.committedStreamingText
        // A shorter re-inference must not wipe committed text.
        let display = asm.append("short")
        XCTAssertEqual(asm.committedStreamingText, committed)
        XCTAssertEqual(display, committed)
    }

    func test_streaming_emptyPartialReturnsCommitted() {
        var asm = StreamingTextAssembler()
        _ = asm.append("Committed sentence.")
        XCTAssertEqual(asm.append("   "), "Committed sentence.")
        XCTAssertEqual(asm.append(""), "Committed sentence.")
    }

    func test_streaming_resetClearsCommitted() {
        var asm = StreamingTextAssembler()
        _ = asm.append("Something committed.")
        XCTAssertFalse(asm.committedStreamingText.isEmpty)
        asm.reset()
        XCTAssertEqual(asm.committedStreamingText, "")
        // After reset, the next partial starts fresh.
        XCTAssertEqual(asm.append("fresh start"), "fresh start")
    }

    func test_streaming_assemblerMatchesExtractedLogicForThreeWaySequence() {
        // A realistic 3-partial growth sequence (the case Tier-1 must not break).
        var asm = StreamingTextAssembler()
        XCTAssertEqual(asm.append("The quick"), "The quick")
        XCTAssertEqual(asm.append("The quick brown fox."), "The quick brown fox.")
        XCTAssertEqual(asm.committedStreamingText, "The quick brown fox.")
        let third = asm.append("The quick brown fox. Jumps over")
        XCTAssertTrue(third.hasPrefix("The quick brown fox."))
        XCTAssertTrue(third.contains("Jumps over"))
        // "Jumps over" has no terminal punctuation → not yet committed.
        XCTAssertEqual(asm.committedStreamingText, "The quick brown fox.")
    }
}
