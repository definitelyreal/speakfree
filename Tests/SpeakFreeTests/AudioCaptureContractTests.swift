// ai-suggestion:unverified · session:unknown · 2026-10-02
// Words-only adversarial contract tests. Authored without implementation, existing
// tests, diffs, or other reviewers. Synthetic samples only; no microphone claims.
import XCTest
@testable import SpeakFreeLib

final class AudioCaptureContractTests: XCTestCase {
    // Exact binary times avoid turning a semantic oracle into a rounding test.
    private let frames = 1_000
    private func time(_ slot: Int) -> Double { Double(slot) / 16 }
    private func audio(_ values: [Float]) -> [Float] {
        values.flatMap { Array(repeating: $0, count: frames) }
    }
    private func packet(_ slot: Int, _ values: [Float]) -> CapturePacket {
        CapturePacket(start: time(slot), samples: audio(values))
    }

    func testBaseOverlapAndRepeatedPacketNeverDuplicateCommittedSpeech() {
        var timeline = CaptureTimeline()
        var recording = timeline.receiveBase(packet(0, [1, 2]))
        recording += timeline.receiveBase(packet(1, [90, 3]))
        recording += timeline.receiveBase(packet(1, [90, 3]))
        recording += timeline.flush()
        XCTAssertEqual(recording, audio([1, 2, 3]))
        XCTAssertEqual(timeline.committedSamples(since: time(1)), 2 * frames)
    }

    func testUncoveredGapAddsNoSamplesAndCannotBeUsedAsAReplacementBoundary() {
        var timeline = CaptureTimeline()
        var recording = timeline.receiveBase(packet(0, [1]))
        recording += timeline.receiveBase(packet(3, [4, 5]))
        XCTAssertEqual(recording, audio([1, 4, 5]))
        XCTAssertEqual(timeline.committedSamples(since: time(0)), 3 * frames)
        XCTAssertNil(timeline.committedSamples(since: time(2)))
        XCTAssertEqual(timeline.committedSamples(since: time(3)), 2 * frames)
        XCTAssertEqual(timeline.committedSamples(since: time(4)), frames)
    }

    func testSecondaryOverlapPreservesPrefixAndSwitchBackAppendsOnlyNewBaseTail() {
        var timeline = CaptureTimeline()
        var recording = timeline.receiveBase(packet(0, [1, 2]))
        recording += timeline.receiveSecondary(packet(1, [90, 3, 4]))
        recording += timeline.receiveBase(packet(3, [80, 5]))
        recording += timeline.useBase()
        recording += timeline.flush()
        XCTAssertEqual(recording, audio([1, 2, 3, 4, 5]))
    }

    func testBufferedBaseFillsOnlyTheGapBetweenSecondaryPackets() {
        var timeline = CaptureTimeline()
        var recording = timeline.receiveSecondary(packet(0, [1]))
        recording += timeline.receiveBase(packet(0, [90, 2, 3, 80]))
        recording += timeline.receiveSecondary(packet(3, [4]))
        recording += timeline.flush()
        XCTAssertEqual(recording, audio([1, 2, 3, 4]))
    }

