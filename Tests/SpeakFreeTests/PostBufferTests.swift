// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.1 — Unit tests for the PURE adaptive-post-buffer decision (PostBufferPolicy).
// Three named scenarios from the plan: silence-immediately, speech-until-release,
// speech-past-release — plus cap / windowing boundaries. No audio I/O, no clock.
//
// These assertions are written to depend ONLY on the policy's load-bearing contract:
//   * Silence (RMS clearly below threshold) accumulates; speech (clearly above) resets the run.
//   * Once `silenceNeededMs` of CONTIGUOUS silence is reached, stop at that elapsed time (< cap).
//   * Continuous speech / never enough trailing silence → fall back to the 300ms cap.
//   * The cap is never exceeded.
// They deliberately avoid the exact-threshold boundary and the "ran out of windows mid-silence"
// edge so the suite is robust to either tie-break choice.

import XCTest
@testable import SpeakFreeLib

final class PostBufferTests: XCTestCase {

    private let windowMs = 30.0
    private let cap = PostBufferPolicy.defaultCapMs              // 300
    private let needMs = PostBufferPolicy.defaultSilenceNeededMs // 150
    private let speech: Float = 0.2   // well above the 0.01 threshold
    private let silent: Float = 0.0   // well below threshold

    /// Build a flat window-RMS array from (value, count) runs.
    private func windows(_ runs: [(Float, Int)]) -> [Float] {
        var out: [Float] = []
        for (v, n) in runs { out.append(contentsOf: Array(repeating: v, count: n)) }
        return out
    }

    // MARK: - Case 1: silence immediately after release

