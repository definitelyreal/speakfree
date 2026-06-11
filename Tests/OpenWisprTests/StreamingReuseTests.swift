// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.3 — Reuse last streaming partial for short utterances.
//
// Two layers:
//   1. PURE GATE — StreamingReuse.decide over the timing + growth + flag conditions.
//   2. INTEGRATION — the gate wired to the SAME T0.4 harness seams (FakeScriptedEngine +
//      MockInserter + TextPipeline) the app uses, proving that on a reuse the engine's final
//      `transcribe` is NEVER called (near-zero final-inference time), the SAVED partial flows
//      through the full TextPipeline post-processing, and that long clips / over-growth / a
//      disabled flag all fall back to the real final inference.

import ApplicationServices
import XCTest
@testable import OpenWisprLib

final class StreamingReuseTests: XCTestCase {

    // A fixed reference instant so timing math is deterministic.
    private let t0: Double = 1_000_000.0

    private func state(
        flag: Bool = true,
        partial: String = "hello world",
        streamedSamples: Int = 32_000,        // 2.0s @ 16kHz
        completedAt: Double? = nil,
        releaseSamples: Int = 33_000,         // ~+3% growth
        releaseAt: Double? = nil
    ) -> StreamingReuse.State {
        StreamingReuse.State(
            flagEnabled: flag,
            lastRawPartial: partial,
            lastStreamedSampleCount: streamedSamples,
            lastStreamCompletedAt: completedAt ?? t0,
            sampleCountAtRelease: releaseSamples,
            keyReleaseAt: releaseAt ?? (t0 + 0.1)  // 100ms after the pass — fresh
        )
    }

    // MARK: - Pure gate

    func test_decide_reusesWhenFreshAndBarelyGrown() {
        let d = StreamingReuse.decide(state())
        XCTAssertEqual(d, .reusePartial(rawPartial: "hello world"))
    }

    func test_decide_flagOff_alwaysRunsFinal() {
        let d = StreamingReuse.decide(state(flag: false))
        XCTAssertEqual(d, .runFinalInference(reason: .flagDisabled))
    }

    func test_decide_emptyPartial_runsFinal() {
        XCTAssertEqual(StreamingReuse.decide(state(partial: "")),
                       .runFinalInference(reason: .noPartial))
        XCTAssertEqual(StreamingReuse.decide(state(partial: "   \n  ")),
                       .runFinalInference(reason: .noPartial))
    }

    func test_decide_staleRelease_runsFinal() {
        // Release 301ms after the pass completed → just over the 300ms freshness window.
        let d = StreamingReuse.decide(state(releaseAt: t0 + 0.301))
        XCTAssertEqual(d, .runFinalInference(reason: .stale))
    }

    func test_decide_freshAtExactly300ms_reuses() {
        // Boundary: exactly 300ms is still fresh (gate is `<=`).
        let d = StreamingReuse.decide(state(releaseAt: t0 + 0.300))
        XCTAssertEqual(d, .reusePartial(rawPartial: "hello world"))
    }

    func test_decide_grewTooMuch_runsFinal() {
        // 32000 → 36000 samples = +12.5% growth, over the 10% gate.
        let d = StreamingReuse.decide(state(streamedSamples: 32_000, releaseSamples: 36_000))
        XCTAssertEqual(d, .runFinalInference(reason: .grewTooMuch))
    }

    func test_decide_growthAtExactly10Percent_reuses() {
        // 32000 → 35200 = +10.0% exactly (gate is `<=`).
        let d = StreamingReuse.decide(state(streamedSamples: 32_000, releaseSamples: 35_200))
        XCTAssertEqual(d, .reusePartial(rawPartial: "hello world"))
    }

    func test_decide_zeroStreamedSamples_runsFinal() {
        let d = StreamingReuse.decide(state(streamedSamples: 0))
        XCTAssertEqual(d, .runFinalInference(reason: .noStreamedSamples))
    }

    func test_decide_shrunkRecording_treatedAsNoGrowth_reuses() {
        // Recorder count smaller than streamed (shouldn't happen) → growth clamped to 0 → reuse.
        let d = StreamingReuse.decide(state(streamedSamples: 32_000, releaseSamples: 31_000))
        XCTAssertEqual(d, .reusePartial(rawPartial: "hello world"))
    }

    func test_decide_releaseBeforeCompletion_treatedAsFresh_reuses() {
        // Clock skew: release timestamp earlier than the recorded completion → age clamped, fresh.
        let d = StreamingReuse.decide(state(completedAt: t0 + 0.5, releaseAt: t0))
        XCTAssertEqual(d, .reusePartial(rawPartial: "hello world"))
    }

