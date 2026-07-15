// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
import ApplicationServices
import Foundation

/// Testable core of `AppDelegate.finalizeRecording`: the record → transcribe → insert
/// decision logic, lifted out of AppDelegate so it can be driven by a FakeEngine + a
/// MockInserter under XCTest without AppKit, a real audio engine, or a live cursor.
///
/// Sharing contract (audit 2026-07-03): `finalizeRecording` CALLS the pure pieces of this
/// type directly — `minSamples`/`silenceRMSThreshold`/`rms` for the gates, `resolveRaw`
/// for the T2.3 reuse-vs-final branch, `composeInsertText` for prepend-space assembly —
/// and keeps only UI / RecordingStore / status-bar side effects inline. `run(...)` below
/// composes those SAME pieces for tests, so a change to any decision is exercised by both
/// paths and they cannot silently diverge.
public enum FinalizePipeline {

    /// 300ms at 16kHz — the minimum sample count below which a recording is treated as an
    /// accidental tap and skipped. Mirrors `finalizeRecording`'s `minSamples`.
    public static let minSamples = 4800

    /// RMS below this means the captured audio is effectively silent (dead audio engine).
    public static let silenceRMSThreshold: Float = 0.0001

    /// What the pipeline decided to do with a recording. Each case mirrors a branch of
    /// `finalizeRecording`, so tests can assert the branch taken without reaching into AppKit.
    public enum Outcome: Equatable {
        /// Below `minSamples` — accidental tap, skipped before transcription.
        case tooShort(sampleCount: Int)
        /// RMS below threshold — silent/dead audio, skipped (engine should be rebuilt).
        case silent(rms: Float)
        /// Engine/transcriber threw. `modelMissing` flags the modelAssetsMissing case so the
        /// caller can surface the "download model" alert exactly as before.
        case failed(modelMissing: Bool)
        /// Transcription succeeded but produced empty text (e.g. hallucination filtered) —
        /// nothing inserted.
        case emptyTranscription
        /// Happy path: text reached the inserter. `insertedText` is the exact string handed to
        /// the inserter (including any prepended space); `pasted` mirrors `insert(...)`'s return.
        case inserted(insertedText: String, pasted: Bool)
        /// T2.3 — short-utterance fast path: the FINAL inference was SKIPPED and the already-computed
        /// streaming partial was routed through the SAME TextPipeline and inserted. Same observable
        /// effect as `.inserted`, but a distinct case so callers/tests can prove the final pass
        /// never ran. `insertedText`/`pasted` mirror `.inserted`.
        case reusedPartial(insertedText: String, pasted: Bool)
    }

    /// Pure RMS used by the silence guard. Matches `finalizeRecording`'s inline computation.
    public static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrtf(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    }

    /// True when samples pass both pre-transcription gates (length and non-silence).
    public static func passesGates(_ samples: [Float]) -> Bool {
        samples.count >= minSamples && rms(of: samples) >= silenceRMSThreshold
    }

    /// Resolve the samples to transcribe, with the wav on disk as ARBITER when the in-memory
    /// copy fails a gate. The wav is what gets kept and what replays fine offline — the
    /// 2026-06-29 AirPods incident was a good 6.7s wav whose dictation was dropped with
    /// "Recording was silent", and any memory-vs-file divergence must cost a file read, not
    /// a dictation. Returns the samples to use, the failure outcome (nil = proceed), and
    /// whether the wav override was taken (callers should log it — divergence is a bug
    /// somewhere upstream and must leave a trace).
    public static func resolveGateSamples(
        memorySamples: [Float],
        readWav: () -> [Float]?
    ) -> (samples: [Float], failure: Outcome?, usedWavFallback: Bool) {
        if passesGates(memorySamples) {
            return (memorySamples, nil, false)
        }
        if let fileSamples = readWav(), passesGates(fileSamples) {
            return (fileSamples, nil, true)
        }
        if memorySamples.count < minSamples {
            return (memorySamples, .tooShort(sampleCount: memorySamples.count), false)
        }
        return (memorySamples, .silent(rms: rms(of: memorySamples)), false)
    }

