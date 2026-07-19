// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.1 — Unit tests for the PURE adaptive-post-buffer decision (PostBufferPolicy).
// Three named scenarios from the plan: silence-immediately, speech-until-release,
// speech-past-release — plus cap / windowing boundaries. No audio I/O, no clock.
//
// These assertions are written to depend ONLY on the policy's load-bearing contract:
//   * Silence (RMS clearly below threshold) accumulates; speech (clearly above) resets the run.
//   * Once `silenceNeededMs` of CONTIGUOUS silence is reached, stop at that elapsed time (< cap).
//   * Continuous speech / never enough trailing silence → fall back to the 220ms cap.
//   * The cap is never exceeded.
// They deliberately avoid the exact-threshold boundary and the "ran out of windows mid-silence"
// edge so the suite is robust to either tie-break choice.

import XCTest
@testable import SpeakFreeLib

final class PostBufferTests: XCTestCase {

    private let windowMs = 30.0
    private let cap = PostBufferPolicy.defaultCapMs              // 220 (retuned 2026-07-19)
    private let needMs = PostBufferPolicy.defaultSilenceNeededMs // 90 (retuned 2026-07-19)
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
    /// window and 90ms needed, the 3rd silent window completes the run → wait 3 × 30 = 90ms,
    /// FAR below the 220ms cap. This is the core latency win.
    func test_silenceImmediately_stopsAtSilenceTarget_wellUnderCap() {
        let w = windows([(silent, 20)])  // 600ms of pure silence available
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, needMs, accuracy: 0.001)
        XCTAssertLessThan(wait, cap)
    }

    // MARK: - Case 2: speech up until release, then silence

    /// Speaker was still talking at release (first windows are speech), then trails into silence.
    /// We must NOT stop during speech, and must stop once 90ms of contiguous silence accrues.
    /// 3 speech windows (90ms) then plenty of silence → the silence run completes at 90 + 90 =
    /// 180ms (well within the cap; silence supply is ample so the result is unambiguous).
    func test_speechUntilRelease_thenSilence_stopsAfterTrailingSilence() {
        let w = windows([(speech, 3), (silent, 20)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, 180.0, accuracy: 0.001)
        XCTAssertLessThan(wait, cap)
    }

    // MARK: - Case 3: speech continuing past release (clipping guard)

    /// Speaker is mid-word and keeps producing energy through the whole observation — we never
    /// accumulate 90ms of contiguous silence, so we fall back to the hard cap (220ms). This is the
    /// last-word-clipping guard: when in doubt, wait the full amount.
    func test_speechPastRelease_neverSilent_fallsBackToCap() {
        let w = windows([(speech, 40)])  // 1200ms of continuous speech
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }

    /// Speech with brief dips that never reach 90ms contiguous silence before the cap → cap.
    func test_speechWithShortGaps_underTarget_fallsBackToCap() {
        // speech, 60ms gap (<90), speech, 60ms gap … never 90 contiguous, runs past the cap.
        let w = windows([(speech, 2), (silent, 2), (speech, 2), (silent, 2),
                         (speech, 2), (silent, 2), (speech, 2), (silent, 2)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }

    // MARK: - Cap boundary

    /// Silence whose run only completes AFTER the cap → the cap wins. 9 speech windows (270ms)
    /// already exceed the 220ms cap outright, so the trailing silence never gets scored — we hit
    /// the cap mid-walk (would-be completion 270 + 90 = 360ms is moot).
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
    /// 90 = 120ms.
    func test_shortSpeechThenSilence_stopsAt120() {
        let w = windows([(speech, 1), (silent, 20)])
        let wait = PostBufferPolicy.decideWaitMs(windowRMS: w, windowMs: windowMs)
        XCTAssertEqual(wait, 120.0, accuracy: 0.001)
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
    /// 220ms cap. 250ms of trailing silence = ~8 whole 30ms windows ≥ the 3 needed for 90ms, so the
    /// silence run completes regardless of partial-window handling — machine-independent proof.
    func test_trailingSamples_realisticSilence_beatsFlatCap() {
        let speechSamples = Array(repeating: Float(0.25), count: 16_000 * 2)
        let silentSamples = Array(repeating: Float(0.0), count: Int(16_000 * 0.25))
        // The runtime scores only the tail it actually polls (last ~cap ms): take the last 220ms.
        let all = speechSamples + silentSamples
        let tail = Array(all.suffix(Int((cap / 1000.0) * 16_000.0)))
        let wait = PostBufferPolicy.decideWaitMs(trailingSamples: tail, windowMs: windowMs)
        XCTAssertLessThan(wait, cap, "trailing-silence clip should stop before the 220ms cap")
        XCTAssertGreaterThanOrEqual(wait, needMs, "must observe at least the silence target")
    }

    /// All-speech samples (no trailing silence) → cap (clipping guard at the sample level).
    func test_trailingSamples_allSpeech_fallsBackToCap() {
        let speechSamples = Array(repeating: Float(0.25), count: 16_000)  // 1s speech
        let wait = PostBufferPolicy.decideWaitMs(trailingSamples: speechSamples, windowMs: windowMs)
        XCTAssertEqual(wait, cap, accuracy: 0.001)
    }

    // MARK: - Retuned defaults tripwire (2026-07-19 A/B: 150→90 / 300→220)

    /// PIN the retuned constants so a silent revert to the old 150/300 fails loudly. The values were
    /// approved on the empirical A/B in POSTBUFFER-AB.md (n=5,583 census, ~0.04% voiced-tail
    /// regressions). If someone reverts these, this test — not a subtle latency drift — catches it.
    func test_retunedDefaults_arePinnedTo90And220() {
        XCTAssertEqual(PostBufferPolicy.defaultSilenceNeededMs, 90.0, accuracy: 0.0,
                       "silenceNeeded default must stay 90ms (retuned 2026-07-19); a revert to 150 is a regression")
        XCTAssertEqual(PostBufferPolicy.defaultCapMs, 220.0, accuracy: 0.0,
                       "cap default must stay 220ms (retuned 2026-07-19); a revert to 300 is a regression")
    }

    // MARK: - Monotonic-deadline stop guard (perf adjudication dispute #1)

    /// The live poll loop feeds monotonic elapsed time to `postBufferShouldFinalize`. It must stop
    /// when the policy's decided wait has elapsed OR the cap deadline is reached — and a congested
    /// runloop that fires a LATE tick (elapsed already well past the cap) must still stop, never
    /// wait a whole extra tick. It must NOT stop while both elapsed < decided and elapsed < cap.
    func test_postBufferDeadlineGuard_stopsAtDecidedOrCap_boundedByDeadline() {
        // Below both the decided wait and the cap → keep polling.
        XCTAssertFalse(PostBufferPolicy.postBufferShouldFinalize(elapsedMs: 60, decidedMs: 90, capMs: cap))
        // Decided wait reached before the cap → stop.
        XCTAssertTrue(PostBufferPolicy.postBufferShouldFinalize(elapsedMs: 90, decidedMs: 90, capMs: cap))
        // Policy still wants to wait (decided == cap, the clipping-guard fallback) but the cap
        // deadline is exactly reached → stop.
        XCTAssertTrue(PostBufferPolicy.postBufferShouldFinalize(elapsedMs: cap, decidedMs: cap, capMs: cap))
        // Congested runloop: a late tick lands far past the cap → stop immediately, do not overshoot
        // by yet another tick.
        XCTAssertTrue(PostBufferPolicy.postBufferShouldFinalize(elapsedMs: cap + 100, decidedMs: cap, capMs: cap))
        // Just under the cap with the fallback decided wait → not yet.
        XCTAssertFalse(PostBufferPolicy.postBufferShouldFinalize(elapsedMs: cap - 1, decidedMs: cap, capMs: cap))
    }
}
