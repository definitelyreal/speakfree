// ai-suggestion:unverified · Claude · 2026-09-22
import FluidAudio
import XCTest
@testable import SpeakFreeLib

/// Regression tests for two crashes on 2026-09-22 (Pacific time).
final class EngineTeardownCrashTests: XCTestCase {

    /// 10:07pm PT app crash: the last reference to a WhisperEngine was dropped inside a block
    /// running on its own engineQueue, and deinit's `engineQueue.sync` trapped
    /// ("dispatch_sync called on queue already owned by current thread"). Before the fix this
    /// test kills the test process with SIGTRAP instead of failing.
    func testWhisperEngineReleasedOnItsOwnQueueDoesNotTrap() {
        var engine: WhisperEngine? = WhisperEngine()
        weak var weakEngine = engine
        let gate = DispatchSemaphore(value: 0)
        let ran = expectation(description: "queued block ran")

        engine!.enqueueOnEngineQueueForTesting { [engine] in
            gate.wait()          // hold the queue until the test has dropped its reference
            _ = engine           // this block now owns the only strong reference
            ran.fulfill()
        }
        engine = nil
        XCTAssertNotNil(weakEngine, "the queued block should still own the engine")
        gate.signal()
        wait(for: [ran], timeout: 5)

        // The block (and with it the engine) is released right after it returns, on engineQueue.
        let deadline = Date().addingTimeInterval(5)
        while weakEngine != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(weakEngine, "engine should deinit on its own queue without trapping")
    }

    /// Releasing on some other thread still takes the normal synchronous path.
    func testWhisperEngineReleasedOffQueueStillDeinits() {
        var engine: WhisperEngine? = WhisperEngine()
        weak var weakEngine = engine
        XCTAssertFalse(engine!.isLoaded)
        engine = nil
        XCTAssertNil(weakEngine)
    }

    /// 9:34pm PT CLI crash: FluidAudio's debug-only assert(speechPadding <= minSpeechDuration)
    /// in VadSegmentationConfig.init trapped every debug build of `speakfree process`. Tests
    /// run as a debug build, so building the config here exercises that assert.
    func testEndpointingConfigBuildsInDebugWithShippedValues() {
        let config = ParakeetEngine.endpointingSegmentationConfig
        XCTAssertEqual(config.minSpeechDuration, 0.15)
        XCTAssertEqual(config.minSilenceDuration, 0.75)
        XCTAssertTrue(config.maxSpeechDuration.isInfinite)
        XCTAssertEqual(config.speechPadding, 0.20, "padding must stay at the shipped 0.20 s")
    }
}
