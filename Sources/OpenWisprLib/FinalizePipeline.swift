// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
import ApplicationServices
import Foundation

/// Testable core of `AppDelegate.finalizeRecording`: the record → transcribe → insert
/// decision logic, lifted out of AppDelegate so it can be driven by a FakeEngine + a
/// MockInserter under XCTest without AppKit, a real audio engine, or a live cursor.
///
/// AppDelegate's `finalizeRecording` keeps every UI / RecordingStore / status-bar side
/// effect; it delegates ONLY the pure pipeline decisions to this type so the observable
/// app behavior is byte-identical to the inline version.
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
    }

    /// Pure RMS used by the silence guard. Matches `finalizeRecording`'s inline computation.
    public static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrtf(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    }

    /// Run the finalize core.
    ///
    /// - Parameters:
    ///   - samples: captured audio (16kHz mono Float32), as `finalizeRecording` sees it.
    ///   - audioURL: passed through to `transcribe`.
    ///   - makeInput: builds the TextPipeline.Input for a given raw string — identical closure
    ///     shape to the one in `finalizeRecording`, so prompt-hints + post-processing run the
    ///     same way the app runs them.
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
    /// - Returns: the `Outcome` describing which branch ran.
    @discardableResult
    public static func run(
        samples: [Float],
        audioURL: URL,
        makeInput: (String) -> TextPipeline.Input,
        transcribe: (URL, [Float], String?) async throws -> String,
        inserter: TextInserting,
        element: AXUIElement?,
        precomputedPrependSpace: Bool? = nil,
        onFocusLost: (() -> Void)? = nil
    ) async -> Outcome {
        // Too-short guard (accidental tap).
        if samples.count < minSamples {
            return .tooShort(sampleCount: samples.count)
        }

        // Dead-audio / silence guard.
        let level = rms(of: samples)
        if level < silenceRMSThreshold {
            return .silent(rms: level)
        }

        do {
            // Prompt hints are assembled from an empty raw first (matches finalizeRecording),
            // then the real transcription is re-run through TextPipeline.
            let prompt = TextPipeline.assemblePromptHints(input: makeInput(""))
            let raw = try await transcribe(audioURL, samples, prompt)
            let text = TextPipeline.run(makeInput(raw)).finalText

            if text.isEmpty {
                return .emptyTranscription
            }

            // T2.2: use the precomputed answer when available (derived from cursor context
            // captured at record-start, off the main thread — no AX query, no semaphore).
            // Fall back to the AX-backed shouldPrependSpace only when no precomputed value
            // is available (e.g. legacy callers or tests that omit the parameter).
            let wantSpace = precomputedPrependSpace ?? inserter.shouldPrependSpace(before: element)
            let insertText = wantSpace ? " " + text : text
            let pasted = inserter.insert(text: insertText, refocusing: element, onFocusLost: onFocusLost)
            return .inserted(insertedText: insertText, pasted: pasted)
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
}