    func test_decide_customThresholds_areHonored() {
        // Tighten the freshness window to 50ms: a 100ms-old partial is now stale.
        let d = StreamingReuse.decide(state(releaseAt: t0 + 0.1), releaseWithinMs: 50)
        XCTAssertEqual(d, .runFinalInference(reason: .stale))
    }

    // MARK: - Integration: reuse routes the partial through TextPipeline, skips the engine

    /// Mirror the app's finalize routing: decide → (reuse ? saved partial : transcriber.transcribe)
    /// → TextPipeline → inserter. Returns the inserted text, the engine's transcribe-call count,
    /// and a wall-clock for the inference step (proves near-zero on reuse).
    private struct FinalizeOutcome {
        let inserted: String?
        let engineCalls: Int
        let inferenceMs: Double
    }

    private func runFinalizeMirror(
        decision: StreamingReuse.Decision,
        engine: FakeScriptedEngine,
        inserter: MockInserter,
        punctuation: PunctuationMode = .off
    ) async -> FinalizeOutcome {
        let transcriber = Transcriber(engine: engine, modelID: "tiny.en", language: "en")
        let makeInput: (String) -> TextPipeline.Input = { raw in
            TextPipeline.Input(raw: raw, cursorContextText: nil, screenContextText: nil,
                               punctuationMode: punctuation, styleMode: .none, glossaryWords: nil)
        }
        let audioURL = URL(fileURLWithPath: "/tmp/speakfree-reuse-test.wav")
        let samples: [Float] = (0..<32_000).map { _ in 0.2 }

        // The exact branch finalizeRecording runs.
        let t0 = DispatchTime.now()
        let raw: String
        switch decision {
        case .reusePartial(let rawPartial):
            raw = rawPartial
        case .runFinalInference:
            do {
                raw = try await transcriber.transcribe(audioURL: audioURL, samples: samples,
                                                       prompt: TextPipeline.assemblePromptHints(input: makeInput("")))
            } catch {
                return FinalizeOutcome(inserted: nil, engineCalls: engine.transcribeCallCount, inferenceMs: 0)
            }
        }
        let inferenceMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0

        let text = TextPipeline.run(makeInput(raw)).finalText
        guard !text.isEmpty else {
            return FinalizeOutcome(inserted: nil, engineCalls: engine.transcribeCallCount, inferenceMs: inferenceMs)
        }
        inserter.insert(text: text, refocusing: nil, onFocusLost: nil)
        return FinalizeOutcome(inserted: text, engineCalls: engine.transcribeCallCount, inferenceMs: inferenceMs)
    }

    func test_integration_shortClipReuseFires_engineNeverCalled_partialInserted() async {
        // A short, fresh, barely-grown utterance → reuse. The saved partial ("hello world period")
        // must flow through TextPipeline (spoken "period" → ".") and land in the inserter, with
        // ZERO calls to the engine's final transcribe (near-zero final-inference latency).
        let engine = FakeScriptedEngine(scriptedFinal: "FINAL PASS SHOULD NOT RUN")
        let inserter = MockInserter()
        let decision = StreamingReuse.decide(state(partial: "hello world period"))
        let outcome = await runFinalizeMirror(decision: decision, engine: engine, inserter: inserter,
                                              punctuation: .spoken)
        XCTAssertEqual(outcome.inserted, "hello world.",
                       "reused partial must run through TextPipeline (spoken 'period' → '.')")
        XCTAssertEqual(outcome.engineCalls, 0, "reuse must NOT call the final inference")
        XCTAssertEqual(inserter.insertedTexts, ["hello world."])
        // Near-zero final inference: reuse does no whisper_full at all.
        XCTAssertLessThan(outcome.inferenceMs, 5.0,
                          "reuse inference step should be ~0ms (no engine call); got \(outcome.inferenceMs)ms")
    }

    func test_integration_longClipDoesNotReuse_engineRunsFinalPass() async {
        // Recording grew far beyond the partial (e.g. the user kept talking after the last
        // streaming pass) → the gate declines, the engine's final pass runs and its text wins.
        let engine = FakeScriptedEngine(scriptedFinal: "the real final transcription")
        let inserter = MockInserter()
        // +50% growth → grewTooMuch.
        let decision = StreamingReuse.decide(state(partial: "stale partial",
                                                   streamedSamples: 32_000, releaseSamples: 48_000))
        XCTAssertEqual(decision, .runFinalInference(reason: .grewTooMuch))
        let outcome = await runFinalizeMirror(decision: decision, engine: engine, inserter: inserter)
        XCTAssertEqual(outcome.inserted, "the real final transcription")
        XCTAssertEqual(outcome.engineCalls, 1, "a non-reused clip must run the final inference once")
        XCTAssertFalse(inserter.insertedTexts.contains { $0.contains("stale partial") },
                       "the stale streaming partial must NOT be inserted when the gate declines")
    }