    func testIncompleteFallbackIsRejectedWithoutDestroyingOriginalSpeech() {
        // A missing middle and a missing tail are distinct incomplete fallbacks.
        for hasMiddleGap in [false, true] {
            var timeline = CaptureTimeline()
            timeline.keepFrom = time(0)
            var recording = timeline.receiveSecondary(packet(0, [1, 2, 3, 4]))
            recording += timeline.receiveBase(packet(0, [10]))
            if hasMiddleGap {
                recording += timeline.receiveBase(packet(2, [30, 40]))
            } else {
                recording += timeline.receiveBase(packet(1, [20, 30]))
            }
            let original = audio([1, 2, 3, 4])
            XCTAssertEqual(recording, original)
            let previousCursor = timeline.cursor
            let allowed = timeline.canRewind(to: time(0), preservingThrough: time(4))
            XCTAssertFalse(allowed, "Incomplete replacement must never authorize truncation")
            XCTAssertEqual(timeline.cursor, previousCursor, "Coverage query must not change capture state")
            XCTAssertEqual(timeline.committedSamples(since: time(0)), 4 * frames)
            // Model the caller's required guard, including the dangerous branch.
            if allowed, let suffix = timeline.committedSamples(since: time(0)) {
                recording.removeLast(suffix)
                recording += timeline.rewind(to: time(0))
            }
            XCTAssertEqual(recording, original)
            recording += timeline.receiveSecondary(packet(4, [5]))
            XCTAssertEqual(recording, audio([1, 2, 3, 4, 5]))
        }
    }

    func testReplacementAfterEarlierGapDiscardsRecordedSamplesNotWallClockDuration() throws {
        var timeline = CaptureTimeline()
        timeline.keepFrom = time(0)
        var recording = timeline.receiveBase(packet(0, [1]))
        recording += timeline.receiveSecondary(packet(3, [4, 5, 6]))
        recording += timeline.receiveBase(packet(4, [50, 60]))
        XCTAssertEqual(recording, audio([1, 4, 5, 6]))
        XCTAssertTrue(timeline.canRewind(to: time(4), preservingThrough: time(6)))
        let discard = try XCTUnwrap(timeline.committedSamples(since: time(4)))
        XCTAssertEqual(discard, 2 * frames)
        recording.removeLast(discard)
        recording += timeline.rewind(to: time(4))
        XCTAssertEqual(recording, audio([1, 4, 50, 60]))
        XCTAssertNil(timeline.committedSamples(since: time(2)))
    }

    func testPacketSplittingAndDuplicateDeliveryDoNotChangeSpeech() {
        let expected = audio([1, 2, 3, 4])
        for useSecondary in [false, true] {
            for partition in [[4], [1, 3], [2, 2], [1, 1, 1, 1]] {
                var timeline = CaptureTimeline()
                var recording: [Float] = []
                var slot = 0
                for length in partition {
                    let values = (slot..<(slot + length)).map { Float($0 + 1) }
                    let next = packet(slot, values)
                    recording += useSecondary ? timeline.receiveSecondary(next) : timeline.receiveBase(next)
                    recording += useSecondary ? timeline.receiveSecondary(next) : timeline.receiveBase(next)
                    slot += length
                }
                recording += timeline.flush()
                XCTAssertEqual(recording, expected, "source=\(useSecondary), partition=\(partition)")
            }
        }
    }

    func testOneMissingFrameIsRecoveredFromAvailableBase() {
        var timeline = CaptureTimeline()
        var recording = timeline.receiveSecondary(CapturePacket(start: 0, samples: [1]))
        recording += timeline.receiveBase(CapturePacket(start: 0, samples: [90, 2, 80]))
        recording += timeline.receiveSecondary(CapturePacket(start: 2.0 / 16_000, samples: [3]))
        recording += timeline.flush()
        XCTAssertEqual(recording, [1, 2, 3], "An available speech sample cannot vanish at the smallest gap")
    }

    // Added 2026-10-03 from the translated-time behavioral requirement only.
    func testOneMissingFrameRecoveryIsIndependentOfTimestampOrigin() {
        for origin: Double in [1, 100, 1_000_000] {
            var timeline = CaptureTimeline()
            var recording = timeline.receiveSecondary(CapturePacket(start: origin, samples: [1]))
            recording += timeline.receiveBase(CapturePacket(start: origin, samples: [90, 2, 80]))
            recording += timeline.receiveSecondary(CapturePacket(start: origin + 2.0 / 16_000, samples: [3]))
            recording += timeline.flush()
            XCTAssertEqual(recording, [1, 2, 3], "Translation must preserve the available frame; origin=\(origin)")
            XCTAssertEqual(timeline.committedSamples(since: origin), 3)
        }
    }

