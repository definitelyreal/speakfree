// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
//
// Candidate W1: noise-relative post-release thresholds. The contract under test is the safety
// property that makes the candidate reviewable: thresholds are never below the fixed quiet-room
// values, so a quiet room decides exactly as before and a noisy room can only wait less.

import XCTest
@testable import SpeakFreeLib

final class PostBufferNoiseRelativeTests: XCTestCase {

    private let window = 480  // 30 ms at 16 kHz

    private func tone(_ rms: Float, windows: Int) -> [Float] {
        // Alternating +/-rms has exactly that RMS.
        (0..<(windows * window)).map { $0 % 2 == 0 ? rms : -rms }
    }

    func testQuietRoomKeepsFixedThresholds() {
        let floor = PostBufferPolicy.noiseFloor(preReleaseSamples: tone(0.002, windows: 50))
        XCTAssertEqual(floor, 0.002, accuracy: 1e-5)
        XCTAssertEqual(PostBufferPolicy.noiseRelativeThresholds(noiseFloor: floor), PostBufferPolicy.fixedThresholds)
    }

    func testThresholdsNeverDropBelowFixedValues() {
        for f: Float in [0, 0.001, 0.004, 0.0066, 0.009, 0.013, 0.05, 0.2, -1, .nan, .infinity] {
            let t = PostBufferPolicy.noiseRelativeThresholds(noiseFloor: f)
            XCTAssertGreaterThanOrEqual(t.silence, PostBufferPolicy.defaultSilenceThreshold, "floor \(f)")
            XCTAssertGreaterThanOrEqual(t.speech, PostBufferPolicy.defaultSpeechThreshold, "floor \(f)")
            XCTAssertTrue(t.silence.isFinite && t.speech.isFinite, "floor \(f)")
        }
    }

    func testNoisyRoomScalesWithFloor() {
        let t = PostBufferPolicy.noiseRelativeThresholds(noiseFloor: 0.015)
        XCTAssertEqual(t.silence, 0.0225, accuracy: 1e-6)
        XCTAssertEqual(t.speech, 0.03, accuracy: 1e-6)
    }

    func testFloorIsLowPercentileSoSpeechDoesNotInflateIt() {
        // 500 ms pre-roll of room tone, then 2.5 s of loud speech.
        let samples = tone(0.004, windows: 17) + tone(0.15, windows: 83)
        XCTAssertEqual(PostBufferPolicy.noiseFloor(preReleaseSamples: samples), 0.004, accuracy: 1e-5)
    }

    func testEmptyOrSubWindowAudioGivesZeroFloor() {
        XCTAssertEqual(PostBufferPolicy.noiseFloor(preReleaseSamples: []), 0)
        XCTAssertEqual(PostBufferPolicy.noiseFloor(preReleaseSamples: [Float](repeating: 0.3, count: 100)), 0)
    }

    /// A fan at 0.022 RMS trips the fixed 0.02 speech bar and never counts as silence, so today's
    /// rule waits the full 1.2 s. Relative to its own floor the same tail is plain room tone.
    func testFanNoiseTailNoLongerExtends() {
        let fanTail = PostBufferPolicy.windowRMSValues(samples: tone(0.022, windows: 40), windowSamples: window)
        let fixed = PostBufferPolicy.decideWaitMs(windowRMS: fanTail, windowMs: 30)
        XCTAssertEqual(fixed, PostBufferPolicy.defaultExtendedCapMs)

        let t = PostBufferPolicy.noiseRelativeThresholds(noiseFloor: 0.02)
        let relative = PostBufferPolicy.decideWaitMs(
            windowRMS: fanTail, windowMs: 30, silenceThreshold: t.silence, speechThreshold: t.speech)
        XCTAssertEqual(relative, PostBufferPolicy.defaultSilenceNeededMs, accuracy: 30)
    }

    /// A word spoken across the release in that same noisy room still clears 2x the floor and
    /// still extends; the wait ends when the word does.
    func testRealTrailingWordInNoiseStillExtends() {
        let t = PostBufferPolicy.noiseRelativeThresholds(noiseFloor: 0.02)
        let tail = PostBufferPolicy.windowRMSValues(
            samples: tone(0.08, windows: 20) + tone(0.02, windows: 10), windowSamples: window)
        let relative = PostBufferPolicy.decideWaitMs(
            windowRMS: tail, windowMs: 30, silenceThreshold: t.silence, speechThreshold: t.speech)
        XCTAssertEqual(relative, 20 * 30 + PostBufferPolicy.defaultSilenceNeededMs, accuracy: 1)
    }

    /// Equal-or-shorter property over a sweep: for any floor, the relative decision never waits
    /// longer than the fixed one on the same tail.
    func testRelativeDecisionNeverWaitsLonger() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let tail = (0..<Int.random(in: 1...45, using: &rng)).map { _ in Float.random(in: 0...0.1, using: &rng) }
            let floor = Float.random(in: 0...0.06, using: &rng)
            let t = PostBufferPolicy.noiseRelativeThresholds(noiseFloor: floor)
            let fixed = PostBufferPolicy.decideWaitMs(windowRMS: tail, windowMs: 30)
            let relative = PostBufferPolicy.decideWaitMs(
                windowRMS: tail, windowMs: 30, silenceThreshold: t.silence, speechThreshold: t.speech)
            XCTAssertLessThanOrEqual(relative, fixed, "tail \(tail) floor \(floor)")
        }
    }
}
