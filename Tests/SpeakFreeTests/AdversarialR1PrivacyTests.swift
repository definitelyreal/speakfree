import XCTest
import AVFoundation
@testable import SpeakFreeLib

/// Round-1 adversarial-review privacy/persistence/network fixes (PR-A..D, NW-A..B).
/// Every test drives a Config.configDirOverride scratch dir — never the live config —
/// and cleans up in tearDown.
final class AdversarialR1PrivacyTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-r1-\(UUID().uuidString)")
        // Create the config dir itself (but NOT the recordings subdir — PR-D needs a
        // fresh leaf create) so createDirectory attributes land on the leaf we're testing.
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    // MARK: - PR-A: legacy maxRecordings=30 default migration

    private func writeConfig(maxRecordings: Int?, userConfirmed: Bool?) throws {
        var c = Config.defaultConfig
        c.maxRecordings = maxRecordings
        c.maxRecordingsUserConfirmed = userConfirmed
        try c.save()
    }

    func testLegacyDefault30IsClearedToNilOnLoad() throws {
        // Pre-2026-06 build: maxRecordings=30 written as a DEFAULT, no confirmation marker.
        try writeConfig(maxRecordings: 30, userConfirmed: nil)

        let loaded = Config.load()
        XCTAssertNil(loaded.maxRecordings, "legacy default 30 must be cleared so prune never auto-deletes")
        XCTAssertEqual(loaded.maxRecordingsUserConfirmed, true, "migration must stamp the marker")

        // Persisted, so it only migrates once.
        let reloaded = Config.load()
        XCTAssertNil(reloaded.maxRecordings)
        XCTAssertEqual(reloaded.maxRecordingsUserConfirmed, true)
    }

    func testUserConfirmed30Survives() throws {
        // A user who deliberately chose a 30 cap in Settings (marker present) keeps it.
        try writeConfig(maxRecordings: 30, userConfirmed: true)

        let loaded = Config.load()
        XCTAssertEqual(loaded.maxRecordings, 30, "a user-confirmed 30 must not be migrated away")
        XCTAssertEqual(loaded.maxRecordingsUserConfirmed, true)
    }

    func testNonThirtyValueSurvives() throws {
        // Any explicit non-30 cap is untouched even without a marker.
        try writeConfig(maxRecordings: 50, userConfirmed: nil)

        let loaded = Config.load()
        XCTAssertEqual(loaded.maxRecordings, 50, "non-30 caps are never treated as the legacy default")
    }

    // MARK: - PR-B: stale SettingsViewModel resurrecting saveRecordings

    func testRefreshFromDiskPreventsStaleSaveOverlay() throws {
        // Start with saving ON on disk, so the view model snapshots true.
        var c = Config.defaultConfig
        c.saveRecordings = FlexBool(true)
        try c.save()

        let vm = SettingsViewModel()
        XCTAssertTrue(vm.saveRecordings)

        // The recordings notice turns saving OFF on disk behind the view model's back.
        RecordingsNotice.persistSaveToggle(false)
        XCTAssertTrue(vm.saveRecordings, "view model still holds the stale value until refreshed")

        // PR-B: the Settings-open refresh hook re-syncs from disk before any save.
        vm.refreshFromDisk()
        XCTAssertFalse(vm.saveRecordings)

        // A subsequent Settings save must NOT resurrect saving.
        vm.save()
        XCTAssertEqual(Config.load().saveRecordings?.value, false)
    }

    // MARK: - PR-C: finishRecording(keep:true) with a vanished wav

    func testFinishRecordingSkipsSidecarsWhenWavMissing() {
        let audioURL = RecordingStore.newRecordingURL()  // creates the dir, not the file
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))

        let meta = RecordingStore.RecordingMeta(
            appVersion: "test", engine: "parakeet", model: "m",
            inputDevice: nil, date: "2026-07-15",
            durationSeconds: 1.0, transcriptChars: 4)
        RecordingStore.finishRecording(audioURL: audioURL, keep: true,
                                       raw: "raw", text: "text", meta: meta)

        // No orphan sidecars must be resurrected.
        let base = audioURL.deletingPathExtension()
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: audioURL.path))
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathExtension("txt").path))
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathExtension("raw.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathExtension("meta.json").path))
    }

    // MARK: - PR-D: recordings dir created 0700 with no chmod window

    func testEnsureDirectoryCreatesWith0700() throws {
        let dir = RecordingStore.recordingsDir
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "must be a fresh create")

        RecordingStore.ensureDirectory()

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o700)
    }

    // MARK: - NW-A: LocalAPIServer sweeps tmp/api at start

    func testSweepTmpAPIRemovesLeftovers() throws {
        let dir = LocalAPIServer.tmpAPIDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let leftover = dir.appendingPathComponent("orphan.audio")
        try Data("stale".utf8).write(to: leftover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))

        // P4: the sweep now only removes files older than an hour so it can't delete another
        // instance's in-flight upload. Backdate this orphan two hours to make it eligible.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: leftover.path)

        let swept = LocalAPIServer.sweepTmpAPI()

        XCTAssertEqual(swept, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: - NW-B: decode duration cap math

    func testDurationCapRejectsOverLimit() {
        // One frame over 30 min at 16 kHz mono (no resample) must be rejected.
        let overFrames = AVAudioFrameCount(LocalAPIServer.maxDecodedFrames + 1)
        XCTAssertTrue(LocalAPIServer.exceedsDurationCap(srcFrames: overFrames, srcSampleRate: 16_000))

        // A 48 kHz source that downsamples above the 16 kHz cap must also be rejected.
        let over48k = AVAudioFrameCount(30 * 60 * 48_000 + 48_000)
        XCTAssertTrue(LocalAPIServer.exceedsDurationCap(srcFrames: over48k, srcSampleRate: 48_000))
    }

    func testDurationCapAcceptsWithinLimit() {
        // One second of 16 kHz audio is well under the cap.
        XCTAssertFalse(LocalAPIServer.exceedsDurationCap(srcFrames: 16_000, srcSampleRate: 16_000))
        // Exactly at the cap is allowed (strictly-greater rejection).
        let atCap = AVAudioFrameCount(LocalAPIServer.maxDecodedFrames)
        XCTAssertFalse(LocalAPIServer.exceedsDurationCap(srcFrames: atCap, srcSampleRate: 16_000))
    }
}