    /// T2.3 reuse-vs-final branch, shared verbatim by `finalizeRecording` and `run(...)`.
    ///
    /// When the gate approved reuse, the saved raw streaming partial is returned after
    /// `collapseSegmentNewlines` — the final pass applies that collapse inside
    /// `Transcriber.transcribeWithEngine`, so applying it here keeps the two paths
    /// byte-identical for multi-segment `\n` (an unspoken segment split can never reach
    /// TextInserter as a `.shiftReturn`). Otherwise the `transcribe` closure runs.
    public static func resolveRaw(
        reuseDecision: StreamingReuse.Decision?,
        transcribe: () async throws -> String
    ) async rethrows -> (raw: String, reusedPartial: Bool) {
        if case let .reusePartial(rawPartial)? = reuseDecision {
            return (TextPipeline.collapseSegmentNewlines(rawPartial), true)
        }
        return (try await transcribe(), false)
    }

    /// Prepend-space assembly, shared verbatim by `finalizeRecording` and `insertFinalText`.
    public static func composeInsertText(_ text: String, prependSpace: Bool) -> String {
        prependSpace ? " " + text : text
    }

    /// Cursor-context fallback for AX-opaque editors (2026-07-15). Electron apps
    /// (VS Code) expose no AXValue, so the mid-sentence-lowercase and prepend-space
    /// features silently died there. When AX yields nothing but the user is still in
    /// the SAME app within `window` seconds of speakfree's own last insertion, the
    /// tail of what was just typed IS the text before the cursor. The tight window
    /// bounds the risk of the user having moved the cursor in between.
    public static func fallbackCursorContext(
        lastInsertedTail: String?,
        lastInsertedBundleID: String?,
        lastInsertedAt: Date?,
        frontmostBundleID: String?,
        now: Date,
        window: TimeInterval = 15
    ) -> String? {
        guard let tail = lastInsertedTail, !tail.isEmpty,
              let at = lastInsertedAt,
              now.timeIntervalSince(at) >= 0,
              now.timeIntervalSince(at) <= window,
              let front = frontmostBundleID,
              front == lastInsertedBundleID else { return nil }
        return tail
    }

