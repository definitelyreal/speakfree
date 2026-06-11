// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.3 — Reuse the last streaming partial for short utterances.
//
// When a user releases the hotkey very shortly after the live-preview ("streaming") pass last
// completed, AND the recording has barely grown since that pass, the already-computed streaming
// partial is (per the T2.3-PRE measurement: 0.000% word divergence on short clips under GREEDY
// sampling) text-identical to what a fresh FINAL inference would produce. In that window we can
// SKIP the redundant final `whisper_full` call and route the saved partial through the SAME
// TextPipeline post-processing the final pass uses — eliminating the final inference latency for
// short utterances at zero accuracy cost.
//
// This type is the PURE decision: it owns no app state, touches no engine, and is unit-testable
// headless. `AppDelegate.finalizeRecording` snapshots the live numbers and asks `decide(...)`.
//
// Kill-switch: gated by `config.reuseStreamingPartial` (FlexBool, default ON). When the flag is
// off — or any gate condition fails — the decision is `.runFinalInference` and behavior is
// byte-identical to pre-T2.3.

import Foundation

public enum StreamingReuse {

    /// Release must land within this many ms of the last streaming pass completing for the
    /// partial to be considered fresh enough to reuse. (PLAN T2.3: "release <300ms after the
    /// last streaming pass completed".)
    public static let defaultReleaseWithinMs: Double = 300.0

    /// The recording may have grown by at most this FRACTION of the streamed sample count since
    /// the last pass. (PLAN T2.3: "sample count grew <~10% since that pass".) More growth means
    /// meaningful new audio the streamed partial never saw → run the final pass.
    public static let defaultMaxSampleGrowthFraction: Double = 0.10

    /// The decision and, when reusing, the raw partial text to route through TextPipeline.
    public enum Decision: Equatable {
        /// Reuse the saved streaming partial (run it through TextPipeline instead of a fresh
        /// final inference). `rawPartial` is the exact engine string the last streaming pass
        /// returned — the caller feeds it to `makeInput(rawPartial)` → `TextPipeline.run`.
        case reusePartial(rawPartial: String)
        /// Run the normal final inference (flag off, no usable partial, stale, or grown too much).
        /// `reason` is a short machine-readable tag for diagnostics/tests.
        case runFinalInference(reason: Reason)
    }

    /// Why a final inference is being run instead of reusing the partial.
    public enum Reason: String, Equatable {
        case flagDisabled        // config.reuseStreamingPartial == false
        case noPartial           // no streaming pass ever completed (or empty partial)
        case stale               // release landed too long after the last streaming pass
        case grewTooMuch         // recording grew >maxFraction since the last streamed pass
        case noStreamedSamples   // last streamed sample count was ≤0 (can't compute growth)
    }

    /// A snapshot of the live streaming state captured at finalize time.
    public struct State: Equatable {
        /// Kill-switch: `config.reuseStreamingPartial?.value ?? true` — default ON.
        public let flagEnabled: Bool
        /// The raw engine text the LAST completed streaming pass returned (pre-TextPipeline).
        /// Empty / whitespace-only means "no usable partial".
        public let lastRawPartial: String
        /// The recorder sample count the last streaming pass was run over.
        public let lastStreamedSampleCount: Int
        /// `CFAbsoluteTime` when the last streaming pass COMPLETED.
        public let lastStreamCompletedAt: Double
        /// The recorder sample count at key-release (used to measure growth since the pass).
        public let sampleCountAtRelease: Int
        /// `CFAbsoluteTime` of key-release.
        public let keyReleaseAt: Double

        public init(flagEnabled: Bool,
                    lastRawPartial: String,
                    lastStreamedSampleCount: Int,
                    lastStreamCompletedAt: Double,
                    sampleCountAtRelease: Int,
                    keyReleaseAt: Double) {
            self.flagEnabled = flagEnabled
            self.lastRawPartial = lastRawPartial
            self.lastStreamedSampleCount = lastStreamedSampleCount
            self.lastStreamCompletedAt = lastStreamCompletedAt
            self.sampleCountAtRelease = sampleCountAtRelease
            self.keyReleaseAt = keyReleaseAt
        }
    }

    /// Pure gate. Returns `.reusePartial` only when EVERY condition holds:
    ///   1. the flag is on,
    ///   2. there is a non-empty saved partial,
    ///   3. the last streamed sample count is positive (so growth is computable),
    ///   4. release landed within `releaseWithinMs` of the pass completing, and
    ///   5. the recording grew by ≤ `maxGrowthFraction` of the streamed samples.
    /// Otherwise `.runFinalInference(reason:)`.
    public static func decide(
        _ state: State,
        releaseWithinMs: Double = defaultReleaseWithinMs,
        maxGrowthFraction: Double = defaultMaxSampleGrowthFraction
    ) -> Decision {
        guard state.flagEnabled else { return .runFinalInference(reason: .flagDisabled) }

        let trimmed = state.lastRawPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .runFinalInference(reason: .noPartial) }

        guard state.lastStreamedSampleCount > 0 else {
            return .runFinalInference(reason: .noStreamedSamples)
        }

        // Freshness: how long after the streaming pass completed did the key lift?
        let sinceStreamMs = (state.keyReleaseAt - state.lastStreamCompletedAt) * 1000.0
        // A negative value (release before the recorded completion — clock skew / reordering)
        // is treated as fresh (0). Only positive ages can be stale. A 1e-6ms epsilon absorbs the
        // floating-point noise of differencing two CFAbsoluteTimes so an exactly-at-cap release
        // (and sub-nanosecond rounding) still counts as fresh.
        guard sinceStreamMs <= releaseWithinMs + 1e-6 else {
            return .runFinalInference(reason: .stale)
        }

        // Growth: how much new audio arrived after the streamed pass?
        let grew = state.sampleCountAtRelease - state.lastStreamedSampleCount
        // If the recorder somehow shrank (shouldn't happen), growth is 0 → still fresh.
        let growthFraction = grew > 0
            ? Double(grew) / Double(state.lastStreamedSampleCount)
            : 0.0
        guard growthFraction <= maxGrowthFraction else {
            return .runFinalInference(reason: .grewTooMuch)
        }

        return .reusePartial(rawPartial: state.lastRawPartial)
    }
}
