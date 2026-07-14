// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import XCTest
@testable import SpeakFreeLib

/// Recordings privacy (2026-07-14): saving is opt-in, and the apology notice governs
/// what happens to files that accumulated while saving was accidentally on-by-default.
final class RecordingsNoticeTests: XCTestCase {

    var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-notice-tests-\(UUID().uuidString)")
        Config.configDirOverride = scratchDir
        try? FileManager.default.createDirectory(at: RecordingStore.recordingsDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func makeRecording(_ name: String = "recording-2026-07-01-120000-AAAA0000",
                               sidecars: Bool = true) -> URL {
        let wav = RecordingStore.recordingsDir.appendingPathComponent("\(name).wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        if sidecars {
            RecordingStore.saveRaw(text: "raw text", for: wav)
            RecordingStore.saveTranscription(text: "final text", for: wav)
            RecordingStore.saveMeta(RecordingStore.RecordingMeta(
                appVersion: "test", engine: "parakeet", model: "m", inputDevice: nil,
                date: "2026-07-01T12:00:00Z", durationSeconds: 1, transcriptChars: 10), for: wav)
        }
        return wav
    }

    // MARK: - Launch policy

    func testUndecidedWithRecordingsShows() {
        XCTAssertEqual(RecordingsNotice.launchAction(decision: nil, hasRecordings: true), .show)
    }

    func testUndecidedWithoutRecordingsMarksNotApplicable() {
        // A fresh install must never see the apology — and must be marked so recordings
        // they opt into LATER don't trigger it.
        XCTAssertEqual(RecordingsNotice.launchAction(decision: nil, hasRecordings: false),
                       .markNotApplicable)
    }

    func testAnyDecisionMeansNeverShowAgain() {
        for decision in ["keep", "delete", "none-found"] {
            XCTAssertEqual(RecordingsNotice.launchAction(decision: decision, hasRecordings: true),
                           .nothing, "decision '\(decision)' must permanently suppress the notice")
            XCTAssertEqual(RecordingsNotice.launchAction(decision: decision, hasRecordings: false),
                           .nothing)
        }
    }

    // MARK: - Resolution

    func testResolveKeepLeavesFilesAndPersistsDecision() {
        let wav = makeRecording()
        RecordingsNotice.resolve(deleteExisting: false, saveFutureRecordings: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path),
                      "'Keep my recordings' must not touch the files")
        let config = Config.load()
        XCTAssertEqual(config.recordingsNoticeDecision, "keep")
        XCTAssertEqual(config.saveRecordings?.value, false)
    }

    func testResolveDeleteRemovesWavAndAllSidecars() {
        let wav = makeRecording()
        let base = wav.deletingPathExtension()
        RecordingsNotice.resolve(deleteExisting: true, saveFutureRecordings: false)

        for path in [wav.path, base.appendingPathExtension("txt").path,
                     base.appendingPathExtension("raw.txt").path,
                     base.appendingPathExtension("meta.json").path] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "delete must remove \(path) — transcripts are as sensitive as audio")
        }
        XCTAssertEqual(Config.load().recordingsNoticeDecision, "delete")
    }

    func testResolveCanEnableFutureSavingWhileDeletingOld() {
        _ = makeRecording()
        RecordingsNotice.resolve(deleteExisting: true, saveFutureRecordings: true)
        let config = Config.load()
        XCTAssertEqual(config.recordingsNoticeDecision, "delete")
        XCTAssertEqual(config.saveRecordings?.value, true,
                       "dialog toggle and keep/delete buttons are independent choices")
    }

    // MARK: - hasAudioFiles (gates the Show Recording Folder button)

    func testHasAudioFilesFalseForEmptyFolder() {
        XCTAssertFalse(RecordingStore.hasAudioFiles())
    }

    func testHasAudioFilesFalseForMissingFolder() {
        try? FileManager.default.removeItem(at: RecordingStore.recordingsDir)
        XCTAssertFalse(RecordingStore.hasAudioFiles())
    }

    func testHasAudioFilesFalseForSidecarsOnly() {
        let wav = makeRecording()
        try? FileManager.default.removeItem(at: wav)
        XCTAssertFalse(RecordingStore.hasAudioFiles(),
                       "leftover sidecars without audio must not enable the browse button")
    }

    func testHasAudioFilesTrueWithWav() {
        _ = makeRecording(sidecars: false)
        XCTAssertTrue(RecordingStore.hasAudioFiles())
    }

    // MARK: - finishRecording (the per-dictation persistence gate)

    func testFinishRecordingKeepWritesAllSidecars() {
        let wav = makeRecording(sidecars: false)
        RecordingStore.finishRecording(
            audioURL: wav, keep: true, raw: "raw", text: "final",
            meta: RecordingStore.RecordingMeta(
                appVersion: "t", engine: "parakeet", model: "m", inputDevice: nil,
                date: "2026-07-14T00:00:00Z", durationSeconds: 2, transcriptChars: 5))

        let base = wav.deletingPathExtension()
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("raw.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("meta.json").path))
    }

    func testFinishRecordingDiscardLeavesNothing() {
        let wav = makeRecording(sidecars: false)
        RecordingStore.finishRecording(
            audioURL: wav, keep: false, raw: "raw", text: "final",
            meta: RecordingStore.RecordingMeta(
                appVersion: "t", engine: "parakeet", model: "m", inputDevice: nil,
                date: "2026-07-14T00:00:00Z", durationSeconds: 2, transcriptChars: 5))

        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: RecordingStore.recordingsDir.path)) ?? []
        XCTAssertTrue(contents.isEmpty,
                      "with saving off, a finished dictation must leave zero files; found \(contents)")
    }

    // MARK: - Config round-trip

    func testNewConfigKeysRoundTrip() throws {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(true)
        config.recordingsNoticeDecision = "keep"
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.saveRecordings?.value, true)
        XCTAssertEqual(decoded.recordingsNoticeDecision, "keep")
    }

    func testLegacyConfigDefaultsToNotSavingAndUndecided() throws {
        // A v1.7.1 config has neither key: saving must default OFF and the notice
        // must be undecided.
        let json = """
        {"hotkey": {"keyCode": 63, "modifiers": []}, "modelSize": "small.en", "language": "en"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertNil(config.saveRecordings)
        XCTAssertNil(config.recordingsNoticeDecision)
    }
}