    /// Run the finalize core.
    ///
    /// - Parameters:
    ///   - samples: captured audio (16kHz mono Float32), as `finalizeRecording` sees it.
    ///   - audioURL: passed through to `transcribe`.
    ///   - promptContext: context-only Input used to assemble the Whisper prompt (no raw text needed).
    ///     Production passes the `pipelineContext` captured at record-start. When `nil` (backward-
    ///     compatible test path), context is derived from `makeInput` with an empty raw string.
    ///   - makeInput: builds the TextPipeline.Input for a given raw string — identical closure
    ///     shape to the one in `finalizeRecording`, so post-processing runs the same way as in
    ///     the app. Receives the actual transcript string; do NOT pass an empty placeholder.
    ///   - transcribe: the transcription seam — `Transcriber.transcribe(audioURL:samples:prompt:)`
    ///     in production, a FakeEngine-backed closure in tests.
    ///   - inserter: the insertion seam (`TextInserter` in production, MockInserter in tests).
    ///   - element: the captured focused element to refocus before inserting (nil in headless tests).
    ///   - precomputedPrependSpace: if non-nil, used directly instead of calling
    ///     `inserter.shouldPrependSpace(before:element)`. Production passes the value derived
    ///     from the cursor-context string captured at record-start (T2.2: off-main precompute).
    ///     When nil (legacy / test path without a precomputed value), `shouldPrependSpace` is
    ///     called on the inserter as before.
    ///   - onFocusLost: forwarded to `inserter.insert`.
    ///   - reuseDecision: T2.3 streaming-partial reuse gate. When `.reusePartial(raw)`, the FINAL
    ///     inference (the `transcribe` closure) is SKIPPED entirely and `raw` — the saved last
    ///     streaming partial — is routed through the SAME `makeInput`→`TextPipeline.run` the final
    ///     pass uses, then inserted identically. The result is `.reusedPartial`. When `nil` or
    ///     `.runFinalInference`, behavior is byte-identical to pre-T2.3 (run the final pass).
    ///   - readWav: gate-arbiter seam — returns the wav's samples when the in-memory copy fails
    ///     a gate (production: `ProcessCommand.loadSamples`). Default `nil` keeps the legacy
    ///     memory-only gating for tests that don't care.
    /// - Returns: the `Outcome` describing which branch ran.
    @discardableResult
    public static func run(
        samples: [Float],
        audioURL: URL,
        promptContext: TextPipeline.Input? = nil,
        makeInput: (String) -> TextPipeline.Input,
        transcribe: (URL, [Float], String?) async throws -> String,
        inserter: TextInserting,
        element: AXUIElement?,
        precomputedPrependSpace: Bool? = nil,
        onFocusLost: (() -> Void)? = nil,
        reuseDecision: StreamingReuse.Decision? = nil,
        readWav: (() -> [Float]?)? = nil
    ) async -> Outcome {
        // Too-short / dead-audio gates with the wav as arbiter — the same
        // `resolveGateSamples` call `finalizeRecording` makes.
        let gate = resolveGateSamples(memorySamples: samples, readWav: readWav ?? { nil })
        if let failure = gate.failure {
            return failure
        }
        let samples = gate.samples

        // Assemble prompt hints ONCE from the context-only Input (no raw text needed).
        // Both the T2.3 reuse path and the normal final-inference path pass this
        // precomputed prompt into TextPipeline.run via `.some(prompt)` so assemblePromptHints
        // is never called a second time inside run().
        let contextInput = promptContext ?? makeInput("")
        let prompt = TextPipeline.assemblePromptHints(input: contextInput)

        // T2.3 — short-utterance fast path vs final inference, via the SHARED resolveRaw
        // (the same call `finalizeRecording` makes). When reuse was approved the final
        // `whisper_full` call is skipped and the saved partial (segment-newline-collapsed)
        // is routed through the SAME TextPipeline the final pass uses. Accuracy: the reuse
        // gate caps post-pass audio growth at `defaultMaxSampleGrowthFraction`, so a
        // tail-word difference is possible within that bound.
        do {
            let (raw, reusedPartial) = try await resolveRaw(reuseDecision: reuseDecision) {
                try await transcribe(audioURL, samples, prompt)
            }
            let text = TextPipeline.run(makeInput(raw), precomputedPrompt: .some(prompt)).finalText

            if text.isEmpty {
                return .emptyTranscription
            }

            let (insertText, pasted) = insertFinalText(
                text, inserter: inserter, element: element,
                precomputedPrependSpace: precomputedPrependSpace, onFocusLost: onFocusLost)
            return reusedPartial
                ? .reusedPartial(insertedText: insertText, pasted: pasted)
                : .inserted(insertedText: insertText, pasted: pasted)
        } catch {
            let modelMissing: Bool
            if case TranscriptionEngineError.modelAssetsMissing = error {
                modelMissing = true
            } else {
                modelMissing = false
            }
            return .failed(modelMissing: modelMissing)
        }
    }

    /// Shared insertion tail used by BOTH the final-pass and the T2.3 reuse paths so they prepend
    /// space and insert identically. Returns the exact string handed to the inserter and the
    /// inserter's pasted/focus-lost result.
    private static func insertFinalText(
        _ text: String,
        inserter: TextInserting,
        element: AXUIElement?,
        precomputedPrependSpace: Bool?,
        onFocusLost: (() -> Void)?
    ) -> (insertText: String, pasted: Bool) {
        // T2.2: use the precomputed answer when available (derived from cursor context captured at
        // record-start, off the main thread — no AX query, no semaphore). Fall back to the
        // AX-backed shouldPrependSpace only when no precomputed value is available.
        let wantSpace = precomputedPrependSpace ?? inserter.shouldPrependSpace(before: element)
        let insertText = composeInsertText(text, prependSpace: wantSpace)
        let pasted = inserter.insert(text: insertText, refocusing: element, onFocusLost: onFocusLost)
        return (insertText, pasted)
    }
}
