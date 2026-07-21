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
@testable import SpeakFreeLib

// MARK: - Test doubles

/// Scripted engine: returns canned transcription text (or throws a scripted error) with
/// zero real inference. Conforms to the same `TranscriptionEngine` protocol the app's
/// WhisperEngine / ParakeetEngine conform to, so it slots into a real `Transcriber`.
final class FakeScriptedEngine: TranscriptionEngine {
    var engineID: String
    var isLoaded: Bool = true
    var supportsStreaming: Bool
    var supportsPrompt: Bool = true
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
                punctuationMode: punctuation,
                cursorContextText: cursorContext,
                screenContextText: screenContext,
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

    // MARK: cursor-context fallback (2026-07-15: mid-sentence lowercase died in VS Code)

    func test_fallbackContext_sameAppWithinWindow_returnsTail() {
        let now = Date()
        let ctx = FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "It looks weird,",
            lastInsertedBundleID: "com.microsoft.VSCode",
            lastInsertedAt: now.addingTimeInterval(-5),
            frontmostBundleID: "com.microsoft.VSCode",
            now: now)
        XCTAssertEqual(ctx, "It looks weird,")
    }

    func test_fallbackContext_expiredWindow_returnsNil() {
        let now = Date()
        XCTAssertNil(FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "tail", lastInsertedBundleID: "com.app",
            lastInsertedAt: now.addingTimeInterval(-20),
            frontmostBundleID: "com.app", now: now),
            "a 15s-stale insertion no longer predicts the cursor position")
    }

    func test_fallbackContext_differentApp_returnsNil() {
        let now = Date()
        XCTAssertNil(FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "tail", lastInsertedBundleID: "com.microsoft.VSCode",
            lastInsertedAt: now.addingTimeInterval(-2),
            frontmostBundleID: "com.apple.Notes", now: now),
            "switching apps invalidates the remembered insertion point")
    }

    func test_fallbackContext_noHistory_returnsNil() {
        XCTAssertNil(FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: nil, lastInsertedBundleID: nil, lastInsertedAt: nil,
            frontmostBundleID: "com.app", now: Date()))
    }

    func test_realTimingRegression_userInteractionStartsFreshSentence() {
        let now = Date()
        let context = FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "It's",
            lastInsertedBundleID: "com.google.Chrome",
            lastInsertedAt: now.addingTimeInterval(-1),
            frontmostBundleID: "com.google.Chrome",
            now: now,
            userInteractedSinceInsertion: true,
            focusedElementMatches: false)
        XCTAssertNil(context, "a click into a new field must invalidate the prior insertion tail")

        let final = TextPipeline.run(TextPipeline.Input(
            raw: "Timing is different than the Premiere version, but doesn't matter, there's no dialogue.",
            punctuationMode: .off,
            cursorContextText: context,
            audioDurationSeconds: 8.5
        )).finalText
        XCTAssertEqual(
            FinalizePipeline.composeInsertText(
                final,
                prependSpace: TextInserter.shouldPrependSpace(contextBefore: context)),
            "Timing is different than the Premiere version, but doesn't matter, there's no dialogue.")
    }

    func test_fallbackContext_sameElementWithoutInteraction_stillContinues() {
        let now = Date()
        XCTAssertEqual(FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "It looks weird,",
            lastInsertedBundleID: "com.microsoft.VSCode",
            lastInsertedAt: now.addingTimeInterval(-2),
            frontmostBundleID: "com.microsoft.VSCode",
            now: now,
            userInteractedSinceInsertion: false,
            focusedElementMatches: true), "It looks weird,")
    }

    func test_fallbackContext_drivesMidSentenceLowercase() {
        // End-to-end intent check: a fallback tail ending mid-sentence lowercases the
        // next dictation's leading capital; a sentence-final tail leaves it alone.
        XCTAssertEqual(
            TextPipeline.adjustCaseForInsertion("I think so", contextBefore: "It looks weird,"),
            "i think so".replacingOccurrences(of: "i think", with: "I think"),
            "leading 'I' is deliberate capitalization and must survive")
        XCTAssertEqual(
            TextPipeline.adjustCaseForInsertion("Have the glow happen", contextBefore: "feels unreal,"),
            "have the glow happen")
        XCTAssertEqual(
            TextPipeline.adjustCaseForInsertion("Have the glow happen", contextBefore: "That is done."),
            "Have the glow happen")
    }

    // MARK: wav-arbiter gate (2026-06-29 AirPods incident: good wav dropped as "silent")

    func test_gateArbiter_memoryPasses_wavNeverRead() {
        var wavRead = false
        let good = Array(repeating: Float(0.2), count: FinalizePipeline.minSamples + 16_000)
        let gate = FinalizePipeline.resolveGateSamples(memorySamples: good,
                                                       readWav: { wavRead = true; return nil })
        XCTAssertNil(gate.failure)
        XCTAssertFalse(gate.usedWavFallback)
        XCTAssertFalse(wavRead, "the wav is only the arbiter on gate failure — no read on the happy path")
        XCTAssertEqual(gate.samples.count, good.count)
    }

    func test_gateArbiter_memorySilentButWavGood_usesWavSamples() {
        let zeros = Array(repeating: Float(0), count: FinalizePipeline.minSamples + 16_000)
        let fromWav = Array(repeating: Float(0.3), count: FinalizePipeline.minSamples + 32_000)
        let gate = FinalizePipeline.resolveGateSamples(memorySamples: zeros, readWav: { fromWav })
        XCTAssertNil(gate.failure, "a good wav must rescue the dictation")
        XCTAssertTrue(gate.usedWavFallback)
        XCTAssertEqual(gate.samples.count, fromWav.count)
    }

    func test_gateArbiter_memoryTooShortButWavGood_usesWavSamples() {
        let short = Array(repeating: Float(0.2), count: FinalizePipeline.minSamples - 1)
        let fromWav = Array(repeating: Float(0.3), count: FinalizePipeline.minSamples + 32_000)
        let gate = FinalizePipeline.resolveGateSamples(memorySamples: short, readWav: { fromWav })
        XCTAssertNil(gate.failure)
        XCTAssertTrue(gate.usedWavFallback)
    }

    func test_gateArbiter_bothSilent_stillSilent() {
        let zeros = Array(repeating: Float(0), count: FinalizePipeline.minSamples + 16_000)
        let gate = FinalizePipeline.resolveGateSamples(memorySamples: zeros, readWav: { zeros })
        guard case .silent = gate.failure else {
            return XCTFail("expected .silent when memory AND wav are silent, got \(String(describing: gate.failure))")
        }
        XCTAssertFalse(gate.usedWavFallback)
    }

    func test_gateArbiter_wavUnreadable_failsOnMemoryVerdict() {
        let short = Array(repeating: Float(0.2), count: 10)
        let gate = FinalizePipeline.resolveGateSamples(memorySamples: short, readWav: { nil })
        XCTAssertEqual(gate.failure, .tooShort(sampleCount: 10))
    }

    func test_gateArbiter_runTranscribesWavSamplesWhenMemorySilent() async {
        // Full run(): all-zero in-memory samples + a good "wav" → the engine must run,
        // and must receive the wav's samples, not the dead in-memory copy.
        let engine = FakeScriptedEngine(scriptedFinal: "rescued from the wav")
        let inserter = MockInserter()
        let zeros = Array(repeating: Float(0), count: FinalizePipeline.minSamples + 16_000)
        let fromWav = Array(repeating: Float(0.3), count: FinalizePipeline.minSamples + 32_000)

        let outcome = await FinalizePipeline.run(
            samples: zeros,
            audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
            makeInput: makeInputClosure(punctuation: .off),
            transcribe: { _, samples, prompt in
                try await engine.transcribe(samples: samples, language: "en",
                                            prompt: prompt, suppressRegex: nil)
            },
            inserter: inserter,
            element: nil,
            readWav: { fromWav }
        )

        guard case .inserted = outcome else { return XCTFail("expected .inserted, got \(outcome)") }
        XCTAssertEqual(engine.transcribeCallCount, 1)
        XCTAssertEqual(engine.lastSamples.count, fromWav.count,
                       "engine must see the wav samples, not the silent in-memory copy")
        XCTAssertEqual(inserter.insertedTexts.first, "rescued from the wav")
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

    // MARK: Newline policy 2b / Option B — Whisper multi-segment output never reaches insertion as \n

    /// (a) A multi-segment engine result (raw "\n"-separated segments, the shape whisper emits)
    /// must be space-joined by the Transcriber so the text that lands in the inserter contains
    /// NO "\n", and the MockInserter records no Return-equivalent (the keystroke route is never
    /// reached for a single space-joined line).
    func test_newline2b_multiSegmentResult_spaceJoined_noNewlineReachesInserter() async {
        // Engine returns raw whisper-style multi-segment output: one segment per line.
        let engine = FakeScriptedEngine(scriptedFinal: " First segment\n Second segment\n Third segment")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        // Space-joined, not "\n"-joined.
        XCTAssertEqual(insertedText, "First segment Second segment Third segment")
        XCTAssertFalse(insertedText.contains("\n"),
                       "multi-segment whisper output must NOT carry a \\n into insertion")
        XCTAssertEqual(inserter.insertedTexts, ["First segment Second segment Third segment"])
        // No newline in the text → keystroke route would emit zero Shift+Return / Return ops.
        XCTAssertTrue(TextInserter.keystrokeOps(for: insertedText).allSatisfy {
            if case .shiftReturn = $0 { return false } else { return true }
        }, "no Return-equivalent op may be produced for space-joined multi-segment text")
    }

    /// (c) Regression: even when the engine returns many segments, no Whisper-origin "\n" can
    /// reach the TextInserter. Asserts on the exact string handed to the inserter.
    func test_newline2b_regression_noWhisperOriginNewlineReachesInserter() async {
        let engine = FakeScriptedEngine(scriptedFinal: "alpha\nbravo\ncharlie\ndelta\necho")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertFalse(insertedText.contains("\n"),
                       "Whisper-origin segment breaks must be space-joined, never \\n")
        XCTAssertEqual(insertedText, "alpha bravo charlie delta echo")
        XCTAssertEqual(inserter.insertedTexts.first?.contains("\n"), false)
    }

    /// (b, pipeline half) A SPOKEN "new line" in the transcript survives the full pipeline as a
    /// literal "\n" handed to the inserter (TextPostProcessor maps spoken "new line" → \n). The
    /// keystroke-vs-clipboard *routing* of that "\n" is asserted in NewlinePolicy2bTests.
    func test_newline2b_spokenNewLine_survivesPipelineAsLiteralNewline() async {
        // Engine returns ONE line (no segment split); the only "\n" source is the spoken command.
        let engine = FakeScriptedEngine(scriptedFinal: "first line new line second line")
        let inserter = MockInserter()
        let outcome = await runViaTranscriber(
            samples: loudSamples(), engine: engine, inserter: inserter,
            makeInput: makeInputClosure(punctuation: .spoken)
        )
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertTrue(insertedText.contains("\n"),
                      "spoken \"new line\" must become a literal \\n; got \(insertedText.debugDescription)")
        XCTAssertEqual(insertedText.filter { $0 == "\n" }.count, 1,
                       "exactly one spoken break → exactly one \\n")
    }

    // MARK: T2.3 reuse path — Newline Policy 2b regression (AR-2 R1, finding 3)

    /// Drive FinalizePipeline through the REUSE branch with a given raw streaming partial.
    /// `transcribe` is wired to fail loudly so a regression that runs the final pass instead of
    /// reusing is caught immediately.
    private func runReuse(
        rawPartial: String,
        samples: [Float]? = nil,
        inserter: MockInserter,
        makeInput: @escaping (String) -> TextPipeline.Input
    ) async -> FinalizePipeline.Outcome {
        return await FinalizePipeline.run(
            samples: samples ?? loudSamples(),
            audioURL: audioURL,
            makeInput: makeInput,
            transcribe: { _, _, _ in
                XCTFail("reuse path must SKIP the final inference")
                return ""
            },
            inserter: inserter,
            element: nil,
            reuseDecision: .reusePartial(rawPartial: rawPartial)
        )
    }

    /// The streaming partial is RAW collectSegments output — it can carry embedded "\n" between
    /// acoustic segments (whisper emits one line per segment, concatenated with no normalization).
    /// The reuse path must apply the SAME space-join the final pass applies, so NO Whisper-origin
    /// "\n" survives into the inserter and fires a `.shiftReturn`. This is the exact 2b footgun the
    /// reuse path was previously unguarded against.
    func test_newline2b_reusePath_multiSegmentPartial_spaceJoined_noNewlineReachesInserter() async {
        let inserter = MockInserter()
        let outcome = await runReuse(
            rawPartial: "hello there\nhow are you",
            inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .reusedPartial(insertedText, _) = outcome else {
            return XCTFail("expected .reusedPartial, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "hello there how are you",
                       "reused multi-segment partial must be space-joined, not \\n-joined")
        XCTAssertFalse(insertedText.contains("\n"),
                       "reuse path must NOT carry a Whisper-origin \\n into insertion")
        XCTAssertTrue(TextInserter.keystrokeOps(for: insertedText).allSatisfy {
            if case .shiftReturn = $0 { return false } else { return true }
        }, "no Return-equivalent op may be produced for the space-joined reused partial")
    }

    /// Many-segment partial: still no "\n" survives the reuse path.
    func test_newline2b_reusePath_regression_noWhisperOriginNewlineReachesInserter() async {
        let inserter = MockInserter()
        let outcome = await runReuse(
            rawPartial: "alpha\nbravo\ncharlie\ndelta\necho",
            inserter: inserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .reusedPartial(insertedText, _) = outcome else {
            return XCTFail("expected .reusedPartial, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "alpha bravo charlie delta echo")
        XCTAssertFalse(insertedText.contains("\n"))
    }

    /// The reuse path and the final path must produce the IDENTICAL inserted text for the same raw
    /// multi-segment string — proving they are byte-equivalent for newline handling (the code's own
    /// "SAME TextPipeline / identical post-processing" claim is now actually true).
    func test_newline2b_reusePath_matchesFinalPath_forMultiSegment() async {
        let raw = " First segment\n Second segment\n Third segment"

        let finalInserter = MockInserter()
        let finalEngine = FakeScriptedEngine(scriptedFinal: raw)
        let finalOutcome = await runViaTranscriber(
            samples: loudSamples(), engine: finalEngine, inserter: finalInserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .inserted(finalText, _) = finalOutcome else {
            return XCTFail("expected .inserted, got \(finalOutcome)")
        }

        let reuseInserter = MockInserter()
        let reuseOutcome = await runReuse(
            rawPartial: raw, inserter: reuseInserter,
            makeInput: makeInputClosure(punctuation: .off)
        )
        guard case let .reusedPartial(reuseText, _) = reuseOutcome else {
            return XCTFail("expected .reusedPartial, got \(reuseOutcome)")
        }

        XCTAssertEqual(reuseText, finalText,
                       "reuse path must produce byte-identical text to the final path for multi-segment input")
    }

    /// A genuinely SPOKEN "new line" must still survive the reuse path as a literal "\n" — the
    /// segment-collapse must only remove acoustic splits, never the deliberate spoken break.
    func test_newline2b_reusePath_spokenNewLine_survivesAsLiteralNewline() async {
        let inserter = MockInserter()
        // One segment (no "\n" split); the only "\n" source is the spoken command.
        let outcome = await runReuse(
            rawPartial: "first line new line second line",
            inserter: inserter,
            makeInput: makeInputClosure(punctuation: .spoken)
        )
        guard case let .reusedPartial(insertedText, _) = outcome else {
            return XCTFail("expected .reusedPartial, got \(outcome)")
        }
        XCTAssertEqual(insertedText.filter { $0 == "\n" }.count, 1,
                       "spoken \"new line\" must still become exactly one literal \\n on the reuse path")
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
