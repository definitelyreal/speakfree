// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import XCTest

final class DictationCommandTests: XCTestCase {
    func testStopCommandRoundTripsAndAtomicallyReplacesItsToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID()
        let first = UUID()
        try SpeakFreeDictationCommandStore.requestStop(
            sessionID: sessionID,
            requestID: first,
            in: directory
        )
        XCTAssertEqual(
            SpeakFreeDictationCommandStore.readStopCommand(in: directory),
            .init(sessionID: sessionID, requestID: first)
        )

        let second = UUID()
        try SpeakFreeDictationCommandStore.requestStop(
            sessionID: sessionID,
            requestID: second,
            in: directory
        )
        XCTAssertEqual(
            SpeakFreeDictationCommandStore.readStopCommand(in: directory),
            .init(sessionID: sessionID, requestID: second)
        )
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: directory.path))
                .contains { $0.hasSuffix(".tmp") }
        )
    }

    func testTrackerIgnoresStaleAndRepeatedCommandsButConsumesANewOne() {
        let sessionID = UUID()
        var tracker = DictationStopCommandTracker()
        let old = SpeakFreeDictationCommandStore.StopCommand(
            sessionID: sessionID,
            requestID: UUID()
        )
        tracker.arm(sessionID: sessionID, currentCommand: old)
        XCTAssertFalse(tracker.shouldStop(for: nil))
        XCTAssertFalse(tracker.shouldStop(for: old))
        XCTAssertFalse(tracker.shouldStop(for: .init(sessionID: UUID(), requestID: UUID())))
        let new = SpeakFreeDictationCommandStore.StopCommand(
            sessionID: sessionID,
            requestID: UUID()
        )
        XCTAssertTrue(tracker.shouldStop(for: new))
        XCTAssertFalse(tracker.shouldStop(for: new))
    }
}