    func test_integration_sampleGrowthGuardForcesFinalPass() async {
        // Same short duration / fresh timing, but just over the 10% growth gate → final pass runs.
        let engine = FakeScriptedEngine(scriptedFinal: "fresh final text")
        let inserter = MockInserter()
        let decision = StreamingReuse.decide(state(partial: "old partial",
                                                   streamedSamples: 32_000, releaseSamples: 35_300)) // +10.3%
        XCTAssertEqual(decision, .runFinalInference(reason: .grewTooMuch))
        let outcome = await runFinalizeMirror(decision: decision, engine: engine, inserter: inserter)
        XCTAssertEqual(outcome.engineCalls, 1)
        XCTAssertEqual(outcome.inserted, "fresh final text")
    }

    func test_integration_flagOff_alwaysRunsFinalPass() async {
        // Kill-switch: even a perfectly-reusable short clip runs the final pass when the flag is off.
        let engine = FakeScriptedEngine(scriptedFinal: "final because flag is off")
        let inserter = MockInserter()
        let decision = StreamingReuse.decide(state(flag: false, partial: "would-be reused"))
        XCTAssertEqual(decision, .runFinalInference(reason: .flagDisabled))
        let outcome = await runFinalizeMirror(decision: decision, engine: engine, inserter: inserter)
        XCTAssertEqual(outcome.engineCalls, 1, "flag off → final inference always runs")
        XCTAssertEqual(outcome.inserted, "final because flag is off")
    }

    // MARK: - Integration via the REAL T0.4 FinalizePipeline.run seam
    //
    // The mirror above re-implements the branch; these drive the ACTUAL FinalizePipeline.run that
    // AppDelegate.finalizeRecording delegates to, passing the reuse decision through its new
    // `reuseDecision:` parameter. This proves the production code path: reuse → `.reusedPartial`,
    // engine's `transcribe` never called, saved partial routed through the SAME TextPipeline.

    private let pipelineAudioURL = URL(fileURLWithPath: "/tmp/speakfree-reuse-pipeline.wav")

    private func loudSamples(count: Int = FinalizePipeline.minSamples + 16_000) -> [Float] {
        (0..<count).map { _ in 0.2 }
    }

    private func makeInput(
        _ punctuation: PunctuationMode = .off
    ) -> (String) -> TextPipeline.Input {
        return { raw in
            TextPipeline.Input(raw: raw, cursorContextText: nil, screenContextText: nil,
                               punctuationMode: punctuation, styleMode: .none, glossaryWords: nil)
        }
    }

    /// Drive the real FinalizePipeline.run with a transcribe seam that counts engine calls.
    private func runPipeline(
        decision: StreamingReuse.Decision,
        scriptedFinal: String,
        inserter: MockInserter,
        punctuation: PunctuationMode = .off,
        engineCalls: @escaping () -> Void
    ) async -> FinalizePipeline.Outcome {
        await FinalizePipeline.run(
            samples: loudSamples(),
            audioURL: pipelineAudioURL,
            makeInput: makeInput(punctuation),
            transcribe: { _, _, _ in engineCalls(); return scriptedFinal },
            inserter: inserter,
            element: nil,
            precomputedPrependSpace: false,
            reuseDecision: decision
        )
    }

