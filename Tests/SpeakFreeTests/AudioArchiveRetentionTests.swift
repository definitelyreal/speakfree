// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
import CryptoKit
import XCTest
@testable import SpeakFreeLib

final class AudioArchiveRetentionTests: XCTestCase {
    private let fm = FileManager.default
    private var directory: URL!
    private var priorConfig: URL?
    private var recordings: URL { RecordingStore.recordingsDir }
    private let injected = NSError(domain: "SyntheticArchiveIO", code: 1)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/26-10-02-pinned-audio/retention-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        priorConfig = Config.configDirOverride; Config.configDirOverride = directory
        RecordingStore.ensureDirectory()
    }
    override func tearDownWithError() throws {
        let formerRecordings = recordings
        Config.configDirOverride = priorConfig
        try fm.removeItem(at: directory)
        AudioArchiveIntegrity.forgetMissingArchives(in: formerRecordings)
    }
    private func audio(_ stamp: String) -> URL {
        recordings.appendingPathComponent("recording-2026-10-02-\(stamp)-AAAAAAAA.wav")
    }
    @discardableResult
    private func publish(_ stamp: String, repaired: Bool = false) throws -> URL {
        let url = audio(stamp)
        let writer = try WavWriter(url: url); try writer.append([0.2, 0.3]); try writer.finish()
        if repaired { try AudioRecorder.finalizeArchive(url: url, samples: [0.2, 0.3], writeFailed: true) }
        let meta = RecordingStore.RecordingMeta(appVersion: "test", engine: "fake", model: "fake", inputDevice: nil,
            date: "2026-10-02", durationSeconds: 1, transcriptChars: 5)
        RecordingStore.finishRecording(audioURL: url, keep: true, raw: "words", text: "Words", meta: meta)
        return url
    }
    private func group(_ url: URL) throws -> [URL] {
        let stem = RecordingActivity.stem(for: url)
        return try fm.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil).filter {
            RecordingActivity.stem(for: $0) == stem
        }
    }
    private func index() throws -> Set<String> {
        guard fm.fileExists(atPath: RecordingStore.recentIndexURL.path) else { return [] }
        return Set(try String(contentsOf: RecordingStore.recentIndexURL).split(separator: "\n").map(String.init))
    }
    private func missingWavGroup(_ stamp: String, sidecars: Bool = false) throws -> URL {
        let url = audio(stamp)
        for suffix in ["archive-damaged", "archive-repair"] + (sidecars ? ["txt", "raw.txt", "meta.json"] : []) {
            try Data("synthetic".utf8).write(to: url.deletingPathExtension().appendingPathExtension(suffix))
        }
        try AudioArchiveIntegrity.markInvalid(url)
        return url
    }
    private func invalidFirst(_ directory: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted {
            $0.lastPathComponent < $1.lastPathComponent // .archive-invalid sorts before .wav
        }
    }
    private func wavFirst(_ directory: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted {
            $0.lastPathComponent > $1.lastPathComponent // .wav sorts before .archive-invalid
        }
    }
    private func isolatedTrash(_ staging: URL) throws -> URL? {
        let target = directory.appendingPathComponent("trash-\(UUID().uuidString)")
        try RecordingRemoval.moveWithoutReplacing(staging, target)
        return target
    }

    func testRecoveryOnlyAudioRemainsVisibleToRemovalButNotPlayback() throws {
        for suffix in ["archive-damaged", "archive-repair"] {
            let url = audio("100000").deletingPathExtension().appendingPathExtension(suffix)
            try Data("synthetic audio evidence".utf8).write(to: url)
            XCTAssertEqual(RecordingStore.recordingCount(), 1)
            XCTAssertTrue(RecordingStore.hasAudioFiles())
            XCTAssertTrue(RecordingStore.listRecordings().isEmpty)
            try fm.removeItem(at: url)
        }
    }

    func testAudioCountDeduplicatesMixedRecoveryAndPrimaryFiles() throws {
        _ = try publish("100000", repaired: true)
        _ = try missingWavGroup("110000")
        _ = try publish("120000")
        try AudioArchiveIntegrity.markInvalid(audio("130000"))
        XCTAssertEqual(RecordingStore.recordingCount(), 3)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 3)
        XCTAssertEqual(RecordingStore.listRecordings().count, 2)
    }

    func testMarkerOnlyGroupDoesNotCountAsRetainedAudio() throws {
        try AudioArchiveIntegrity.markInvalid(audio("100000"))
        XCTAssertEqual(RecordingStore.recordingCount(), 0)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
        XCTAssertFalse(RecordingStore.hasAudioFiles())
    }

    func testWarmCountRefreshesAfterFailedArchiveAndKeepNoneCleanup() throws {
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
        let url = audio("100000")
        let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.3], writeFailed: true,
            writerFactory: { _ in throw self.injected }))
        let meta = RecordingStore.RecordingMeta(appVersion: "test", engine: "fake", model: "fake", inputDevice: nil,
            date: "2026-10-03", durationSeconds: 1, transcriptChars: 0)
        RecordingStore.finishRecording(audioURL: url, keep: true, raw: "", text: "", meta: meta)
        XCTAssertEqual(RecordingStore.recordingCount(), 1)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 1)
        RecordingStore.finishRecording(audioURL: url, keep: false, raw: "", text: "", meta: meta)
        XCTAssertEqual(RecordingStore.recordingCount(), 0)
        XCTAssertEqual(RecordingStore.cachedRecordingCount(), 0)
    }

    func testPruneRemovesWholeRepairedGroupAndItsRecentIndexEntry() throws {
        let old = try publish("100000", repaired: true), new = try publish("110000")
        XCTAssertEqual(try group(old).count, 5)
        XCTAssertTrue(try index().contains(RecordingActivity.stem(for: old)))
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(old), [], "WAV, raw, transcript, metadata and damaged source must expire together")
        XCTAssertEqual(try index(), [RecordingActivity.stem(for: new)])
        XCTAssertEqual(try group(new).count, 4)
    }

    func testOneKeepNInventoryTreatsRepairedAndPlainWavsTheSame() throws {
        for repaired in [false, true] {
            let root = directory.appendingPathComponent(repaired ? "repaired" : "plain")
            Config.configDirOverride = root; RecordingStore.ensureDirectory()
            let old = try publish("100000", repaired: repaired), failed = try missingWavGroup("110000")
            RecordingStore.prune(maxCount: 1)
            XCTAssertEqual(try group(old), [], "one latest-N budget includes a retained failed take exactly once")
            XCTAssertEqual(try index(), [])
            XCTAssertEqual(try group(failed).count, 3)
        }
        Config.configDirOverride = directory
    }

    func testTranscriptOnlyStrayGroupDoesNotConsumeRetentionBudget() throws {
        let retained = try publish("100000", repaired: true)
        let stray = audio("110000").deletingPathExtension().appendingPathExtension("txt")
        try Data("unrelated old sidecar".utf8).write(to: stray)
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(retained).count, 5)
        XCTAssertEqual(try index(), [RecordingActivity.stem(for: retained)])
        XCTAssertTrue(fm.fileExists(atPath: stray.path))
    }

    func testNewerMarkerOnlyGroupCannotEvictRetainedAudio() throws {
        let retained = try publish("100000"), markerOnly = audio("110000")
        let stray = audio("120000").deletingPathExtension().appendingPathExtension("txt")
        try AudioArchiveIntegrity.markInvalid(markerOnly)
        try Data("unrelated transcript".utf8).write(to: stray)
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(retained).count, 4)
        XCTAssertEqual(try index(), [RecordingActivity.stem(for: retained)])
        XCTAssertEqual(RecordingStore.recordingCount(), 1)
        XCTAssertEqual(try group(markerOnly), [])
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(markerOnly))
        XCTAssertTrue(fm.fileExists(atPath: stray.path))
    }

    func testProtectedMarkerOnlyLeftoverDoesNotEvictAudio() throws {
        let retained = try publish("100000"), markerOnly = audio("110000")
        try AudioArchiveIntegrity.markInvalid(markerOnly)
        let lease = try RecordingActivity.shared.acquire(markerOnly)
        defer { lease.release() }
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(retained).count, 4)
        XCTAssertEqual(try index(), [RecordingActivity.stem(for: retained)])
        XCTAssertEqual(try group(markerOnly).count, 1)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(markerOnly))
    }

    func testRecoveryOnlyGroupPrunesAllCompanionsAndIndex() throws {
        let old = try missingWavGroup("100000", sidecars: true)
        let new = try publish("110000")
        let oldStem = RecordingActivity.stem(for: old), newStem = RecordingActivity.stem(for: new)
        try "\(oldStem)\n\(newStem)\n".write(to: RecordingStore.recentIndexURL, atomically: true, encoding: .utf8)
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(old), [])
        XCTAssertEqual(try index(), [newStem])
    }

    func testProtectedExpiredGroupKeepsItsSidecarsAndIndex() throws {
        let old = try publish("100000", repaired: true), new = try publish("110000")
        let lease = try RecordingActivity.shared.acquire(old)
        defer { lease.release() }
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(old).count, 5)
        XCTAssertEqual(try index(), [RecordingActivity.stem(for: old), RecordingActivity.stem(for: new)])
    }

    func testFailedCanonicalPruneKeepsInvalidMarkerAndAllCompanions() throws {
        let old = try publish("100000"), new = try publish("110000")
        try AudioArchiveIntegrity.markInvalid(old)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordings.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordings.path) }
        RecordingStore.prune(maxCount: 1)
        XCTAssertEqual(try group(old).count, 5)
        XCTAssertEqual(try index(), [RecordingActivity.stem(for: old), RecordingActivity.stem(for: new)])
        AudioArchiveIntegrity.forget(old)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(old), "disk marker must still block after a process restart")
    }

    func testPartialTrashStagingKeepsMarkerWhenCanonicalWavCannotMove() throws {
        let old = try publish("100000"), new = try publish("110000")
        try AudioArchiveIntegrity.markInvalid(old)
        let marker = AudioArchiveIntegrity.marker(for: old)
        let before = try Data(contentsOf: old)
        let result = RecordingRemoval.run(directory: recordings, listDirectory: invalidFirst,
            trash: isolatedTrash, move: { source, destination in
                if source == old { throw self.injected }
                if source == marker { XCTAssertFalse(self.fm.fileExists(atPath: old.path), "marker cannot leave before its invalid WAV") }
                try RecordingRemoval.moveWithoutReplacing(source, destination)
            })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try Data(contentsOf: old), before)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        XCTAssertFalse(fm.fileExists(atPath: new.path), "an unrelated eligible group still moves")
        AudioArchiveIntegrity.forget(old)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(old))
    }

    func testTrashRollbackCannotRestoreWavWhenInvalidMarkerRestoreFails() throws {
        let old = try publish("100000")
        try AudioArchiveIntegrity.markInvalid(old)
        let marker = AudioArchiveIntegrity.marker(for: old)
        let before = try Data(contentsOf: old)
        let result = RecordingRemoval.run(directory: recordings, listDirectory: wavFirst,
            trash: { _ in throw self.injected }, move: { source, destination in
                if destination == marker { throw self.injected }
                try RecordingRemoval.moveWithoutReplacing(source, destination)
            })
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "WAV stays staged until its invalid marker can be restored")
        let recovery = try XCTUnwrap(result.recoveryDirectory)
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(old.lastPathComponent)), before)
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(marker.lastPathComponent).path))
    }

    func testResumedBatchRestorationRequiresMarkerBeforeCanonicalWav() throws {
        let old = try publish("100000")
        try AudioArchiveIntegrity.markInvalid(old)
        let invalid = AudioArchiveIntegrity.marker(for: old)
        let removal = RecordingRemoval.run(directory: recordings, listDirectory: wavFirst, trash: isolatedTrash)
        let recovery = try XCTUnwrap(removal.trashDirectory)
        let journal = recovery.appendingPathComponent(".speakfree-recording-removal.json")
        var contents = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        let files = try wavFirst(recovery).filter { RecordingStore.isRecordingArtifact($0.lastPathComponent) }
        let records: [[String: Any]] = try files.map { file in
            let attributes = try fm.attributesOfItem(atPath: file.path)
            let device = try XCTUnwrap(attributes[.systemNumber] as? NSNumber)
            let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
            return ["name": file.lastPathComponent, "device": device.stringValue, "inode": inode.stringValue,
                    "sha256": SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()]
        }
        contents["restoreTransaction"] = ["stem": RecordingActivity.stem(for: old), "files": records]
        try JSONSerialization.data(withJSONObject: contents).write(to: journal)
        let failed = RecordingRemoval.restoreBatch(recovery, to: recordings, move: { source, destination in
            if destination == invalid { throw self.injected }
            try RecordingRemoval.moveWithoutReplacing(source, destination)
        })
        XCTAssertFalse(failed.succeeded)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(old.lastPathComponent).path))
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(invalid.lastPathComponent).path))
        let retried = RecordingRemoval.restoreBatch(recovery, to: recordings)
        XCTAssertTrue(retried.succeeded)
        AudioArchiveIntegrity.forget(old)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(old))
        XCTAssertTrue(fm.fileExists(atPath: old.path))
    }
}
