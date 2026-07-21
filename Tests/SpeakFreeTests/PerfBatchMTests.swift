// Claude · 2026-07-19 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
import XCTest
@testable import SpeakFreeLib

/// Batch M (perf) — proves the menu/store code stops scaling with the recording corpus:
/// * `listRecordings(limit:)` selects the newest N by FILENAME and reads at most N sidecars (M1).
/// * the cached `recordingCount()` avoids rescanning the corpus on Settings-open (M2).
/// * `deleteAllRecordings()` sweeps every artifact without reading a sidecar per file (M3).
/// All isolation is via `Config.configDirOverride` scratch dirs — the real corpus is never touched.
final class PerfBatchMTests: XCTestCase {
    private var scratchDir: URL!
    private var testDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-perfM-\(UUID().uuidString)")
        Config.configDirOverride = scratchDir
        testDir = RecordingStore.recordingsDir
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        RecordingStore.sidecarReadsForTesting = 0
        RecordingStore.dateParsesForTesting = 0
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    // MARK: - Corpus seeding (a few hundred tiny fake recordings)

    /// Fixed base instant; recording `i` is timestamped base+i seconds, so a higher index is newer.
    /// Filenames are generated with RecordingStore's own formatter so the embedded timestamp
    /// round-trips exactly through `listRecordings(limit:)`.
    private static let base = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01T00:00:00Z

    @discardableResult
    private func writeRecording(index: Int, sidecar: Bool) -> URL {
        let ts = RecordingStore.dateFormatter.string(from: Self.base.addingTimeInterval(TimeInterval(index)))
        let name = "recording-\(ts)-\(String(format: "%08X", index)).wav"
        let url = testDir.appendingPathComponent(name)
        try! Data("x".utf8).write(to: url)
        if sidecar {
            let side = url.deletingPathExtension().appendingPathExtension("txt")
            try! Data("text-\(index)".utf8).write(to: side)
        }
        return url
    }

    /// Recover the seeding index encoded in the filename's 8-hex suffix.
    private func index(of url: URL) -> Int {
        let hex = String(url.deletingPathExtension().lastPathComponent.suffix(8))
        return Int(hex, radix: 16) ?? -1
    }

    // MARK: - M1: newest-N cap by filename

    func testLimitReturnsNewestNByFilename() {
        for i in 0..<300 { writeRecording(index: i, sidecar: true) }

        let recent = RecordingStore.listRecordings(limit: 15)

        XCTAssertEqual(recent.count, 15, "cap must bound the result to N")
        // Newest first, and exactly the top-15 indices (285...299).
        XCTAssertEqual(recent.map { index(of: $0.url) }, Array((285...299).reversed()))
        // Strictly descending by date.
        for k in 1..<recent.count {
            XCTAssertGreaterThan(recent[k - 1].date, recent[k].date)
        }
        // The ≤N slice DID read its sidecars.
        XCTAssertEqual(recent.first?.text, "text-299")
    }

    func testLimitReadsAtMostNSidecars() {
        for i in 0..<300 { writeRecording(index: i, sidecar: true) }

        RecordingStore.sidecarReadsForTesting = 0
        _ = RecordingStore.listRecordings(limit: 15)

        // The cap selection is filename-only: only the 15 chosen sidecars are opened, not all 300.
        XCTAssertEqual(RecordingStore.sidecarReadsForTesting, 15)
        XCTAssertEqual(RecordingStore.dateParsesForTesting, 15,
                       "timestamp parsing must also be capped, not scale with the corpus")
    }

    func testLimitSelectionIgnoresSidecars() {
        // Only the OLDEST 15 have sidecars; the newest 285 have none. If selection read sidecars to
        // decide, it would surface the old ones — it must not.
        for i in 0..<300 { writeRecording(index: i, sidecar: i < 15) }

        let recent = RecordingStore.listRecordings(limit: 15)

        XCTAssertEqual(recent.map { index(of: $0.url) }, Array((285...299).reversed()),
                       "selection must be by filename timestamp, not by which files have transcripts")
        XCTAssertTrue(recent.allSatisfy { $0.text == nil },
                      "the newest recordings genuinely have no sidecar")
    }

    func testLimitZeroAndEmpty() {
        writeRecording(index: 1, sidecar: true)
        XCTAssertTrue(RecordingStore.listRecordings(limit: 0).isEmpty)
        RecordingStore.deleteAllRecordings()
        XCTAssertTrue(RecordingStore.listRecordings(limit: 15).isEmpty)
    }

    // MARK: - M2: cached count

