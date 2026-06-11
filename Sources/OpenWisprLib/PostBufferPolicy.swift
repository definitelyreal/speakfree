// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.1 — Adaptive post-buffer.
//
// The app keeps recording for a short window AFTER the dictation key is released, so the tail of
// the last word (still sitting in an AVAudioEngine buffer) isn't clipped. Historically this was a
// FLAT 300 ms wait applied to EVERY dictation — a tax paid even when the speaker had already gone
// silent before lifting the key.
//
// This file is the PURE decision: "given the RMS of each fixed-length window of trailing audio,
// how long should I keep recording before finalizing?" It has no I/O, no audio framework, no clock
// — just arithmetic over `[Float]` window-RMS values — so it is exhaustively unit-testable
// (silence-immediately / speech-until-release / speech-past-release). AppDelegate drives it by
// chopping the post-release audio into windows and polling `decideWaitMs`; the perf harness drives
// it over fixture tails to measure the latency win.
//
// Reuses the SAME RMS notion the audio tap already computes (AudioRecorder.handleAudioBuffer:
// sqrtf(Σx² / n)) so "silence" here means the same thing the visualizer + dead-audio check mean.

import Foundation

/// Pure policy for the adaptive post-key-release buffer.
///
/// Decision rule (cap-bounded, silence-terminated):
///   * Walk the trailing-audio windows in capture order.
///   * A window is "silent" when its RMS is at or below `silenceThreshold` (`≤`); a window exactly
///     at the threshold counts as silence.
///   * Stop as soon as a CONTIGUOUS run of silent windows reaches `silenceNeededMs` of audio —
///     return the elapsed time up to and including the window that completed that run.
///   * Never wait longer than `capMs` (the old flat behavior is the worst case — never worse).
///   * If silence is observed from the very first window, the wait collapses toward
///     `silenceNeededMs` instead of the full cap.
///   * If the windows run out before a full silence run (or before the cap), fall back to `capMs` —
///     the last-word-clipping guard: when in doubt, wait the full old amount. (Live: the caller
///     keeps polling as more windows arrive until silence is met or the cap is hit.)
public enum PostBufferPolicy {

    /// Defaults locked by PLAN T2.1: stop on ~150 ms trailing silence, hard cap 300 ms.
    public static let defaultSilenceNeededMs: Double = 150.0
    public static let defaultCapMs: Double = 300.0

    /// Default poll/window cadence (ms). The live runtime polls the recorder at this grain.
    public static let defaultWindowMs: Double = 30.0

    /// Default RMS silence threshold. Chosen well above the dead-audio floor (AppDelegate uses
    /// 0.0001 to detect a *dead engine*) but below normal speech energy (the visualizer treats
    /// ~0.15 RMS as full-scale). 0.01 ≈ −40 dBFS: room tone / breath passes as silence, an actual
    /// trailing syllable does not. The rule is `≤`: a window AT the threshold counts as silence.
    public static let defaultSilenceThreshold: Float = 0.01

    /// Decide how long (ms) to keep recording after key release, given per-window RMS.
    ///
    /// - Parameters:
    ///   - windowRMS: RMS of each trailing-audio window, in capture order (oldest → newest). Each
    ///     window represents `windowMs` of audio. An empty array means no trailing audio was
    ///     captured/observed yet → wait the full cap (conservative: don't clip what we haven't seen).
    ///   - windowMs: Duration each window represents, in milliseconds (> 0).
    ///   - silenceThreshold: RMS at or below which a window counts as silent.
    ///   - silenceNeededMs: Contiguous trailing silence required to stop early.
    ///   - capMs: Absolute upper bound on the wait (the legacy flat value).
    /// - Returns: Milliseconds to wait, in `[0, capMs]`. Always ≤ `capMs`.
    public static func decideWaitMs(
        windowRMS: [Float],
        windowMs: Double,
        silenceThreshold: Float = defaultSilenceThreshold,
        silenceNeededMs: Double = defaultSilenceNeededMs,
        capMs: Double = defaultCapMs
    ) -> Double {
        precondition(windowMs > 0, "windowMs must be positive")

        // No trailing audio observed → fall back to the cap (never clip unseen tail).
        guard !windowRMS.isEmpty else { return capMs }

        // Windows needed to constitute `silenceNeededMs` of contiguous silence.
        let windowsNeeded = Int((silenceNeededMs / windowMs).rounded(.up))
        // A zero/sub-window silence requirement still needs at least one silent window to act on.
        let needed = max(1, windowsNeeded)

        var contiguousSilent = 0
        var elapsedMs = 0.0

        for rms in windowRMS {
            elapsedMs += windowMs
            // Reached the cap mid-walk: stop now, clamped to the cap.
            if elapsedMs >= capMs { return capMs }

            if rms <= silenceThreshold {
                contiguousSilent += 1
                if contiguousSilent >= needed {
                    // Enough trailing silence: stop early (clamped, defensively, to the cap).
                    return min(elapsedMs, capMs)
                }
            } else {
                // Speech (above threshold) resets the silence run.
                contiguousSilent = 0
            }
        }

        // Ran out of observed windows before a full contiguous-silence run or the cap — fall back to
        // the cap (last-word-clipping guard: when in doubt, wait the full old amount). In live use
        // the caller keeps polling as more windows arrive until silence is met or the cap is hit.
        return capMs
    }

    /// Convenience: compute per-window RMS over a flat sample buffer, then decide.
    ///
    /// Splits `samples` into consecutive windows of `windowMs` of audio (a trailing partial window
    /// IS included — a short trailing-silence tail still counts toward the silence run), computes
    /// the RMS of each, and feeds `decideWaitMs`. Used by both the live recorder loop and the
    /// harness so they score IDENTICAL logic.
    public static func decideWaitMs(
        trailingSamples samples: [Float],
        sampleRate: Double = 16_000.0,
        windowMs: Double = defaultWindowMs,
        silenceThreshold: Float = defaultSilenceThreshold,
        silenceNeededMs: Double = defaultSilenceNeededMs,
        capMs: Double = defaultCapMs
    ) -> Double {
        let windowSamples = max(1, Int((windowMs / 1000.0) * sampleRate))
        let rms = windowRMSValues(samples: samples, windowSamples: windowSamples)
        // No whole window of trailing audio yet → nothing observed → fall back to the cap.
        guard !rms.isEmpty else { return capMs }
        return decideWaitMs(
            windowRMS: rms,
            windowMs: windowMs,
            silenceThreshold: silenceThreshold,
            silenceNeededMs: silenceNeededMs,
            capMs: capMs
        )
    }

    /// RMS of one window of samples — sqrtf(Σx² / n), the same RMS the audio tap and dead-audio
    /// check use. Empty → 0 (treated as silence).
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// RMS per consecutive `windowSamples`-frame window. A trailing partial window (shorter than
    /// `windowSamples`) IS included if it has any samples — a short trailing-silence tail still
    /// counts toward the silence run.
    public static func windowRMSValues(samples: [Float], windowSamples: Int) -> [Float] {
        guard windowSamples > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / windowSamples + 1)
        var i = 0
        while i < samples.count {
            let end = Swift.min(i + windowSamples, samples.count)
            out.append(rms(samples[i..<end]))
            i = end
        }
        return out
    }
}
