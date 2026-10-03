// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-suggestion:unverified · session:unknown · 2026-10-02
import XCTest
@testable import SpeakFreeLib

final class CaptureTimelineTests: XCTestCase {
    private func packet(_ start: Int, _ count: Int, offset: Float = 0) -> CapturePacket {
        CapturePacket(start: Double(start) / 16_000, samples: (start..<(start + count)).map { Float($0) + offset })
    }

    func testDelayedAirPodsHandoverDoesNotRepeatOrLoseSamples() {
        var timeline = CaptureTimeline()
        var result = timeline.receiveBase(packet(0, 1600))
        // Bluetooth's first packet arrives late. Select it, but don't replay it.
        result += timeline.receiveSecondary(packet(0, 800))
        result += timeline.receiveBase(packet(1600, 1600))
        result += timeline.receiveSecondary(packet(800, 1200))
        result += timeline.receiveSecondary(packet(2000, 1200))
        XCTAssertEqual(result, (0..<3200).map(Float.init))
    }

    func testDisconnectUsesBufferedBuiltInTailAndRejectsOverlap() {
        var timeline = CaptureTimeline()
        var result = timeline.receiveBase(packet(0, 800))
        result += timeline.receiveSecondary(packet(400, 1200))
        result += timeline.receiveBase(packet(800, 1600))
        result += timeline.useBase()
        result += timeline.receiveBase(packet(2000, 1200))
        XCTAssertEqual(result, (0..<3200).map(Float.init))
    }

    func testStopFlushesTailStillInBluetoothTransit() {
        var timeline = CaptureTimeline()
        var result = timeline.receiveBase(packet(0, 800))
        result += timeline.receiveSecondary(packet(400, 800))
        result += timeline.receiveBase(packet(800, 800))
        result += timeline.flush()
        XCTAssertEqual(result, (0..<1600).map(Float.init))
        XCTAssertTrue(timeline.receiveSecondary(packet(800, 800)).isEmpty)
    }

    func testPreferredMicActuallyReplacesBaseSamples() {
        var timeline = CaptureTimeline()
        _ = timeline.receiveBase(packet(0, 800))
        XCTAssertEqual(timeline.receiveSecondary(packet(400, 800, offset: 10_000)), (800..<1200).map { Float($0) + 10_000 })
    }

    func testCommittedMappingCountsSamplesAcrossHolesAndClippedOverlap() {
        var timeline = CaptureTimeline()
        _ = timeline.receiveSecondary(packet(0, 16000))
        _ = timeline.receiveSecondary(packet(32000, 16000))
        _ = timeline.receiveSecondary(packet(40000, 16000)) // Only 8000 new samples.
        XCTAssertEqual(timeline.committedSamples(since: 0), 40000)
        XCTAssertEqual(timeline.committedSamples(since: 2), 24000)
        XCTAssertEqual(timeline.committedSamples(since: 3), 8000)
        XCTAssertNil(timeline.committedSamples(since: 1.5), "a boundary inside a missing interval is not a recorded index")
    }

    func testCommittedMappingTracksRewindAndReset() {
        var timeline = CaptureTimeline()
        _ = timeline.receiveSecondary(packet(0, 16000))
        _ = timeline.receiveSecondary(packet(32000, 16000))
        _ = timeline.receiveBase(packet(32000, 32000))
        XCTAssertEqual(timeline.rewind(to: 2).count, 32000)
        XCTAssertEqual(timeline.committedSamples(since: 0), 48000)
        XCTAssertEqual(timeline.committedSamples(since: 2), 32000)
        XCTAssertNil(timeline.committedSamples(since: 1.5))
        timeline.reset()
        XCTAssertNil(timeline.committedSamples(since: 0))
    }