    func testCachedCountLazyInitialFromDisk() {
        for i in 0..<3 { writeRecording(index: i, sidecar: false) }
        // First access lazily scans disk.
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 3)
    }

    func testCachedCountTracksCreateAndDeleteAll() {
        // Warm the cache while empty.
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)

        // A wav written directly to disk (bypassing finishRecording) must NOT change the warm cache —
        // proves the value is cached, not rescanned every call.
        writeRecording(index: 1, sidecar: false)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)

        // finishRecording(keep:true) is the real create path — it increments the cache.
        let url = RecordingStore.newRecordingURL()
        try! Data("wav".utf8).write(to: url)
        let meta = RecordingStore.RecordingMeta(
            appVersion: "t", engine: "e", model: "m", inputDevice: nil,
            date: "d", durationSeconds: 1, transcriptChars: 1)
        RecordingStore.finishRecording(audioURL: url, keep: true, raw: "r", text: "t", meta: meta)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 1)

        // Delete All zeroes the cache.
        RecordingStore.deleteAllRecordings()
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
    }

    func testKeepFalseDoesNotIncrementCache() {
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
        let url = RecordingStore.newRecordingURL()
        try! Data("wav".utf8).write(to: url)
        let meta = RecordingStore.RecordingMeta(
            appVersion: "t", engine: "e", model: "m", inputDevice: nil,
            date: "d", durationSeconds: 1, transcriptChars: 1)
        RecordingStore.finishRecording(audioURL: url, keep: false, raw: "r", text: "t", meta: meta)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
    }

    // MARK: - M3: deleteAll sweeps everything without per-file sidecar reads

    func testDeleteAllRemovesAllArtifactsIncludingOrphans() {
        for i in 0..<50 { writeRecording(index: i, sidecar: true) }
        // An orphaned sidecar with no wav behind it — the old wav-driven pass could miss it.
        let orphan = testDir.appendingPathComponent("recording-2025-01-01-235959-DEADBEEF.txt")
        try! Data("orphan".utf8).write(to: orphan)

        RecordingStore.sidecarReadsForTesting = 0
        RecordingStore.deleteAllRecordings()

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: testDir.path)) ?? []
        XCTAssertTrue(remaining.filter { $0.hasPrefix("recording-") }.isEmpty,
                      "every recording-prefixed artifact, including the orphan sidecar, is gone")
        XCTAssertEqual(RecordingStore.sidecarReadsForTesting, 0,
                       "deleteAll must not read a transcript per file")
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
    }

    // MARK: - Adversarial perf review (codex-attack.md findings 5–7)

    // Finding 7: Delete All is an allow-list of EXACT recording artifacts. A human-managed
    // `recording-archive/` directory and a foreign-extension `recording-notes.pdf` — both
    // `recording-` prefixed — must survive, and directories are never recursed into.
    func testDeleteAllPreservesNonArtifactEntries() {
        for i in 0..<5 { writeRecording(index: i, sidecar: true) }

        let archiveDir = testDir.appendingPathComponent("recording-archive")
        try! FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        // A file nested inside the archive dir whose NAME is a valid artifact — proves no recursion.
        let nested = archiveDir.appendingPathComponent("recording-2025-01-01-120000-CAFEBABE.wav")
        try! Data("keep".utf8).write(to: nested)
        let notes = testDir.appendingPathComponent("recording-notes.pdf")
        try! Data("notes".utf8).write(to: notes)

        RecordingStore.deleteAllRecordings()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: archiveDir.path, isDirectory: &isDir) && isDir.boolValue,
                      "a recording-archive/ directory must survive Delete All")
        XCTAssertTrue(fm.fileExists(atPath: nested.path),
                      "Delete All must not recurse into directories")
        XCTAssertTrue(fm.fileExists(atPath: notes.path),
                      "recording-notes.pdf (foreign extension) must survive Delete All")
        // Every seeded top-level artifact is gone.
        let remaining = (try? fm.contentsOfDirectory(atPath: testDir.path)) ?? []
        XCTAssertTrue(remaining.allSatisfy { !RecordingStore.isRecordingArtifact($0) },
                      "all real top-level recording artifacts were removed")
    }

    // Finding 5: when a removal fails (permissions/immutable/IO), the survivor stays VISIBLE —
    // the cached count is invalidated and rescanned, not force-zeroed to hide the folder controls.
    func testDeleteAllKeepsCountVisibleWhenRemovalFails() throws {
        for i in 0..<3 { writeRecording(index: i, sidecar: false) }
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 3)  // warm the cache

        let ts = RecordingStore.dateFormatter.string(from: Self.base.addingTimeInterval(1))
        let stuck = testDir.appendingPathComponent("recording-\(ts)-00000001.wav")
        // User-immutable flag makes unlink() fail — a real un-removable file.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck.path)

        RecordingStore.deleteAllRecordings()

        // Restore removability so tearDown can clean up.
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path),
                      "the un-removable recording survived on disk")
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 1,
                       "cache must rescan and show the survivor, not report zero after a failed removal")
    }

    // Finding 6: the once-per-launch ensureDirectory guard must still recreate the folder if the
    // user trashes/moves it mid-session — otherwise the next wav write throws.
    func testEnsureDirectoryRecreatesVanishedFolder() {
        RecordingStore.ensureDirectory()                     // fire the once-guard for this path
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path))

        try! FileManager.default.removeItem(at: testDir)     // user trashes the recordings folder
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDir.path))

        let url = RecordingStore.newRecordingURL()           // next dictation re-ensures
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path, isDirectory: &isDir) && isDir.boolValue,
                      "ensureDirectory must recreate a folder that vanished after the once-guard fired")
        XCTAssertNoThrow(try Data("wav".utf8).write(to: url),
                         "a wav can be written into the recreated folder")
    }
}
