// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
import XCTest
@testable import SpeakFreeLib

final class RecordingRemovalTests: XCTestCase {
    private enum FixtureError: Error { case injected }
    private let fm = FileManager.default
    private var root: URL!
    private var recordings: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("recording-trash-tests-\(UUID().uuidString)")
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

    private func artifact(_ id: String, suffix: String = "wav", contents: String? = nil) throws -> URL {
        let path = recordings.appendingPathComponent("recording-2026-01-01-120000-\(id).\(suffix)")
        try Data((contents ?? id).utf8).write(to: path)
        return path
    }

    private func isolatedTrash(_ staged: URL) throws -> URL? {
        let destination = fakeTrash.appendingPathComponent(staged.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(staged, destination)
        return destination
    }

    private func assertSameDirectory(_ actual: URL?, _ expected: URL, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        let left = try fm.attributesOfItem(atPath: actual.path)
        let right = try fm.attributesOfItem(atPath: expected.path)
        XCTAssertEqual(left[.systemFileNumber] as? NSNumber, right[.systemFileNumber] as? NSNumber, file: file, line: line)
        XCTAssertEqual(left[.systemNumber] as? NSNumber, right[.systemNumber] as? NSNumber, file: file, line: line)
    }

    func testAllArtifactsStayTogetherAndForeignDirectoriesAndSymlinksStayUntouched() throws {
        let files = try [artifact("A"), artifact("A", suffix: "meta.json"),
                         artifact("A", suffix: "bt.raw.txt"), artifact("A", suffix: "builtin.raw.txt")]
        let expected = try files.map { try Data(contentsOf: $0) }
        let foreign = recordings.appendingPathComponent("notes.txt")
        try Data("foreign".utf8).write(to: foreign)
        let nested = recordings.appendingPathComponent("recording-2026-01-01-120000-nested.wav")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedFile = nested.appendingPathComponent("keep.txt")
        try Data("nested".utf8).write(to: nestedFile)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = recordings.appendingPathComponent("recording-2026-01-01-120000-link.wav")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removedFiles, 4)
        XCTAssertEqual(result.failedFiles, 0)
        let group = try XCTUnwrap(result.trashDirectory)
        for (index, file) in files.enumerated() {
            XCTAssertFalse(fm.fileExists(atPath: file.path))
            XCTAssertEqual(try Data(contentsOf: group.appendingPathComponent(file.lastPathComponent)), expected[index])
        }
        XCTAssertEqual(try String(contentsOf: foreign), "foreign")
        XCTAssertEqual(try String(contentsOf: nestedFile), "nested")
        XCTAssertEqual(try String(contentsOf: outside), "outside")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertNil(RecordingRemoval.pendingRecoveryDirectory(in: recordings))
    }

    func testTrashThenRestoreReturnsEveryArtifactToItsOriginalPath() throws {
        let files = try [artifact("restore"), artifact("restore", suffix: "txt"),
                         artifact("restore", suffix: "meta.json")]
        let bytes = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let restored = RecordingRemoval.restoreTrashedBatch(trashed, to: recordings)
        XCTAssertTrue(restored.succeeded)
        XCTAssertEqual(restored.restoredFiles, files.count)
        XCTAssertFalse(fm.fileExists(atPath: trashed.path))
        for file in files { XCTAssertEqual(try Data(contentsOf: file), bytes[file.lastPathComponent]) }
    }