    func testRewindCoverageAllowsUnalignedMicrophoneGrids() {
        for offset in [-0.5, -0.49, 0.49, 0.5] {
            var timeline = CaptureTimeline()
            let start = 12345.0
            let baseStart = start + offset / 16_000
            _ = timeline.receiveSecondary(CapturePacket(start: start, samples: [1]))
            for i in 0..<20 {
                _ = timeline.receiveBase(CapturePacket(start: baseStart + Double(i) / 10,
                                                       samples: Array(repeating: 0.25, count: 1600)))
            }
            let cursor = timeline.cursor
            XCTAssertTrue(timeline.canRewind(to: start, preservingThrough: start + 2), "offset \(offset)")
            XCTAssertEqual(timeline.cursor, cursor, "coverage inspection must not advance or rewind capture")
            let audio = timeline.rewind(to: start)
            XCTAssertLessThanOrEqual(abs(audio.count - 32000), 1, "only boundary-grid rounding is allowed")
        }
    }

    func testRewindCoverageRejectsEvenOneMissingInternalSample() {
        var timeline = CaptureTimeline()
        _ = timeline.receiveSecondary(packet(0, 1))
        _ = timeline.receiveBase(packet(0, 1600))
        _ = timeline.receiveBase(packet(1601, 1600))
        XCTAssertFalse(timeline.canRewind(to: 0, preservingThrough: 0.2))
        // rewind emits the whole suffix, so gaps after the requested end must fail too.
        XCTAssertFalse(timeline.canRewind(to: 0, preservingThrough: 0.05))
    }

    func testRewindCoverageDoesNotAccumulateRoundingAtRepeatedOverlaps() {
        var timeline = CaptureTimeline()
        _ = timeline.receiveSecondary(packet(0, 1))
        for i in 0..<20 {
            let start = Double(i) * (0.1 - 0.49 / 16_000)
            _ = timeline.receiveBase(CapturePacket(start: start, samples: Array(repeating: 0.25, count: 1600)))
        }
        XCTAssertFalse(timeline.canRewind(to: 0, preservingThrough: 1.9),
                       "rounding under half a sample per packet still duplicates multiple samples overall")
    }

    func testRewindCoverageRejectsLongLagAndGapWithoutChangingHistory() {
        let samples = Array(repeating: Float(0.25), count: 1600)
        for gap in [0.0, 1.0 / 16_000] {
            var timeline = CaptureTimeline()
            timeline.keepFrom = 0
            _ = timeline.receiveSecondary(packet(0, 1))
            for i in 0..<1799 {
                let start = Double(i) / 10 + (i >= 900 ? gap : 0)
                _ = timeline.receiveBase(CapturePacket(start: start, samples: samples))
            }
            let cursor = timeline.cursor, oldest = timeline.oldestHeld
            // Repeated late callbacks must not require a rewind/materialized waveform to
            // decide: both the trailing stream and the internal one-sample gap are refusals.
            for _ in 0..<100 {
                XCTAssertFalse(timeline.canRewind(to: 0, preservingThrough: 180))
                XCTAssertEqual(timeline.canRewind(to: 0, preservingThrough: 179), gap == 0)
            }
            XCTAssertEqual(timeline.cursor, cursor)
            XCTAssertEqual(timeline.oldestHeld, oldest)
        }
    }

    func testWrongRateIsRejectedBeforeAnySamplesAreAccepted() {
        var clock = CaptureClockGuard()
        for i in 0..<30 {
            // Frames really advance at 48k, but the driver labels them 24k.
            XCTAssertFalse(clock.accept(start: Double(i * 1024) / 48_000, frames: 1024, rate: 24_000))
        }
    }

    func testValidClockBecomesReadyAndRejectsAFormatJump() {
        var clock = CaptureClockGuard()
        XCTAssertFalse(clock.accept(start: 0, frames: 1024, rate: 24_000))
        XCTAssertFalse(clock.accept(start: 1024.0 / 24_000, frames: 1024, rate: 24_000))
        XCTAssertTrue(clock.accept(start: 2048.0 / 24_000, frames: 1024, rate: 24_000))
        XCTAssertFalse(clock.accept(start: 2560.0 / 24_000, frames: 1024, rate: 24_000))
    }
}