    /// Speaker went silent before lifting the key — every trailing window is silent. With a 30ms
    /// window and 150ms needed, the 5th silent window completes the run → wait 5 × 30 = 150ms,
    /// FAR below the 300ms cap. This is the core latency win.
    func test_silenceImmediately_stopsAtSilenceTarget_wellUnderCap() {
        let w = windows([(silent, 20)])  // 600ms of pure silence available
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, needMs, accuracy: 0.001)
        XCTAssertLessThan(wait, cap)
    }

    // MARK: - Case 2: speech up until release, then silence

    /// Speaker was still talking at release (first windows are speech), then trails into silence.
    /// We must NOT stop during speech, and must stop once 150ms of contiguous silence accrues.
    /// 3 speech windows (90ms) then plenty of silence → the silence run completes at 90 + 150 =
    /// 240ms (well within the cap; silence supply is ample so the result is unambiguous).
    func test_speechUntilRelease_thenSilence_stopsAfterTrailingSilence() {
        let w = windows([(speech, 3), (silent, 20)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, 240.0, accuracy: 0.001)
        XCTAssertLessThan(wait, cap)
    }

    // MARK: - Case 3: speech continuing past release (clipping guard)

    /// Speaker is mid-word and keeps producing energy through the whole observation — we never
    /// accumulate 150ms of contiguous silence, so we fall back to the hard cap (300ms). This is the
    /// last-word-clipping guard: when in doubt, wait the full old amount.
    func test_speechPastRelease_neverSilent_fallsBackToCap() {
        let w = windows([(speech, 40)])  // 1200ms of continuous speech
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }

    /// Speech with brief dips that never reach 150ms contiguous silence before the cap → cap.
    func test_speechWithShortGaps_underTarget_fallsBackToCap() {
        // speech, 90ms gap (<150), speech, 90ms gap … never 150 contiguous, runs past the cap.
        let w = windows([(speech, 2), (silent, 3), (speech, 2), (silent, 3),
                         (speech, 2), (silent, 3), (speech, 2), (silent, 3)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }

    // MARK: - Cap boundary

    /// Silence whose run only completes AFTER the cap → the cap wins. 9 speech windows (270ms)
    /// then silence: the run would complete at 270 + 150 = 420ms > 300; we hit the cap mid-walk.
    func test_lateSilence_capWinsOverTarget() {
        let w = windows([(speech, 9), (silent, 20)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }

    /// Empty window stream → no trailing audio observed → fall back to cap (never clip unseen tail).
    func test_noWindows_fallsBackToCap() {
        XCTAssertEqual(PostBufferPolicy.decideWaitMs(windowRMS: [], windowMs: windowMs),
                       cap, accuracy: 0.001)
    }

    /// Silence after a longer lead-in still resolves before the cap, proving the early-stop is the
    /// silence-completion time, not a fixed value. 1 speech window (30ms) + ample silence → 30 +
    /// 150 = 180ms.
    func test_shortSpeechThenSilence_stopsAt180() {
        let w = windows([(speech, 1), (silent, 20)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, 180.0, accuracy: 0.001)
        XCTAssertLessThan(wait, cap)
    }

    // MARK: - Threshold: clearly-silent vs clearly-speech (no boundary tie-break)

    /// A clearly-silent level (≪ threshold) reads as silence; a clearly-loud level (≫ threshold)
    /// reads as speech. (The exact-threshold boundary is intentionally not asserted.)
    func test_clearlySilentVsClearlySpeech() {
        let quiet = windows([(0.001, 20)])   // ≪ 0.01 → silence
        XCTAssertEqual(PostBufferPolicy.decideWaitMs(windowRMS: quiet, windowMs: windowMs),
                       needMs, accuracy: 0.001)
        let loud = windows([(0.2, 40)])      // ≫ 0.01 → speech → cap
        XCTAssertEqual(PostBufferPolicy.decideWaitMs(windowRMS: loud, windowMs: windowMs),
                       cap, accuracy: 0.001)
    }

    // MARK: - rms helper

    func test_rms_ofSilence_isZero() {
        XCTAssertEqual(PostBufferPolicy.rms(ArraySlice([0, 0, 0] as [Float])), 0, accuracy: 1e-7)
    }

    func test_rms_ofConstant_isMagnitude() {
        XCTAssertEqual(PostBufferPolicy.rms(ArraySlice([0.5, 0.5, 0.5, 0.5] as [Float])), 0.5, accuracy: 1e-6)
    }

    func test_rms_ofEmpty_isZero() {
        XCTAssertEqual(PostBufferPolicy.rms(ArraySlice([] as [Float])), 0, accuracy: 1e-7)
    }

    // MARK: - windowRMSValues (whole-window split; partial-window handling not asserted)

    func test_windowRMSValues_wholeWindows_computesPerWindowRMS() {
        // 16kHz, 30ms window = 480 samples. 960 samples → exactly two WHOLE windows.
        let loud = Array(repeating: Float(0.3), count: 480)
        let quiet = Array(repeating: Float(0.0), count: 480)
        let rmss = PostBufferPolicy.windowRMSValues(samples: loud + quiet, windowSamples: 480)
        XCTAssertEqual(rmss.count, 2)
        XCTAssertEqual(rmss[0], 0.3, accuracy: 1e-5)
        XCTAssertEqual(rmss[1], 0.0, accuracy: 1e-6)
    }

    func test_windowRMSValues_emptyInput_isEmpty() {
        XCTAssertTrue(PostBufferPolicy.windowRMSValues(samples: [], windowSamples: 480).isEmpty)
    }

    // MARK: - trailingSamples convenience (the API AppDelegate + harness call)

    /// 2s speech + 250ms trailing silence at 16kHz: the convenience overload resolves well under the
    /// 300ms cap. 250ms of trailing silence = ~8 whole 30ms windows ≥ the 5 needed for 150ms, so the
    /// silence run completes regardless of partial-window handling — machine-independent proof.
    func test_trailingSamples_realisticSilence_beatsFlatCap() {
        let speechSamples = Array(repeating: Float(0.25), count: 16_000 * 2)
        let silentSamples = Array(repeating: Float(0.0), count: Int(16_000 * 0.25))
        // The runtime scores only the tail it actually polls (last ~cap ms): take the last 300ms.
        let all = speechSamples + silentSamples
        let tail = Array(all.suffix(Int((cap / 1000.0) * 16_000.0)))
        let wait = PostBufferPolicy.decideWaitMs(trailingSamples: tail, windowMs: windowMs)
        XCTAssertLessThan(wait, cap, "trailing-silence clip should stop before the 300ms cap")
        XCTAssertGreaterThanOrEqual(wait, needMs, "must observe at least the silence target")
    }

    /// All-speech samples (no trailing silence) → cap (clipping guard at the sample level).
    func test_trailingSamples_allSpeech_fallsBackToCap() {
        let speechSamples = Array(repeating: Float(0.25), count: 16_000)  // 1s speech
        let wait = PostBufferPolicy.decideWaitMs(trailingSamples: speechSamples, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }
}