    func test_pipeline_shortClipReuse_emitsReusedPartial_engineNeverCalled() async {
        // Fresh, barely-grown short clip → reuse. The real pipeline must SKIP the transcribe seam
        // entirely (engineCalls stays 0), route the saved partial ("hi there period") through
        // TextPipeline (spoken 'period' → '.'), and emit .reusedPartial (not .inserted).
        var calls = 0
        let inserter = MockInserter()
        let decision = StreamingReuse.decide(state(partial: "hi there period"))
        let outcome = await runPipeline(
            decision: decision, scriptedFinal: "FINAL MUST NOT RUN",
            inserter: inserter, punctuation: .spoken, engineCalls: { calls += 1 })
        guard case let .reusedPartial(insertedText, pasted) = outcome else {
            return XCTFail("expected .reusedPartial, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "hi there.", "reused partial flows through the full TextPipeline")
        XCTAssertTrue(pasted)
        XCTAssertEqual(calls, 0, "the final transcribe seam must NEVER be called on a reuse")
        XCTAssertEqual(inserter.insertedTexts, ["hi there."])
    }

    func test_pipeline_longClip_runsFinalInference_emitsInserted() async {
        // Over-grown clip → gate declines → the real pipeline runs the transcribe seam once and
        // emits .inserted with the FINAL text, never the stale partial.
        var calls = 0
        let inserter = MockInserter()
        let decision = StreamingReuse.decide(state(partial: "stale partial",
                                                   streamedSamples: 32_000, releaseSamples: 48_000))
        XCTAssertEqual(decision, .runFinalInference(reason: .grewTooMuch))
        let outcome = await runPipeline(
            decision: decision, scriptedFinal: "the real final transcription",
            inserter: inserter, engineCalls: { calls += 1 })
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "the real final transcription")
        XCTAssertEqual(calls, 1, "a non-reused clip runs the final inference exactly once")
    }

    func test_pipeline_growthGuard_justOver10Percent_runsFinalInference() async {
        var calls = 0
        let inserter = MockInserter()
        // +10.3% growth (32000 → 35300) — just over the 10% gate.
        let decision = StreamingReuse.decide(state(partial: "old partial",
                                                   streamedSamples: 32_000, releaseSamples: 35_300))
        XCTAssertEqual(decision, .runFinalInference(reason: .grewTooMuch))
        let outcome = await runPipeline(
            decision: decision, scriptedFinal: "fresh final text",
            inserter: inserter, engineCalls: { calls += 1 })
        guard case .inserted = outcome else { return XCTFail("expected .inserted, got \(outcome)") }
        XCTAssertEqual(calls, 1)
    }

    func test_pipeline_flagOff_runsFinalInference_killSwitch() async {
        // Kill-switch: a perfectly reusable short clip still runs the final pass when the flag is off.
        var calls = 0
        let inserter = MockInserter()
        let decision = StreamingReuse.decide(state(flag: false, partial: "would-be reused"))
        XCTAssertEqual(decision, .runFinalInference(reason: .flagDisabled))
        let outcome = await runPipeline(
            decision: decision, scriptedFinal: "final because flag is off",
            inserter: inserter, engineCalls: { calls += 1 })
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "final because flag is off")
        XCTAssertEqual(calls, 1, "flag off → final inference always runs")
    }

    func test_pipeline_nilDecision_isByteIdenticalToFinalPass() async {
        // A nil reuseDecision (legacy callers) must behave EXACTLY like pre-T2.3: run the final pass.
        var calls = 0
        let inserter = MockInserter()
        let outcome = await FinalizePipeline.run(
            samples: loudSamples(),
            audioURL: pipelineAudioURL,
            makeInput: makeInput(.off),
            transcribe: { _, _, _ in calls += 1; return "ordinary final text" },
            inserter: inserter,
            element: nil,
            precomputedPrependSpace: false,
            reuseDecision: nil
        )
        guard case let .inserted(insertedText, _) = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        XCTAssertEqual(insertedText, "ordinary final text")
        XCTAssertEqual(calls, 1)
    }

    func test_pipeline_reuseWithEmptyPartialAfterPipeline_emitsEmptyTranscription() async {
        // Defensive: if a reused partial post-processes to empty (e.g. only a hallucination marker),
        // the pipeline emits .emptyTranscription and inserts nothing — same as the final path.
        var calls = 0
        let inserter = MockInserter()
        let outcome = await runPipeline(
            decision: .reusePartial(rawPartial: "[BLANK_AUDIO]"),
            scriptedFinal: "unused", inserter: inserter, engineCalls: { calls += 1 })
        XCTAssertEqual(outcome, .emptyTranscription)
        XCTAssertEqual(calls, 0, "reuse path must not call the engine even when the partial empties")
        XCTAssertEqual(inserter.insertCallCount, 0)
    }

    // MARK: - Config flag (FlexBool, default ON)

    func test_config_reuseStreamingPartial_defaultsToOnWhenAbsent() throws {
        // Absent in JSON → nil → app treats `?? true` as ON.
        let json = #"{"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"tiny.en","language":"en"}"#
        let cfg = try Config.decode(from: Data(json.utf8))
        XCTAssertNil(cfg.reuseStreamingPartial)
        XCTAssertTrue(cfg.reuseStreamingPartial?.value ?? true, "default (nil) must read as ON")
    }

    func test_config_reuseStreamingPartial_killSwitchParsesFalse() throws {
        let json = #"{"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"tiny.en","language":"en","reuseStreamingPartial":false}"#
        let cfg = try Config.decode(from: Data(json.utf8))
        XCTAssertEqual(cfg.reuseStreamingPartial?.value, false)
    }

    func test_config_reuseStreamingPartial_flexBoolStringForm() throws {
        let json = #"{"hotkey":{"keyCode":63,"modifiers":[]},"modelSize":"tiny.en","language":"en","reuseStreamingPartial":"no"}"#
        let cfg = try Config.decode(from: Data(json.utf8))
        XCTAssertEqual(cfg.reuseStreamingPartial?.value, false, "FlexBool 'no' → false")
    }
}