    func testSingleFramePartitionsAndDuplicatesAreIndependentOfTimestampOrigin() {
        let expected: [Float] = [1, 2, 3, 4, 5, 6, 7]
        for origin: Double in [1, 100, 1_000_000] {
            for useSecondary in [false, true] {
                for partition in [[7], [1, 6], [3, 4], [1, 1, 1, 1, 1, 1, 1]] {
                    var timeline = CaptureTimeline()
                    var recording: [Float] = []
                    var index = 0
                    for length in partition {
                        let next = CapturePacket(
                            start: origin + Double(index) / 16_000,
                            samples: Array(expected[index..<(index + length)])
                        )
                        recording += useSecondary ? timeline.receiveSecondary(next) : timeline.receiveBase(next)
                        recording += useSecondary ? timeline.receiveSecondary(next) : timeline.receiveBase(next)
                        index += length
                    }
                    recording += timeline.flush()
                    XCTAssertEqual(recording, expected, "origin=\(origin), secondary=\(useSecondary), partition=\(partition)")
                    XCTAssertEqual(timeline.committedSamples(since: origin), expected.count)
                }
            }
        }
    }

    func testFractionalGapLimitDoesNotBecomeAnAdditionalWholeSample() {
        // These are real half-frame boundaries, not arithmetic noise around a
        // whole frame. Only base samples wholly before secondary starts fit.
        for origin: Double in [0, 1, 100, 1_000_000] {
            for secondaryStartInFrames: Double in [1.5, 2.5] {
                var timeline = CaptureTimeline()
                var recording = timeline.receiveSecondary(CapturePacket(start: origin, samples: [1]))
                recording += timeline.receiveBase(CapturePacket(start: origin, samples: [90, 2, 3, 80]))
                recording += timeline.receiveSecondary(CapturePacket(
                    start: origin + secondaryStartInFrames / 16_000,
                    samples: [4]
                ))
                let expected: [Float] = secondaryStartInFrames == 1.5 ? [1, 4] : [1, 2, 4]
                XCTAssertEqual(recording, expected, "A fractional remainder is not a whole captured sample; origin=\(origin), limit=\(secondaryStartInFrames)")
            }
        }
    }

    func testHeldBaseTailIsFullyEmittedOnceAtTranslatedOrigins() {
        for origin: Double in [1, 100, 1_000_000] {
            for finishWithFlush in [false, true] {
                var timeline = CaptureTimeline()
                var recording = timeline.receiveSecondary(CapturePacket(start: origin, samples: [1]))
                recording += timeline.receiveBase(CapturePacket(start: origin, samples: [90, 2, 3, 4, 5, 6, 7]))
                XCTAssertEqual(recording, [1], "Base tail must stay buffered while secondary is selected")
                recording += finishWithFlush ? timeline.flush() : timeline.useBase()
                XCTAssertEqual(recording, [1, 2, 3, 4, 5, 6, 7], "Every held sample, including the last, must survive; origin=\(origin), flush=\(finishWithFlush)")
                recording += timeline.flush()
                recording += timeline.useBase()
                XCTAssertEqual(recording, [1, 2, 3, 4, 5, 6, 7], "Repeated draining must not duplicate speech")
            }
        }
    }

    func testResetCannotLeakBufferedSpeechIntoNextRecording() {
        var timeline = CaptureTimeline()
        timeline.keepFrom = time(0)
        _ = timeline.receiveSecondary(packet(0, [1]))
        _ = timeline.receiveBase(packet(1, [99, 98]))
        timeline.reset()
        var recording = timeline.receiveBase(packet(0, [7]))
        recording += timeline.flush()
        XCTAssertEqual(recording, audio([7]))
        XCTAssertEqual(timeline.committedSamples(since: time(0)), frames)
    }
}
