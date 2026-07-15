// Claude · 2026-07-15 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
import XCTest
@testable import SpeakFreeLib

/// Round-2 adversarial-review audio/privacy/config fixes (Agent B: P3, P4, P6, P8).
/// Every test drives a Config.configDirOverride scratch dir — never the live config —
/// and cleans up in tearDown. P1/P2/P5/P7 need app-lifecycle / live-CoreAudio / network
/// seams that don't exist for a pure unit test; they are exercised at the integration
/// level and noted in the fix report instead.
final class AdversarialR2PrivacyTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-r2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    // MARK: - P3: legacy maxRecordings migration is in-memory ONLY

    func testP3_MigrationDoesNotRewriteConfigOnDisk() throws {
        // Legacy pre-2026-06 config: maxRecordings=30 written as a DEFAULT, no marker.
        var c = Config.defaultConfig
        c.maxRecordings = 30
        c.maxRecordingsUserConfirmed = nil
        try c.save()

        // The LOADED (in-memory) config is migrated: cap cleared, marker stamped.
        let loaded = Config.load()
        XCTAssertNil(loaded.maxRecordings, "loaded cap must be cleared so prune keeps everything")
        XCTAssertEqual(loaded.maxRecordingsUserConfirmed, true, "loaded marker must be stamped")

        // …but the file on disk is UNTOUCHED. P3: migration must not save() inside load(),
        // or a non-atomic write racing a concurrent off-main load could reset config.json.
        let onDisk = try Config.decode(from: Data(contentsOf: Config.configFile))
        XCTAssertEqual(onDisk.maxRecordings, 30, "config.json must still hold the legacy 30")
        XCTAssertNil(onDisk.maxRecordingsUserConfirmed, "disk marker is only stamped on a Settings save")
    }

    func testP3_PruneUsesLoadedValueNotDiskValue() throws {
        var c = Config.defaultConfig
        c.maxRecordings = 30
        c.maxRecordingsUserConfirmed = nil
        try c.save()

        // finalizeRecording derives the prune cap from the LOADED config.
        let loaded = Config.load()
        let effective = Config.effectiveMaxRecordings(loaded.maxRecordings)
        XCTAssertEqual(effective, 0, "loaded nil cap → keep everything (no auto-prune)")

        // Concretely: prune at that cap is a no-op, so pre-existing recordings survive.
        for _ in 0..<3 {
            let url = RecordingStore.newRecordingURL()
            try Data(repeating: 0, count: 2048).write(to: url)
        }
        RecordingStore.prune(maxCount: effective)  // guard maxCount>0 → no-op
        XCTAssertEqual(RecordingStore.listRecordings().count, 3, "keep-everything must not delete")
    }

    func testP3_MigrationIsIdempotentAcrossReloads() throws {
        var c = Config.defaultConfig
        c.maxRecordings = 30
        c.maxRecordingsUserConfirmed = nil
        try c.save()

        // Re-deriving the migration on every load yields the same in-memory result each time.
        for _ in 0..<3 {
            let loaded = Config.load()
            XCTAssertNil(loaded.maxRecordings)
            XCTAssertEqual(loaded.maxRecordingsUserConfirmed, true)
        }
        // Disk value is stable (never rewritten by any of the loads).
        let onDisk = try Config.decode(from: Data(contentsOf: Config.configFile))
        XCTAssertEqual(onDisk.maxRecordings, 30)
    }

    // MARK: - P4: tmp/api sweep is age-gated (never eats an in-flight upload)

    func testP4_SweepOnlyRemovesStaleFiles() throws {
        let dir = LocalAPIServer.tmpAPIDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A recent upload (another instance / concurrent request) must survive a start() sweep.
        let fresh = dir.appendingPathComponent("inflight.audio")
        try Data("recent".utf8).write(to: fresh)

        // A >1h-old orphan (crash residue) must be swept.
        let stale = dir.appendingPathComponent("orphan.audio")
        try Data("old".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)

        let swept = LocalAPIServer.sweepTmpAPI()  // default 1-hour gate

        XCTAssertEqual(swept, 1, "only the >1h-old orphan is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "a recent in-flight upload must survive the sweep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testP4_ExplicitAgeSeepsEverythingWhenRequested() throws {
        let dir = LocalAPIServer.tmpAPIDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("x.audio")
        try Data("y".utf8).write(to: f)

        // olderThan:0 sweeps regardless of age — the injectable seam used by callers/tests.
        XCTAssertEqual(LocalAPIServer.sweepTmpAPI(olderThan: 0), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    // MARK: - P6: Parakeet vocab must be a non-empty [String] or [String:String]

    func testP6_VocabShapeValidation() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sf-r2-vocab-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let vocab = dir.appendingPathComponent("parakeet_vocab.json")

        func check(_ json: String) -> Bool {
            try? Data(json.utf8).write(to: vocab)
            return ParakeetModelManager.parakeetVocabIsValid(inDir: dir)
        }

        // Parseable-but-useless shapes are now rejected (they made FluidAudio throw at load).
        XCTAssertFalse(check("{}"), "empty object → invalid")
        XCTAssertFalse(check("[]"), "empty array → invalid")
        XCTAssertFalse(check("42"), "bare number → invalid")
        XCTAssertFalse(check("\"hi\""), "bare string → invalid")
        XCTAssertFalse(check("[1, 2, 3]"), "array of non-strings → invalid")
        XCTAssertFalse(check("{\"0\": 1}"), "object of non-string values → invalid")

        // The two shapes FluidAudio actually parses are accepted.
        XCTAssertTrue(check("[\"<blank>\", \"a\", \"the\"]"), "non-empty [String] → valid")
        XCTAssertTrue(check("{\"0\": \"<blank>\", \"1\": \"a\"}"), "non-empty [String:String] → valid")
    }

    // MARK: - P8: RecordingStore mutations are serialized (no orphan-sidecar TOCTOU)

    func testP8_ConcurrentMutationsProduceNoOrphanSidecar() throws {
        let meta = RecordingStore.RecordingMeta(
            appVersion: "test", engine: "parakeet", model: "m",
            inputDevice: nil, date: "2026-07-15", durationSeconds: 1.0, transcriptChars: 1)

        // Hammer finishRecording / prune / deleteAllRecordings concurrently. The static
        // mutationLock must serialize them: no deadlock, and no transcript sidecar left behind
        // without its wav (the exact TOCTOU the lock closes).
        let group = DispatchGroup()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                let url = RecordingStore.newRecordingURL()
                try? Data(repeating: 0, count: 2048).write(to: url)
                RecordingStore.finishRecording(audioURL: url, keep: true, raw: "r", text: "t", meta: meta)
                if i % 5 == 0 { RecordingStore.prune(maxCount: 3) }
                if i % 11 == 0 { RecordingStore.deleteAllRecordings() }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success, "mutations must not deadlock")

        // Invariant: every transcript sidecar still has its wav. Without the lock, a delete
        // between finishRecording's fileExists guard and its sidecar writes would leave a
        // transcript with no audio behind it.
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: RecordingStore.recordingsDir.path)) ?? []
        for name in files where name.hasSuffix(".txt") && !name.hasSuffix(".raw.txt") {
            let base = (name as NSString).deletingPathExtension  // recording-<ts>-<id>
            let wav = RecordingStore.recordingsDir.appendingPathComponent(base + ".wav")
            XCTAssertTrue(fm.fileExists(atPath: wav.path),
                          "orphan transcript sidecar \(name) has no wav — serialization failed")
        }
    }
}
