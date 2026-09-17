// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
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
