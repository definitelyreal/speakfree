// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
import XCTest
@testable import SpeakFreeLib

final class RecordingStoreTests: XCTestCase {
    private var scratchDir: URL!
    private var testDir: URL!

    override func setUp() {
        super.setUp()
        // Standard isolation seam: RecordingStore.recordingsDir is computed from
        // Config.configDir on every access, so the override redirects everything.
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-test-\(UUID().uuidString)")
        Config.configDirOverride = scratchDir
        testDir = RecordingStore.recordingsDir
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    func testDeleteReportsFailureWhenDirectoryCannotBeEnumerated() throws {
        let fm = FileManager.default
        try fm.removeItem(at: testDir)
        try Data("not a directory".utf8).write(to: testDir)
        let result = RecordingStore.deleteAllRecordings()
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.enumerationFailed)
        XCTAssertEqual(try String(contentsOf: testDir), "not a directory")
    }

    func testDeleteOfAbsentDirectorySucceeds() throws {
        try FileManager.default.removeItem(at: testDir)
        XCTAssertTrue(RecordingStore.deleteAllRecordings().succeeded)
    }

    func testFailedRemovalPreservesFileAndReportsFailureThenCanRetry() throws {
        let fm = FileManager.default
        let wav = RecordingStore.newRecordingURL()
        try Data("synthetic fixture".utf8).write(to: wav)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: testDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: testDir.path) }
        let failed = RecordingStore.deleteAllRecordings()
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.failedFiles, 1)
        XCTAssertTrue(fm.fileExists(atPath: wav.path))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: testDir.path)
        let retried = RecordingStore.deleteAllRecordings()
        XCTAssertTrue(retried.succeeded)
        XCTAssertEqual(retried.removedFiles, 1)
        XCTAssertFalse(fm.fileExists(atPath: wav.path))
    }

    func testNewRecordingURLCreatesValidPath() {
        let url = RecordingStore.newRecordingURL()
        XCTAssertTrue(url.lastPathComponent.hasPrefix("recording-"))
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertTrue(url.path.contains(testDir.path))
    }

    func testNewRecordingURLsAreUnique() {
        let url1 = RecordingStore.newRecordingURL()
        let url2 = RecordingStore.newRecordingURL()
        XCTAssertNotEqual(url1, url2)
    }

    func testNewRecordingURLFormat() {
        let url = RecordingStore.newRecordingURL()
        XCTAssertTrue(url.lastPathComponent.hasPrefix("recording-"))
        XCTAssertEqual(url.pathExtension, "wav")
    }

    func testListRecordingsEmpty() {
        let recordings = RecordingStore.listRecordings()
        XCTAssertTrue(recordings.isEmpty)
    }

    func testListRecordingsFindsFiles() throws {
        let url1 = RecordingStore.newRecordingURL()
        let url2 = RecordingStore.newRecordingURL()
        try Data("fake".utf8).write(to: url1)
        try Data("fake".utf8).write(to: url2)

        let recordings = RecordingStore.listRecordings()
        XCTAssertEqual(recordings.count, 2)
    }

    func testListRecordingsIgnoresNonRecordingFiles() throws {
        let bogus = testDir.appendingPathComponent("notes.txt")
        try Data("not a recording".utf8).write(to: bogus)

        let recordings = RecordingStore.listRecordings()
        XCTAssertTrue(recordings.isEmpty)
    }

    func testListRecordingsSortedNewestFirst() throws {
        let older = testDir.appendingPathComponent("recording-2025-01-01-120000-AAAAAAAA.wav")
        let newer = testDir.appendingPathComponent("recording-2025-06-15-150000-BBBBBBBB.wav")
        try Data("fake".utf8).write(to: older)
        try Data("fake".utf8).write(to: newer)

        let recordings = RecordingStore.listRecordings()
        XCTAssertEqual(recordings.count, 2)
        XCTAssertTrue(recordings[0].date > recordings[1].date)
    }

    func testPruneRemovesOldest() throws {
        let urls = [
            testDir.appendingPathComponent("recording-2025-01-01-100000-AAAAAAAA.wav"),
            testDir.appendingPathComponent("recording-2025-01-01-110000-BBBBBBBB.wav"),
            testDir.appendingPathComponent("recording-2025-01-01-120000-CCCCCCCC.wav"),
        ]
        for url in urls {
            try Data("fake".utf8).write(to: url)
        }

        RecordingStore.prune(maxCount: 2)
        let remaining = RecordingStore.listRecordings()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.allSatisfy { $0.url.lastPathComponent != "recording-2025-01-01-100000-AAAAAAAA.wav" })
    }

    func testPruneDoesNothingWhenUnderLimit() throws {
        let url = RecordingStore.newRecordingURL()
        try Data("fake".utf8).write(to: url)

        RecordingStore.prune(maxCount: 5)
        XCTAssertEqual(RecordingStore.listRecordings().count, 1)
    }

    func testDeleteAllRecordings() throws {
        for _ in 0..<3 {
            let url = RecordingStore.newRecordingURL()
            try Data("fake".utf8).write(to: url)
        }
        XCTAssertEqual(RecordingStore.listRecordings().count, 3)

        RecordingStore.deleteAllRecordings()
        XCTAssertEqual(RecordingStore.listRecordings().count, 0)
    }
}