    func testRestoreRetainsWholeGroupWhenAnyCompanionHasANewerCollision() throws {
        let audio = try artifact("collision", contents: "old audio")
        let transcript = try artifact("collision", suffix: "txt", contents: "old transcript")
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        try Data("new transcript".utf8).write(to: transcript)
        let restored = RecordingRemoval.restoreTrashedBatch(trashed, to: recordings)
        XCTAssertFalse(restored.succeeded)
        XCTAssertEqual(restored.restoredFiles, 0)
        XCTAssertEqual(restored.retainedFiles, 2)
        XCTAssertFalse(fm.fileExists(atPath: audio.path))
        XCTAssertEqual(try String(contentsOf: transcript), "new transcript")
        let recovery = try XCTUnwrap(restored.recoveryDirectory)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent(audio.lastPathComponent)), "old audio")
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent(transcript.lastPathComponent)), "old transcript")
    }

    func testRestoreRetainsActiveDestinationGroup() throws {
        let audio = try artifact("active", contents: "old audio")
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let destination = recordings.appendingPathComponent(audio.lastPathComponent)
        let lease = try RecordingActivity.shared.acquire(destination)
        defer { lease.release() }
        let restored = RecordingRemoval.restoreTrashedBatch(trashed, to: recordings)
        XCTAssertFalse(restored.succeeded)
        XCTAssertEqual(restored.restoredFiles, 0)
        XCTAssertEqual(restored.retainedFiles, 1)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testRestoreResumesAGroupAfterMidGroupFailure() throws {
        let files = try [artifact("rollback"), artifact("rollback", suffix: "txt")]
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let recovery = root.appendingPathComponent(trashed.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(trashed, recovery)
        var moves = 0
        let restored = RecordingRemoval.restoreBatch(recovery, to: recordings) { source, destination in
            moves += 1
            if moves == 2 { throw FixtureError.injected }
            try RecordingRemoval.moveWithoutReplacing(source, destination)
        }
        XCTAssertFalse(restored.succeeded)
        XCTAssertEqual(restored.restoredFiles, 1)
        XCTAssertEqual(restored.retainedFiles, 1)
        XCTAssertEqual(files.filter { fm.fileExists(atPath: $0.path) }.count, 1)
        XCTAssertEqual(files.filter { fm.fileExists(atPath: recovery.appendingPathComponent($0.lastPathComponent).path) }.count, 1)

        let retried = RecordingRemoval.restoreBatch(recovery, to: recordings)
        XCTAssertTrue(retried.succeeded)
        XCTAssertEqual(retried.restoredFiles, 1)
        for file in files { XCTAssertTrue(fm.fileExists(atPath: file.path)) }
    }

    func testRestoreRetryDoesNotMixOldSidecarWithReplacedAudio() throws {
        let audio = try artifact("generation", contents: "old audio")
        let transcript = try artifact("generation", suffix: "txt", contents: "old transcript")
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let recovery = root.appendingPathComponent(trashed.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(trashed, recovery)
        var moves = 0
        _ = RecordingRemoval.restoreBatch(recovery, to: recordings) { source, destination in
            moves += 1
            if moves == 2 { throw FixtureError.injected }
            try RecordingRemoval.moveWithoutReplacing(source, destination)
        }
        let restoredName = try XCTUnwrap([audio, transcript].first { fm.fileExists(atPath: $0.path) })
        let retainedName = [audio, transcript].first { $0 != restoredName }!
        try fm.removeItem(at: restoredName)
        try Data("new generation".utf8).write(to: restoredName)

        let retried = RecordingRemoval.restoreBatch(recovery, to: recordings)
        XCTAssertFalse(retried.succeeded)
        XCTAssertEqual(try String(contentsOf: restoredName), "new generation")
        XCTAssertFalse(fm.fileExists(atPath: retainedName.path))
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(retainedName.lastPathComponent).path))
    }

    func testRestoreRetryDoesNotMixWhenOldSourceAndNewDestinationBothExist() throws {
        let audio = try artifact("blocked-generation", contents: "old audio")
        let transcript = try artifact("blocked-generation", suffix: "txt", contents: "old transcript")
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let recovery = root.appendingPathComponent(trashed.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(trashed, recovery)
        _ = RecordingRemoval.restoreBatch(recovery, to: recordings) { _, _ in throw FixtureError.injected }
        try Data("new audio".utf8).write(to: audio)

        let retried = RecordingRemoval.restoreBatch(recovery, to: recordings)
        XCTAssertFalse(retried.succeeded)
        XCTAssertEqual(try String(contentsOf: audio), "new audio")
        XCTAssertFalse(fm.fileExists(atPath: transcript.path))
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(transcript.lastPathComponent).path))
    }

    func testRestoreRetryDetectsInPlaceContentChangeWithSameInode() throws {
        let files = try [artifact("in-place", contents: "old audio"),
                         artifact("in-place", suffix: "txt", contents: "old transcript")]
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let recovery = root.appendingPathComponent(trashed.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(trashed, recovery)
        var moves = 0
        _ = RecordingRemoval.restoreBatch(recovery, to: recordings) { source, destination in
            moves += 1
            if moves == 2 { throw FixtureError.injected }
            try RecordingRemoval.moveWithoutReplacing(source, destination)
        }
        let restored = try XCTUnwrap(files.first { fm.fileExists(atPath: $0.path) })
        let retained = files.first { $0 != restored }!
        let inodeBefore = try XCTUnwrap((fm.attributesOfItem(atPath: restored.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
        let handle = try FileHandle(forWritingTo: restored)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("changed in place".utf8))
        try handle.close()
        let inodeAfter = try XCTUnwrap((fm.attributesOfItem(atPath: restored.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
        XCTAssertEqual(inodeBefore, inodeAfter)

        let retried = RecordingRemoval.restoreBatch(recovery, to: recordings)
        XCTAssertFalse(retried.succeeded)
        XCTAssertFalse(fm.fileExists(atPath: retained.path))
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(retained.lastPathComponent).path))
    }

    func testFailedGroupKeepsLedgerAndDoesNotStartNextGroup() throws {
        _ = try artifact("first", contents: "first audio")
        _ = try artifact("first", suffix: "txt", contents: "first transcript")
        let second = try artifact("second", contents: "second audio")
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let recovery = root.appendingPathComponent(trashed.lastPathComponent)
        try RecordingRemoval.moveWithoutReplacing(trashed, recovery)
        var moves = 0
        let firstAttempt = RecordingRemoval.restoreBatch(recovery, to: recordings) { source, destination in
            moves += 1
            if moves == 2 { throw FixtureError.injected }
            try RecordingRemoval.moveWithoutReplacing(source, destination)
        }
        XCTAssertFalse(firstAttempt.succeeded)
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent(second.lastPathComponent).path))

        let retried = RecordingRemoval.restoreBatch(recovery, to: recordings)
        XCTAssertTrue(retried.succeeded)
        XCTAssertTrue(fm.fileExists(atPath: second.path))
    }

    func testRestoreRejectsSymlinkDestination() throws {
        _ = try artifact("symlink-destination")
        let removed = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        let trashed = try XCTUnwrap(removed.trashDirectory)
        let realDestination = root.appendingPathComponent("real-recordings", isDirectory: true)
        try fm.createDirectory(at: realDestination, withIntermediateDirectories: true)
        try fm.removeItem(at: recordings)
        try fm.createSymbolicLink(at: recordings, withDestinationURL: realDestination)

        let restored = RecordingRemoval.restoreTrashedBatch(trashed, to: recordings)
        XCTAssertFalse(restored.succeeded)
        XCTAssertTrue(fm.fileExists(atPath: trashed.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: realDestination.path), [])
    }

    func testPartialStagingFailureCountsOnlyActuallyTrashedFiles() throws {
        let good = try artifact("good")
        let denied = try artifact("denied")
        var denials = 0
        let result = RecordingRemoval.run(directory: recordings, trash: isolatedTrash) { source, destination in
            if source.lastPathComponent == denied.lastPathComponent { denials += 1; throw FixtureError.injected }
            try RecordingRemoval.moveWithoutReplacing(source, destination)
        }
        XCTAssertEqual(denials, 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(result.failedFiles, 1)
        XCTAssertTrue(fm.fileExists(atPath: denied.path))
        XCTAssertFalse(fm.fileExists(atPath: good.path))
        let group = try XCTUnwrap(result.trashDirectory)
        XCTAssertEqual(try String(contentsOf: group.appendingPathComponent(good.lastPathComponent)), "good")
        XCTAssertNil(result.recoveryDirectory)
    }

    func testTrashFailureRestoresEveryFileWithoutLeavingPendingFolder() throws {
        let files = try [artifact("A"), artifact("B")]
        let result = RecordingRemoval.run(directory: recordings, trash: { _ in throw FixtureError.injected })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertEqual(result.failedFiles, 2)
        XCTAssertNil(result.recoveryDirectory)
        XCTAssertNil(RecordingRemoval.pendingRecoveryDirectory(in: recordings))
        XCTAssertEqual(try files.map { try String(contentsOf: $0) }, ["A", "B"])
    }

    func testRollbackNeverOverwritesNewFileAndPendingGroupBlocksAnotherRemoval() throws {
        let file = try artifact("original", contents: "old audio")
        let result = RecordingRemoval.run(directory: recordings, trash: { _ in
            try Data("new audio".utf8).write(to: file)
            throw FixtureError.injected
        })
        XCTAssertEqual(try String(contentsOf: file), "new audio")
        let recovery = try XCTUnwrap(result.recoveryDirectory)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent(file.lastPathComponent)), "old audio")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedFiles, 1)
        try assertSameDirectory(RecordingRemoval.pendingRecoveryDirectory(in: recordings), recovery)
        let blocked = RecordingRemoval.run(directory: recordings, trash: { _ in
            XCTFail("Pending recovery must be made visible before another Trash operation")
            return nil
        })
        try assertSameDirectory(blocked.recoveryDirectory, recovery)
        XCTAssertFalse(blocked.succeeded)
        XCTAssertEqual(try String(contentsOf: file), "new audio")
    }

    func testRollbackPreservesNewDanglingSymlink() throws {
        let file = try artifact("old")
        let destination = root.appendingPathComponent("does-not-exist")
        let result = RecordingRemoval.run(directory: recordings, trash: { _ in
            try self.fm.createSymbolicLink(at: file, withDestinationURL: destination)
            throw FixtureError.injected
        })
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: file.path), destination.path)
        let recovery = try XCTUnwrap(result.recoveryDirectory)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent(file.lastPathComponent)), "old")
        XCTAssertFalse(result.succeeded)
    }

    func testAtomicMoverRejectsEveryOccupiedDestination() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)
        XCTAssertThrowsError(try RecordingRemoval.moveWithoutReplacing(source, destination))
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertEqual(try String(contentsOf: destination), "destination")
        try fm.removeItem(at: destination)
        try fm.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertThrowsError(try RecordingRemoval.moveWithoutReplacing(source, destination))
        XCTAssertEqual(try String(contentsOf: source), "source")
    }

    func testTotalStagingFailureDoesNotCallTrashOrLeaveMarkerFolder() throws {
        let file = try artifact("A")
        let result = RecordingRemoval.run(directory: recordings, trash: { _ in
            XCTFail("Nothing moved; Trash must not be called")
            return nil
        }, move: { _, _ in throw FixtureError.injected })
        XCTAssertEqual(result.failedFiles, 1)
        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertNil(result.recoveryDirectory)
        XCTAssertNil(RecordingRemoval.pendingRecoveryDirectory(in: recordings))
        XCTAssertEqual(try String(contentsOf: file), "A")
    }

    func testSourceEnumerationFailureAndSourceDirectorySymlinkDoNotTraverse() throws {
        let file = try artifact("A")
        let movedDirectory = root.appendingPathComponent("actual-recordings")
        try fm.moveItem(at: recordings, to: movedDirectory)
        try fm.createSymbolicLink(at: recordings, withDestinationURL: movedDirectory)
        var result = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        XCTAssertTrue(result.enumerationFailed)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try String(contentsOf: movedDirectory.appendingPathComponent(file.lastPathComponent)), "A")
        try fm.removeItem(at: recordings)
        try Data("not a directory".utf8).write(to: recordings)
        result = RecordingRemoval.run(directory: recordings, trash: isolatedTrash)
        XCTAssertTrue(result.enumerationFailed)
        XCTAssertEqual(try String(contentsOf: recordings), "not a directory")
    }

    func testAbsentAndEmptyDirectoriesAreSuccessfulWithoutCallingTrash() throws {
        let empty = RecordingRemoval.run(directory: recordings, trash: { _ in XCTFail("Trash must not be called for this fixture"); return nil })
        XCTAssertTrue(empty.succeeded)
        try fm.removeItem(at: recordings)
        let absent = RecordingRemoval.run(directory: recordings, trash: { _ in XCTFail("Trash must not be called for this fixture"); return nil })
        XCTAssertTrue(absent.succeeded)
    }

    func testUnreadableSourceReportsEnumerationFailureAndPreservesFiles() throws {
        let file = try artifact("A")
        try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: recordings.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordings.path) }
        let result = RecordingRemoval.run(directory: recordings, trash: { _ in XCTFail("Trash must not be called for this fixture"); return nil })
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.enumerationFailed)
        XCTAssertEqual(try String(contentsOf: file), "A")
    }

    func testFalseSuccessfulTrashResponseIsDetectedAndRolledBack() throws {
        let file = try artifact("A")
        let result = RecordingRemoval.run(directory: recordings, trash: { _ in self.fakeTrash })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertEqual(result.failedFiles, 1)
        XCTAssertEqual(try String(contentsOf: file), "A")
        XCTAssertNil(result.recoveryDirectory)
    }

    func testRollbackDoesNotRemoveForeignFileThatArrivedInStagingFolder() throws {
        _ = try artifact("A")
        let result = RecordingRemoval.run(directory: recordings, trash: { staging in
            try Data("foreign".utf8).write(to: staging.appendingPathComponent("keep.txt"))
            throw FixtureError.injected
        })
        let recovery = try XCTUnwrap(result.recoveryDirectory)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("keep.txt")), "foreign")
        try assertSameDirectory(RecordingRemoval.pendingRecoveryDirectory(in: recordings), recovery)
    }

    func testProgressIsBoundedMonotonicAndReportsElapsedMovingAndFinishing() throws {
        for number in 0..<10 { _ = try artifact(String(number)) }
        let capture = ProgressCapture()
        let result = RecordingRemoval.run(directory: recordings, progress: { capture.append($0) }, trash: isolatedTrash) {
            Thread.sleep(forTimeInterval: 0.015)
            try RecordingRemoval.moveWithoutReplacing($0, $1)
        }
        XCTAssertTrue(result.succeeded)
        let updates = capture.values
        XCTAssertEqual(updates.first?.phase, .preparing)
        XCTAssertEqual(updates.last?.phase, .finishing)
        XCTAssertEqual(updates.last?.completed, 10)
        XCTAssertGreaterThan(result.elapsedSeconds, 0.1)
        XCTAssertLessThanOrEqual(updates.count, Int(ceil(result.elapsedSeconds / 0.05)) + 4)
        for update in updates {
            XCTAssertGreaterThanOrEqual(update.completed, 0)
            XCTAssertLessThanOrEqual(update.completed, update.total)
            XCTAssertLessThanOrEqual(update.elapsedSeconds, result.elapsedSeconds)
        }
        for (prior, next) in zip(updates, updates.dropFirst()) {
            XCTAssertLessThanOrEqual(prior.completed, next.completed)
            XCTAssertLessThanOrEqual(prior.elapsedSeconds, next.elapsedSeconds)
            if prior.phase == .moving && next.phase == .moving && next.completed != next.total {
                XCTAssertGreaterThanOrEqual(next.elapsedSeconds - prior.elapsedSeconds, 0.049)
            }
        }
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingRemoval.Progress] = []
    func append(_ progress: RecordingRemoval.Progress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(progress)
    }
    var values: [RecordingRemoval.Progress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
