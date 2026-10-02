// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
//
// Noise-relative, self-correcting gate on the synchronous sparse Whisper rescue.

import XCTest
@testable import SpeakFreeLib

final class SparseRescueGateTests: XCTestCase {
    private let window = 0.03

    /// Shape of a noisy-room take: 20 s held, ~1 s of words, room noise around 0.015 whose
    /// fluctuations clear the fixed 0.02 bar in ~60% of windows.
    private func noisyPauseTake() -> [Float] {
        var rms: [Float] = []
        for i in 0..<640 { rms.append(i % 5 < 2 ? 0.015 : 0.023) }   // room tone
        rms.append(contentsOf: [Float](repeating: 0.12, count: 35))   // ~1 s of speech
        return rms
    }

    func testNoisyPauseTakeSkipsTheSynchronousRescue() {
        let rms = noisyPauseTake()
        let fixedSpeech = Double(rms.filter { $0 >= 0.02 }.count) * window
        XCTAssertTrue(Transcriber.sparseRescueEligible(
            parakeetWordCount: 2, durationSeconds: 20.3, speechDurationSeconds: fixedSpeech),
            "precondition: the fixed bar calls this take sparse")
        let gate = SparseRescueGate()
        let floor = Transcriber.noiseFloorRMS(from: rms)
        let (decision, speech, ratio) = gate.decide(
            device: "MacBook Pro Microphone", parakeetWords: 2, durationSeconds: 20.3,
            windowRMS: rms, windowSeconds: window, noiseFloor: floor)
        XCTAssertEqual(decision, .skip(backgroundCheck: true))
        XCTAssertEqual(ratio, SparseRescueGate.initialRatio)
        XCTAssertEqual(speech, 35 * window, accuracy: 1e-9)
    }

    func testZeroWordTakesAlwaysRescue() {
        let (decision, _, _) = SparseRescueGate().decide(
            device: "x", parakeetWords: 0, durationSeconds: 20, windowRMS: noisyPauseTake(),
            windowSeconds: window, noiseFloor: 0.015)
        XCTAssertEqual(decision, .rescue)
    }

    func testQuietRoomDroppedSentenceStillRescues() {
        // 10 s of real speech, 2 words back: the dropped-sentence shape the rescue exists for.
        var rms = [Float](repeating: 0.002, count: 60)
        rms.append(contentsOf: [Float](repeating: 0.1, count: 333))
        let floor = Transcriber.noiseFloorRMS(from: rms)
        let (decision, speech, _) = SparseRescueGate().decide(
            device: "x", parakeetWords: 2, durationSeconds: 11.8, windowRMS: rms,
            windowSeconds: window, noiseFloor: floor)
        XCTAssertEqual(decision, .rescue)
        XCTAssertEqual(speech, 333 * window, accuracy: 1e-9)
    }

    func testRescueOutcomesMoveTheRatioWithinBounds() {
        let gate = SparseRescueGate()
        gate.recordRescue(device: "a", gained: false)
        XCTAssertEqual(gate.ratio(for: "a"), 2.5, accuracy: 1e-6)
        for _ in 0..<20 { gate.recordRescue(device: "a", gained: false) }
        XCTAssertEqual(gate.ratio(for: "a"), SparseRescueGate.maxRatio)
        for _ in 0..<20 { gate.recordRescue(device: "a", gained: true) }
        XCTAssertEqual(gate.ratio(for: "a"), SparseRescueGate.minRatio)
        XCTAssertEqual(gate.ratio(for: "b"), SparseRescueGate.initialRatio, "devices are independent")
    }

    func testBackgroundChecksAreDenseWhileLearningThenThin() {
        let gate = SparseRescueGate()
        let rms = noisyPauseTake()
        func skip() -> SparseRescueGate.Decision {
            gate.decide(device: "m", parakeetWords: 2, durationSeconds: 20, windowRMS: rms,
                        windowSeconds: window, noiseFloor: 0.015).decision
        }
        for _ in 0..<SparseRescueGate.learningChecks {
            XCTAssertEqual(skip(), .skip(backgroundCheck: true))
            gate.recordSkipCheck(device: "m", wouldHaveGained: false)
        }
        var checks = 0
        for _ in 0..<(SparseRescueGate.settledCheckInterval * 4) {
            if case .skip(true) = skip() { checks += 1 }
        }
        XCTAssertEqual(checks, 4)
    }

    func testMissedWordsInABackgroundCheckLowerTheRatioAndRestartLearning() {
        let gate = SparseRescueGate()
        for _ in 0..<3 { gate.recordSkipCheck(device: "m", wouldHaveGained: false) }
        gate.recordSkipCheck(device: "m", wouldHaveGained: true)
        XCTAssertEqual(gate.ratio(for: "m"), SparseRescueGate.initialRatio / SparseRescueGate.step, accuracy: 1e-6)
        let (decision, _, _) = gate.decide(
            device: "m", parakeetWords: 2, durationSeconds: 20, windowRMS: noisyPauseTake(),
            windowSeconds: window, noiseFloor: 0.015)
        XCTAssertEqual(decision, .skip(backgroundCheck: true), "learning restarted: check every skip")
    }

    func testGateFloorFallsBackToPrerollWhenSpeechDominates() {
        var rms = [Float](repeating: 0.002, count: 16)
        rms.append(contentsOf: [Float](repeating: 0.1, count: 400))
        XCTAssertEqual(Transcriber.noiseFloorRMS(from: rms), 0.1, "whole-take floor lands on speech")
        XCTAssertEqual(SparseRescueGate.gateNoiseFloor(windowRMS: rms, takeFloor: 0.1), 0.002)
        XCTAssertEqual(SparseRescueGate.gateNoiseFloor(windowRMS: [], takeFloor: 0.01), 0.01)
        XCTAssertEqual(SparseRescueGate.gateNoiseFloor(windowRMS: [0.05, 0.05], takeFloor: 0.004), 0.004)
    }

    func testSpeechSecondsNeverBelowTheFixedBar() {
        let rms: [Float] = [0.019, 0.02, 0.03]
        XCTAssertEqual(SparseRescueGate.speechSeconds(windowRMS: rms, windowSeconds: 1, noiseFloor: 0, ratio: 2), 2)
        XCTAssertEqual(SparseRescueGate.speechSeconds(windowRMS: rms, windowSeconds: 1, noiseFloor: .nan, ratio: 2), 2)
        XCTAssertEqual(SparseRescueGate.speechSeconds(windowRMS: rms, windowSeconds: 1, noiseFloor: 0.012, ratio: 2), 1)
    }
}
