// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import AVFoundation
import XCTest
@testable import SpeakFreeLib

final class RecordingRemovalActivityTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var recordings: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recording-activity-\(UUID())")
        recordings = root.appendingPathComponent("recordings")
        fakeTrash = root.appendingPathComponent("fake-trash")
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        Config.configDirOverride = root
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = nil
        try fm.removeItem(at: root)
    }

    private func url(_ id: String) -> URL {
        recordings.appendingPathComponent("recording-2026-01-01-120000-\(id).wav")
    }

    private func closedWAV(_ id: String) throws -> URL {
        let path = url(id)
        let writer = try WavWriter(url: path)
        try writer.append(Array(repeating: 0.1, count: 16_000))
        writer.close()
        return path
    }

    private func isolatedTrash(_ staged: URL) throws -> URL? {
        let destination = fakeTrash.appendingPathComponent(staged.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(staged, destination)
        return destination
    }

    private func meta() -> RecordingStore.RecordingMeta {
        .init(appVersion: "synthetic", engine: "synthetic", model: "none", inputDevice: nil,
              date: "2026-01-01T12:00:00Z", durationSeconds: 1, transcriptChars: 9)
    }

    func testOpenWAVAndAllItsSidecarsRemainAtOriginalPaths() throws {
        let active = url("active"), archived = try closedWAV("archived")
        let writer = try WavWriter(url: active)
        try writer.append(Array(repeating: 0.1, count: 8_000))
        RecordingStore.writeSentinel(recordingURL: active)
        RecordingStore.saveAuxiliaryTranscription(text: "synthetic", kind: .whisper, for: active)
        let result = RecordingStore.trashAllRecordings(trash: isolatedTrash)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(result.retainedRecordings, 1)
        XCTAssertTrue(fm.fileExists(atPath: active.path))
        XCTAssertTrue(fm.fileExists(atPath: active.deletingPathExtension().appendingPathExtension("whisper.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: archived.path))
        try writer.append(Array(repeating: 0.2, count: 8_000))
        writer.close()
        XCTAssertEqual(try AVAudioFile(forReading: active).length, 16_000)
        RecordingStore.finishRecording(audioURL: active, keep: true, raw: "synthetic", text: "synthetic", meta: meta())
        XCTAssertNotNil(RecordingStore.loadMeta(for: active))
    }

    func testNewTakeCanStartAndFinalizeWhileNativeTrashIsBlocked() throws {
        _ = try closedWAV("old")
        let entered = expectation(description: "fake native Trash entered")
        let removed = expectation(description: "Trash completed")
        let newFinished = expectation(description: "new take finalized before Trash returned")
        let unblock = DispatchSemaphore(value: 0)
        let fakeTrash = try XCTUnwrap(self.fakeTrash)
        DispatchQueue.global().async {
            let result = RecordingStore.trashAllRecordings(trash: { staged in
                entered.fulfill()
                guard unblock.wait(timeout: .now() + 5) == .success else {
                    throw NSError(domain: "synthetic-timeout", code: 1)
                }
                let destination = fakeTrash.appendingPathComponent(staged.lastPathComponent)
                try RecordingRemoval.moveWithoutReplacing(staged, destination)
                return destination
            })
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.retainedRecordings, 1)
            removed.fulfill()
        }
        wait(for: [entered], timeout: 2)
        let newURL = url("new"), meta = meta()
        DispatchQueue.global().async {
            do {
                let writer = try WavWriter(url: newURL)
                try writer.append(Array(repeating: 0.1, count: 16_000))
                writer.close()
                RecordingStore.finishRecording(audioURL: newURL, keep: true,
                    raw: "synthetic", text: "synthetic", meta: meta)
                newFinished.fulfill()
            } catch { XCTFail("New recording failed: \(error)") }
        }
        let finished = XCTWaiter.wait(for: [newFinished], timeout: 2)
        unblock.signal()
        wait(for: [removed], timeout: 3)
        XCTAssertEqual(finished, .completed, "Trash must not hold the publication mutex")
        XCTAssertTrue(fm.fileExists(atPath: newURL.path))
        XCTAssertNotNil(RecordingStore.loadMeta(for: newURL))
    }

    func testTakeCompletedDuringEnumerationIsExcludedFromThatDeletionEpoch() throws {
        let old = try closedWAV("old"), fresh = url("fresh")
        let result = RecordingStore.trashAllRecordings(progress: { progress in
            guard progress.phase == .preparing else { return }
            do {
                let writer = try WavWriter(url: fresh)
                try writer.append([0.1, 0.2]); writer.close()
            } catch { XCTFail("Synthetic creation failed: \(error)") }
        }, trash: isolatedTrash)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.retainedRecordings, 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
    }

    func testFinalizerLeaseAndQueuedChildKeepAudioAfterWriterCloses() throws {
        let audio = url("finalizing")
        let finalizer = try RecordingActivity.shared.acquire(audio)
        let writer = try WavWriter(url: audio)
        try writer.append(Array(repeating: 0.1, count: 16_000)); writer.close()
        let child = try RecordingActivity.shared.acquire(audio)
        finalizer.release()
        let protected = RecordingStore.trashAllRecordings(trash: isolatedTrash)
        XCTAssertEqual(protected.retainedRecordings, 1)
        RecordingStore.saveAuxiliaryTranscription(text: "synthetic", kind: .whisper, for: audio)
        child.release()
        let complete = RecordingStore.trashAllRecordings(trash: isolatedTrash)
        XCTAssertEqual(complete.removedFiles, 2)
    }

    func testLateSidecarCannotResurrectRemovedAudio() throws {
        let audio = try closedWAV("removed")
        XCTAssertTrue(RecordingStore.trashAllRecordings(trash: isolatedTrash).succeeded)
        RecordingStore.saveTranscription(text: "synthetic", for: audio)
        RecordingStore.saveRaw(text: "synthetic", for: audio)
        RecordingStore.saveAuxiliaryTranscription(text: "synthetic", kind: .whisper, for: audio)
        RecordingStore.saveMeta(meta(), for: audio)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: recordings.path), [])
    }

    func testOldFinalizerCannotClearNewTakeSentinel() throws {
        let old = try closedWAV("old"), current = try closedWAV("current")
        RecordingStore.writeSentinel(recordingURL: old)
        RecordingStore.writeSentinel(recordingURL: current)
        RecordingStore.clearSentinel(recordingURL: old)
        XCTAssertEqual(RecordingStore.checkCrashRecovery(), current)
        RecordingStore.clearSentinel(recordingURL: current)
        XCTAssertNil(RecordingStore.checkCrashRecovery())
    }

    func testDirectoryAliasReaderProtectsCanonicalRecordingPath() throws {
        let audio = try closedWAV("aliased")
        let alias = root.appendingPathComponent("recordings-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: recordings)
        let reader = try RecordingActivity.shared.acquire(alias.appendingPathComponent(audio.lastPathComponent))
        let result = RecordingStore.trashAllRecordings(trash: isolatedTrash)
        XCTAssertEqual(result.retainedRecordings, 1)
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
        reader.release()
    }

    func testIndividualFileAliasReaderProtectsCanonicalRecordingPath() throws {
        let audio = try closedWAV("aliased-file")
        let alias = root.appendingPathComponent("single-file-alias.wav")
        try fm.createSymbolicLink(at: alias, withDestinationURL: audio)
        let reader = try RecordingActivity.shared.acquireReading(alias)
        let result = RecordingStore.trashAllRecordings(trash: isolatedTrash)
        XCTAssertEqual(result.retainedRecordings, 1)
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
        reader.release()
    }

    func testLegacyDeleteAndPruneHonorActiveGroup() throws {
        let active = try closedWAV("active"), other = try closedWAV("other")
        let lease = try RecordingActivity.shared.acquire(active)
        let deleted = RecordingStore.deleteAllRecordings()
        XCTAssertEqual(deleted.removedFiles, 1)
        XCTAssertTrue(fm.fileExists(atPath: active.path))
        XCTAssertFalse(fm.fileExists(atPath: other.path))
        _ = try closedWAV("newer")
        RecordingStore.prune(maxCount: 1)
        XCTAssertTrue(fm.fileExists(atPath: active.path))
        lease.release()
    }
}
