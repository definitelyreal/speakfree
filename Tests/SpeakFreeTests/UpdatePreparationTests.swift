// ai-suggestion:unverified · session:01a09da8-0424-7b71-a705-10868c5f46e4 · 2026-09-13
import XCTest
@testable import SpeakFreeLib

final class UpdatePreparationTests: XCTestCase {
    func testRequiresFullObservedQuietAndWarning() {
        var policy = UpdateQuietPolicy(startedAt: 0, timeout: 600)
        XCTAssertEqual(policy.observe(now: 0, active: false, changed: false), .waiting(30))
        XCTAssertEqual(policy.observe(now: 29.99, active: false, changed: false), .waiting(1))
        XCTAssertEqual(policy.observe(now: 30, active: false, changed: false), .warning(5, playTone: true))
        XCTAssertEqual(policy.observe(now: 34.99, active: false, changed: false), .warning(1, playTone: false))
        XCTAssertEqual(policy.observe(now: 35, active: false, changed: false), .ready)
    }

    func testNewActivityDuringWarningRestartsBothIntervals() {
        var policy = UpdateQuietPolicy(startedAt: 0, timeout: 600)
        _ = policy.observe(now: 0, active: false, changed: false)
        _ = policy.observe(now: 30, active: false, changed: false)
        XCTAssertEqual(policy.observe(now: 34.99, active: true, changed: false), .waiting(30))
        XCTAssertEqual(policy.observe(now: 90, active: true, changed: false), .waiting(30))
        XCTAssertEqual(policy.observe(now: 91, active: false, changed: false), .waiting(30))
        XCTAssertEqual(policy.observe(now: 121, active: false, changed: false), .warning(5, playTone: true))
        XCTAssertEqual(policy.observe(now: 122, active: false, changed: true), .waiting(30))
        XCTAssertEqual(policy.observe(now: 123, active: false, changed: false), .waiting(30))
    }

    func testStaleMainQueueDeliveryCannotAuthorizeOrKeepWarning() {
        var policy = UpdateQuietPolicy(startedAt: 0, timeout: 600)
        _ = policy.observe(now: 0, active: false, changed: false)
        _ = policy.observe(now: 30, active: false, changed: false)
        XCTAssertEqual(policy.observe(now: 36, active: false, changed: false, observedAt: 33), .waiting(30))
        XCTAssertNil(policy.warningSince)
        XCTAssertEqual(policy.observe(now: 37, active: false, changed: false, observedAt: 37), .waiting(30))
        XCTAssertEqual(policy.observe(now: 67, active: false, changed: false, observedAt: 67), .warning(5, playTone: true))
        XCTAssertEqual(policy.observe(now: 72, active: false, changed: false, observedAt: 72), .ready)
    }

    func testTimeoutNeverAuthorizesEvenWhenQuietOrActive() {
        for active in [false, true] {
            var policy = UpdateQuietPolicy(startedAt: 0, timeout: 60)
            _ = policy.observe(now: 0, active: false, changed: false)
            XCTAssertEqual(policy.observe(now: 60, active: active, changed: false), .timedOut)
        }
    }

    func testParserSeparatesHealthFromFailedCaptureAndRejectsUnknownCaptureFormat() {
        XCTAssertEqual(UpdateLogEvent.classify("[12:34:56] Health check: all OK"), .unrelated)
        XCTAssertEqual(UpdateLogEvent.classify("[12:34:56] Capture route: base healthy"), .unrelated)
        XCTAssertEqual(UpdateLogEvent.classify("[12:34:56] AudioRecorder: recording started, pre-roll 100 samples"), .captureStarted)
        XCTAssertEqual(UpdateLogEvent.classify("[12:34:56] Recording start FAILED: synthetic"), .activity)
        XCTAssertEqual(UpdateLogEvent.classify("[12:34:56] Transcription failed: synthetic"), .activity)
        XCTAssertEqual(UpdateLogEvent.classify("[12:34:56] New dictation state format"), .unsupported)
        XCTAssertEqual(UpdateLogEvent.classify("malformed"), .unsupported)
    }

    func testMetadataAndNewEventObservationWithoutReadingTranscriptBodies() throws {
        try withFixture { root, log in
            let observer = LegacyUpdateActivityObserver(directory: root)
            XCTAssertFalse(try observer.snapshot().changed)
            try append("[12:34:56] Health check: all OK\n", to: log)
            XCTAssertFalse(try observer.snapshot().changed, "unrelated periodic logs must allow updates")
            try append("[12:34:57] Recording start FAILED: synthetic\n", to: log)
            XCTAssertTrue(try observer.snapshot().changed, "failed attempts without a WAV still defer")
            XCTAssertFalse(try observer.snapshot().changed)
            let wav = root.appendingPathComponent("recordings/recording-fixture.wav")
            try Data([0, 1]).write(to: wav)
            XCTAssertTrue(try observer.snapshot().changed)
            XCTAssertFalse(try observer.snapshot().changed)
            try append("synthetic", to: wav)
            XCTAssertTrue(try observer.snapshot().changed, "existing WAV growth must defer")
            try FileManager.default.removeItem(at: wav)
            XCTAssertTrue(try observer.snapshot().changed, "opt-out deletion still counts as activity")
        }
    }

