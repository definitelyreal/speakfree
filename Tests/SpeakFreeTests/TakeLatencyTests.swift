// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
//
// Speed loop step 1: the per-take `Latency:` line and the post-release wait summary.
// `scripts/latency-report.py` parses the field names asserted here, so a rename must fail a test.

import XCTest
@testable import SpeakFreeLib

final class TakeLatencyTests: XCTestCase {

    func testLogLineCarriesEveryStageInOrder() {
        var t = TakeLatency(keyRelease: 100.0)
        t.finalizeStart = 100.09
        t.gateEnd = 100.10
        t.inferStart = 100.11
        t.inferEnd = 100.36
        t.pipelineEnd = 100.365
        t.persistEnd = 100.385
        t.insertEnd = 100.41
        t.postBuffer = PostBufferOutcome(waitedMs: 90, extended: false, maxTrailingRMS: 0.004, releaseSample: 1600)
        let line = t.logLine(chars: 44, audioSeconds: 3.8, engine: "parakeet")
        XCTAssertEqual(line,
            "Latency: total=0.410 wait=0.090 stop=0.010 queue=0.010 infer=0.250 text=0.005 "
            + "save=0.020 insert=0.025 ext=no tailRMS=0.0040 cold=no preload=no audio=3.80 chars=44 engine=parakeet")
    }

    func testMissingStagesPrintNaAndTotalFallsBackToLastMark() {
        var t = TakeLatency(keyRelease: 10.0)
        t.finalizeStart = 11.2
        t.gateEnd = 11.21
        t.inferStart = 11.21
        t.inferEnd = 12.0
        t.pipelineEnd = 12.01
        t.persistEnd = 12.05
        t.coldLoad = true
        t.preloadStartedAtPress = true
        t.postBuffer = PostBufferOutcome(waitedMs: 1200, extended: true, maxTrailingRMS: 0.031, releaseSample: 0)
        let line = t.logLine(chars: 0, audioSeconds: 1.0, engine: "whisper")
        XCTAssertTrue(line.contains("total=2.050 "), line)
        XCTAssertTrue(line.contains("insert=na "), line)
        XCTAssertTrue(line.contains("ext=yes tailRMS=0.0310 cold=yes preload=yes"), line)
    }

    /// Normal takes write sidecars after insertion: no persist mark, insert timed from the
    /// end of the text pipeline, save reported as not on the path.
    func testSidecarsAfterInsertionTimeInsertFromPipelineEnd() {
        var t = TakeLatency(keyRelease: 0)
        t.finalizeStart = 0.1
        t.gateEnd = 0.1
        t.inferStart = 0.1
        t.inferEnd = 0.3
        t.pipelineEnd = 0.31
        t.insertEnd = 0.35
        let line = t.logLine(chars: 3, audioSeconds: 1, engine: "parakeet")
        XCTAssertTrue(line.contains("save=na insert=0.040 "), line)
        XCTAssertTrue(line.hasPrefix("Latency: total=0.350 "), line)
    }

    func testClockGoingBackwardsNeverPrintsNegative() {
        var t = TakeLatency(keyRelease: 5.0)
        t.finalizeStart = 4.9
        XCTAssertTrue(t.logLine(chars: 1, audioSeconds: 1, engine: "x").contains("wait=0.000"))
    }

    func testSummarizeFlagsExtensionOnlyForSpeechEnergyTail() {
        let quiet = [Float](repeating: 0.005, count: 16_000 / 10)   // 100 ms of room tone
        let q = PostBufferOutcome.summarize(trailingSamples: quiet, waitedMs: 90, releaseSample: 42)
        XCTAssertFalse(q.extended)
        XCTAssertEqual(q.releaseSample, 42)
        XCTAssertEqual(q.maxTrailingRMS, 0.005, accuracy: 1e-6)

        var voiced = quiet
        voiced.append(contentsOf: [Float](repeating: 0.05, count: 480))  // one 30 ms voiced window
        let v = PostBufferOutcome.summarize(trailingSamples: voiced, waitedMs: 1200, releaseSample: 0)
        XCTAssertTrue(v.extended)
        XCTAssertEqual(v.maxTrailingRMS, 0.05, accuracy: 1e-4)
    }

    func testSummarizeOfEmptyTailIsNotExtended() {
        let e = PostBufferOutcome.summarize(trailingSamples: [], waitedMs: 220, releaseSample: 7)
        XCTAssertFalse(e.extended)
        XCTAssertEqual(e.maxTrailingRMS, 0)
    }

    func testMetaRecordsReleasePointAndOldSidecarsStillDecode() throws {
        let meta = RecordingStore.RecordingMeta(
            appVersion: "t", engine: "parakeet", model: "m", inputDevice: nil, date: "d",
            durationSeconds: 1, transcriptChars: 1,
            postBuffer: PostBufferOutcome(waitedMs: 93.27, extended: true, maxTrailingRMS: 0.03, releaseSample: 16_000))
        let data = try JSONEncoder().encode(meta)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["keyReleaseSample"] as? Int, 16_000)
        XCTAssertEqual(json["postBufferWaitMs"] as? Double, 93.3)
        XCTAssertEqual(json["postBufferExtended"] as? Bool, true)

        let old = #"{"appVersion":"1.7.1","engine":"whisper","model":"m","date":"d","durationSeconds":1,"transcriptChars":2}"#
        let decoded = try JSONDecoder().decode(RecordingStore.RecordingMeta.self, from: Data(old.utf8))
        XCTAssertNil(decoded.keyReleaseSample)
        XCTAssertNil(decoded.postBufferWaitMs)
        XCTAssertNil(decoded.postBufferExtended)
    }

    func testIdleDescriptionHandlesNeverUsedModel() {
        XCTAssertEqual(WhisperEngine.idleDescription(.infinity), "never used")
        XCTAssertEqual(WhisperEngine.idleDescription(61.9), "61s")
    }
}