    func testSentinelPresenceAlwaysBlocksEvenMalformedOrStale() throws {
        try withFixture { root, _ in
            let observer = LegacyUpdateActivityObserver(directory: root)
            let sentinel = root.appendingPathComponent(".recording-in-progress.json")
            try Data("not JSON".utf8).write(to: sentinel)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: sentinel.path)
            XCTAssertTrue(try observer.snapshot().active)
            try FileManager.default.removeItem(at: sentinel)
            XCTAssertFalse(try observer.snapshot().active)
        }
    }

    func testMissingEvidenceAndUnknownNewEventFailClosed() throws {
        try withFixture { root, log in
            let observer = LegacyUpdateActivityObserver(directory: root)
            _ = try observer.snapshot()
            try append("[12:34:56] New recording protocol\n", to: log)
            XCTAssertThrowsError(try observer.snapshot())
            try FileManager.default.removeItem(at: log)
            XCTAssertThrowsError(try LegacyUpdateActivityObserver(directory: root).snapshot())
        }
    }

    func testPartialLineBlocksUntilCompleteAndCannotHideAttempt() throws {
        try withFixture { root, log in
            let observer = LegacyUpdateActivityObserver(directory: root)
            _ = try observer.snapshot()
            try append("[12:34:56] Recording start", to: log)
            XCTAssertTrue(try observer.snapshot().changed)
            XCTAssertTrue(try observer.snapshot().changed)
            try append(" FAILED: synthetic\n", to: log)
            XCTAssertTrue(try observer.snapshot().changed)
            XCTAssertFalse(try observer.snapshot().changed)
        }
    }

    func testRotationCannotSkipNewCaptureAndLongBacklogBlocks() throws {
        try withFixture { root, log in
            let observer = LegacyUpdateActivityObserver(directory: root)
            _ = try observer.snapshot()
            try FileManager.default.removeItem(at: log)
            try Data("[12:34:56] Recording start FAILED: synthetic\n".utf8).write(to: log)
            XCTAssertTrue(try observer.snapshot().changed)
            try append(String(repeating: "a", count: 1_048_578), to: log)
            XCTAssertThrowsError(try observer.snapshot())
        }
    }

    func testLargeArchiveBoundsPerPollMetadataAndCachesMembership() throws {
        try withFixture { root, _ in
            for index in 0..<1_000 {
                let name = String(format: "recording-2026-09-13-%06d-fixture.wav", index)
                try Data().write(to: root.appendingPathComponent("recordings/" + name))
            }
            let observer = LegacyUpdateActivityObserver(directory: root)
            _ = try observer.snapshot()
            XCTAssertEqual(observer.recordingStatCount, LegacyUpdateActivityObserver.recentFileLimit)
            XCTAssertEqual(observer.recordingListingCount, 1)
            XCTAssertFalse(try observer.snapshot().changed)
            XCTAssertEqual(observer.recordingStatCount, LegacyUpdateActivityObserver.recentFileLimit)
            XCTAssertEqual(observer.recordingListingCount, 1, "stable archives do not enumerate on every poll")
            let newest = root.appendingPathComponent("recordings/recording-2026-09-14-000000-new.wav")
            try Data([1]).write(to: newest)
            XCTAssertTrue(try observer.snapshot().changed)
            XCTAssertEqual(observer.recordingListingCount, 2)
            try append("growth", to: newest)
            XCTAssertTrue(try observer.snapshot().changed)
        }
    }

    func testKnownCaptureWithoutSentinelStaysActiveUntilStop() throws {
        try withFixture { root, log in
            let observer = LegacyUpdateActivityObserver(directory: root)
            _ = try observer.snapshot()
            try append("[12:34:56] AudioRecorder: recording started, pre-roll 100 samples\n", to: log)
            XCTAssertTrue(try observer.snapshot().active)
            XCTAssertTrue(try observer.snapshot().active, "a failed sentinel write must not allow quiet timeout during a known hold")
            try append("[12:34:57] Health check: all OK\n", to: log)
            XCTAssertTrue(try observer.snapshot().active)
            try append("[12:35:56] AudioRecorder: recording stopped, 100 samples\n", to: log)
            let stopped = try observer.snapshot()
            XCTAssertFalse(stopped.active)
            XCTAssertTrue(stopped.changed)
        }
    }

    func testInvalidCLIArgumentsDoNotStartUI() {
        XCTAssertEqual(UpdatePreparation.run(arguments: ["--timeout", "0"]), 64)
        XCTAssertEqual(UpdatePreparation.run(arguments: ["--timeout", "nan"]), 64)
        XCTAssertEqual(UpdatePreparation.run(arguments: ["--force"]), 64)
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speakfree-update-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let log = root.appendingPathComponent("logs/speakfree-fixture.log")
        try Data("[12:00:00] Session started\n".utf8).write(to: log)
        try body(root, log)
    }
    private func append(_ value: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(value.utf8))
    }
}
