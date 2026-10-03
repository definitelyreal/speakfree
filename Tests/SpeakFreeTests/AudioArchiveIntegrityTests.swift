// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
import XCTest
@testable import SpeakFreeLib

private final class ArchiveCapture: DeviceCapturing {
    var deliver: ((CapturePacket) -> Void)?
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void) { deliver = packet }
    func stop() {}
}

final class AudioArchiveIntegrityTests: XCTestCase {
    private var directory: URL!
    private var previousConfig: URL?
    private let injected = NSError(domain: NSPOSIXErrorDomain, code: 28)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/26-10-02-pinned-audio/fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        previousConfig = Config.configDirOverride
        Config.configDirOverride = directory
    }
    override func tearDownWithError() throws {
        Config.configDirOverride = previousConfig
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeRecorder(
        fault: @escaping (URL, WavWriter.IOOperation) throws -> Void = { _, _ in },
        install: @escaping (URL, URL) throws -> Void = { try WavWriter.installReplacement($0, at: $1) }
    ) -> (AudioRecorder, ArchiveCapture) {
        let device = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in", isBuiltIn: true,
                                     isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
        let source = ArchiveCapture()
        let recorder = AudioRecorder(factory: { source }, writerFactory: { url in
            try WavWriter(url: url, beforeIO: { try fault(url, $0) })
        }, installArchive: install)
        recorder.capture.configure(devices: [device], systemDefault: device, pin: nil, prelisten: true)
        recorder.capture.start(); recorder.capture.queue.sync {}
        return (recorder, source)
    }
    private func feed(_ source: ArchiveCapture, _ recorder: AudioRecorder, _ values: [Float], at: Double = 0) {
        source.deliver?(CapturePacket(start: at, samples: values))
        recorder.capture.queue.sync {}
        _ = recorder.currentSamples()
    }
    private func stop(_ recorder: AudioRecorder) {
        recorder.shutdown(); recorder.capture.queue.sync {}
    }
    private func assertPCM(_ url: URL, _ samples: [Float], file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44 + samples.count * 2, file: file, line: line)
        XCTAssertEqual(bytes.dropFirst(44), WavWriter.pcmData(samples), file: file, line: line)
        XCTAssertTrue(try WavWriter.matchesHeader(url, sampleCount: samples.count), file: file, line: line)
    }

    func testFailedTruncateRepairsNonemptyArchiveAndKeepsExactOldBytes() throws {
        let (recorder, source) = makeRecorder { _, op in if op == .truncate { throw self.injected } }
        defer { stop(recorder) }
        let url = directory.appendingPathComponent("take.wav")
        try recorder.startRecording(to: url)
        let first = [Float](repeating: 0.2, count: 1600)
        feed(source, recorder, first)
        recorder.capture.queue.sync { recorder.replaceTail(from: 400, with: [Float](repeating: -0.3, count: 800), source: "replacement") }
        let last = [Float](repeating: 0.1, count: 320)
        feed(source, recorder, last, at: 0.1)
        let result = try XCTUnwrap(recorder.stopRecording())
        let expected = Array(first.prefix(400)) + [Float](repeating: -0.3, count: 800) + last
        XCTAssertEqual(result.samples, expected)
        XCTAssertTrue(result.audioFileIsValid, result.archiveError ?? "")
        try assertPCM(result.url, expected)
        try assertPCM(AudioRecorder.recoveryArtifactURLs(for: url)[0], first)
    }

    func testPartialPCMWriteIsRepairedEvenForSubsecondTake() throws {
        var failed = false
        let (recorder, source) = makeRecorder { url, op in
            if url.pathExtension == "wav", op == .append, !failed {
                failed = true
                // Model a real short write: bytes land on disk before ENOSPC is reported.
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd(); try handle.write(contentsOf: Data([1, 2, 3])); try handle.close()
                throw self.injected
            }
        }
        defer { stop(recorder) }
        let url = directory.appendingPathComponent("take.wav")
        try recorder.startRecording(to: url)
        let expected = [Float](repeating: 0.15, count: 640)
        feed(source, recorder, expected)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertTrue(failed)
        XCTAssertTrue(result.audioFileIsValid)
        try assertPCM(url, expected)
        XCTAssertEqual(try Data(contentsOf: AudioRecorder.recoveryArtifactURLs(for: url)[0]).suffix(3), Data([1, 2, 3]))
    }

    func testHeaderAndCloseFailuresAreAllReportedAndRepaired() throws {
        for point: WavWriter.IOOperation in [.patchRIFF, .patchData, .seekEnd, .close] {
            let (recorder, source) = makeRecorder { url, op in
                if url.pathExtension == "wav", op == point { throw self.injected }
            }
            let url = directory.appendingPathComponent("\(point).wav")
            try recorder.startRecording(to: url)
            let expected = [Float](repeating: 0.25, count: 1600)
            feed(source, recorder, expected)
            let result = try XCTUnwrap(recorder.stopRecording())
            XCTAssertTrue(result.audioFileIsValid, "\(point): \(result.archiveError ?? "")")
            try assertPCM(url, expected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: AudioRecorder.recoveryArtifactURLs(for: url)[0].path))
            stop(recorder)
        }
    }

    func testPeriodicHeaderFailureIsStickyEvenWhenFinalPatchSucceeds() throws {
        var failed = false
        let (recorder, source) = makeRecorder { url, op in
            if url.pathExtension == "wav", op == .patchData, !failed { failed = true; throw self.injected }
        }
        defer { stop(recorder) }
        let url = directory.appendingPathComponent("long.wav")
        try recorder.startRecording(to: url)
        let expected = [Float](repeating: 0.2, count: 80_000)
        feed(source, recorder, expected)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertTrue(result.audioFileIsValid)
        try assertPCM(url, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioRecorder.recoveryArtifactURLs(for: url)[0].path))
    }

    func testFailedRepairRetainsMemoryAndDamageButWithdrawsWav() throws {
        let (recorder, source) = makeRecorder { _, op in if op == .append { throw self.injected } }
        defer { stop(recorder) }
        let url = directory.appendingPathComponent("take.wav")
        try recorder.startRecording(to: url)
        let expected = [Float](repeating: 0.2, count: 1600)
        feed(source, recorder, expected)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertEqual(result.samples, expected)
        XCTAssertFalse(result.audioFileIsValid)
        XCTAssertNotNil(result.archiveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "stale WAV must not become a later orphan input")
        for artifact in AudioRecorder.recoveryArtifactURLs(for: url) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
            let permissions = try FileManager.default.attributesOfItem(atPath: artifact.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testFailedAtomicInstallLeavesCompleteCandidateAndOriginalEvidence() throws {
        var admitted = false
        let expected = [Float](repeating: -0.2, count: 800)
        let (recorder, source) = makeRecorder(fault: { url, op in
            if url.pathExtension == "wav", op == .append { throw self.injected }
        }, install: { candidate, original in
            admitted = true
            try self.assertPCM(candidate, expected)
            XCTAssertEqual(try Data(contentsOf: original).count, 44, "original must survive through candidate validation")
            throw self.injected
        })
        defer { stop(recorder) }
        let url = directory.appendingPathComponent("take.wav")
        try recorder.startRecording(to: url); feed(source, recorder, expected)
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertTrue(admitted)
        XCTAssertFalse(result.audioFileIsValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try assertPCM(AudioRecorder.recoveryArtifactURLs(for: url)[1], expected)
    }

    func testNormalPathDoesNotRewriteAndMissingOrInvalidHeaderIsRepaired() throws {
        let expected = [Float](repeating: 0.25, count: 1600)
        let valid = directory.appendingPathComponent("valid.wav")
        let writer = try WavWriter(url: valid); try writer.append(expected); try writer.finish()
        var rewrites = 0
        let factory: (URL) throws -> WavWriter = { rewrites += 1; return try WavWriter(url: $0) }
        try AudioRecorder.finalizeArchive(url: valid, samples: expected, writeFailed: false, writerFactory: factory)
        XCTAssertEqual(rewrites, 0)
        let invalid = directory.appendingPathComponent("invalid.wav")
        try Data(repeating: 0, count: 44 + expected.count * 2).write(to: invalid)
        try AudioRecorder.finalizeArchive(url: invalid, samples: expected, writeFailed: false, writerFactory: factory)
        let missing = directory.appendingPathComponent("missing.wav")
        try AudioRecorder.finalizeArchive(url: missing, samples: expected, writeFailed: false, writerFactory: factory)
        XCTAssertEqual(rewrites, 2)
        try assertPCM(invalid, expected); try assertPCM(missing, expected)
    }

    func testRecoveryEvidenceRefusesToOverwritePreviousAttempt() throws {
        let url = directory.appendingPathComponent("take.wav")
        let backup = AudioRecorder.recoveryArtifactURLs(for: url)[0]
        try Data([9, 8, 7]).write(to: backup)
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.2], writeFailed: true))
        XCTAssertEqual(try Data(contentsOf: backup), Data([9, 8, 7]))
    }

    func testRecoveryArtifactsShareLeaseAndKeepNoneCleanup() throws {
        RecordingStore.ensureDirectory()
        let url = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-02-120000-AAAAAAAA.wav")
        for artifact in [url] + AudioRecorder.recoveryArtifactURLs(for: url) {
            try Data([1]).write(to: artifact)
            XCTAssertEqual(RecordingActivity.group(for: artifact), RecordingActivity.group(for: url))
            XCTAssertTrue(RecordingStore.isRecordingArtifact(artifact.lastPathComponent))
        }
        let lease = try RecordingActivity.shared.acquire(url)
        let removal = RecordingActivity.shared.beginRemoval(in: RecordingStore.recordingsDir)
        for artifact in AudioRecorder.recoveryArtifactURLs(for: url) { XCTAssertFalse(removal.claim(artifact)) }
        removal.finish(); lease.release()
        let meta = RecordingStore.RecordingMeta(appVersion: "test", engine: "fake", model: "fake", inputDevice: nil,
            date: "2026-10-02", durationSeconds: 1, transcriptChars: 0, targetApp: nil)
        RecordingStore.finishRecording(audioURL: url, keep: false, raw: "", text: "", meta: meta)
        for artifact in [url] + AudioRecorder.recoveryArtifactURLs(for: url) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        }
    }

    func testRetentionPrunesOldFailedArchiveWithoutWavAndDeleteAllFindsRemaining() throws {
        RecordingStore.ensureDirectory()
        let old = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-01-120000-AAAAAAAA.wav")
        let recent = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-02-120000-BBBBBBBB.wav")
        for url in [old, recent] {
            for artifact in AudioRecorder.recoveryArtifactURLs(for: url) { try Data([1]).write(to: artifact) }
        }
        RecordingStore.prune(maxCount: 1)
        for artifact in AudioRecorder.recoveryArtifactURLs(for: old) { XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path)) }
        for artifact in AudioRecorder.recoveryArtifactURLs(for: recent) { XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path)) }
        _ = RecordingStore.deleteAllRecordings()
        for artifact in AudioRecorder.recoveryArtifactURLs(for: recent) { XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path)) }
    }
    func testPreservationAndWithdrawalFailuresBlockOriginalAcrossRestartMarker() throws {
        RecordingStore.ensureDirectory()
        let url = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-02-120000-CCCCCCCC.wav")
        let old = [Float](repeating: 0.3, count: 64_000)
        let writer = try WavWriter(url: url); try writer.append(old); try writer.finish()
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.2], writeFailed: true,
            beforeIO: { op in if op == .preserve || op == .withdraw { throw self.injected } }))
        XCTAssertEqual(try Data(contentsOf: url), original, "failed preservation must never destroy source bytes")
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioArchiveIntegrity.marker(for: url).path))
        AudioArchiveIntegrity.forget(url) // new-process simulation: only the durable marker remains.
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: url.path)
        XCTAssertTrue(RecordingStore.sweepRecoverableOrphans(minSeconds: 0).isEmpty)
        // A later successful repair removes both the marker and process-local block.
        try AudioRecorder.finalizeArchive(url: url, samples: [0.2], writeFailed: true)
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioArchiveIntegrity.marker(for: url).path))
        try assertPCM(url, [0.2])
    }

    func testMarkerCreationFailureStillBlocksCurrentProcessWhenAllMutationsFail() throws {
        let url = directory.appendingPathComponent("take.wav")
        let writer = try WavWriter(url: url); try writer.append([0.25]); try writer.finish()
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.5], writeFailed: true,
                                                              beforeIO: { _ in throw self.injected }))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioArchiveIntegrity.marker(for: url).path))
        // Explicit deletion cleans the in-process block even when no artifact was written.
        try FileManager.default.removeItem(at: url)
        AudioRecorder.discardRecoveryArtifacts(for: url)
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(url))
    }

    func testRepairSyncFailurePreservesArtifactsAndBlocksWav() throws {
        let (recorder, source) = makeRecorder { url, op in
            if (url.pathExtension == "wav" && op == .append) || op == .synchronize { throw self.injected }
        }
        defer { stop(recorder) }
        let url = directory.appendingPathComponent("take.wav")
        try recorder.startRecording(to: url); feed(source, recorder, [0.2])
        let result = try XCTUnwrap(recorder.stopRecording())
        XCTAssertFalse(result.audioFileIsValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioRecorder.recoveryArtifactURLs(for: url)[1].path))
        AudioRecorder.discardRecoveryArtifacts(for: url)
    }

    func testExistingRepairEvidenceWithdrawsCanonicalWithoutOverwritingEvidence() throws {
        let url = directory.appendingPathComponent("take.wav")
        let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        let original = try Data(contentsOf: url), artifacts = AudioRecorder.recoveryArtifactURLs(for: url)
        let earlier = Data("earlier recovery candidate".utf8)
        try earlier.write(to: artifacts[1])
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.4], writeFailed: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: artifacts[0]), original)
        XCTAssertEqual(try Data(contentsOf: artifacts[1]), earlier)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url))
        AudioRecorder.discardRecoveryArtifacts(for: url)
    }

    func testExistingDamagedHardLinkAllowsSafeCanonicalWithdrawal() throws {
        let url = directory.appendingPathComponent("take.wav")
        let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        let original = try Data(contentsOf: url), damaged = AudioRecorder.recoveryArtifactURLs(for: url)[0]
        try FileManager.default.linkItem(at: url, to: damaged)
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.4], writeFailed: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: damaged), original)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url))
        AudioRecorder.discardRecoveryArtifacts(for: url)
    }

    func testDifferentExistingDamagedEvidencePreservesBothBlockedFiles() throws {
        let url = directory.appendingPathComponent("take.wav")
        let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        let original = try Data(contentsOf: url), damaged = AudioRecorder.recoveryArtifactURLs(for: url)[0]
        let earlier = Data("different retained damaged evidence".utf8)
        try earlier.write(to: damaged)
        XCTAssertThrowsError(try AudioRecorder.finalizeArchive(url: url, samples: [0.4], writeFailed: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: damaged), earlier)
        AudioArchiveIntegrity.forget(url)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(url), "durable marker still blocks after process restart")
        try FileManager.default.removeItem(at: url)
        AudioRecorder.discardRecoveryArtifacts(for: url)
    }

    func testAliasMarkerLookupKeepsPathLocalWriteAndCleanupSemantics() throws {
        let canonical = directory.appendingPathComponent("take.wav")
        let alias = directory.appendingPathComponent("other.wav")
        let writer = try WavWriter(url: canonical); try writer.append([0.2]); try writer.finish()
        let original = try Data(contentsOf: canonical)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)
        try AudioArchiveIntegrity.markInvalid(canonical)
        try AudioArchiveIntegrity.markInvalid(alias)
        AudioArchiveIntegrity.forget(alias)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioArchiveIntegrity.marker(for: alias).path))
        try AudioArchiveIntegrity.clear(alias)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioArchiveIntegrity.marker(for: alias).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioArchiveIntegrity.marker(for: canonical).path),
                      "clearing an alias-local marker must not delete the target's independent marker")
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(alias), "canonical marker must still block the alias")
        try AudioArchiveIntegrity.clear(canonical)
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(alias))
        // Older path-local alias markers also remain effective without a target marker.
        try AudioArchiveIntegrity.markInvalid(alias); AudioArchiveIntegrity.forget(alias)
        XCTAssertTrue(AudioArchiveIntegrity.isInvalid(alias))
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(canonical))
        try AudioArchiveIntegrity.clear(alias)
        XCTAssertEqual(try Data(contentsOf: canonical), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), canonical.path)
    }

    func testOrdinaryFinishDoesNotAddSynchronization() throws {
        var syncs = 0
        let url = directory.appendingPathComponent("take.wav")
        let writer = try WavWriter(url: url, beforeIO: { if $0 == .synchronize { syncs += 1 } })
        try writer.append([0.2]); try writer.finish()
        XCTAssertEqual(syncs, 0)
        try assertPCM(url, [0.2])
    }

    func testKeptInvalidArchiveDoesNotAcquireMisleadingTranscriptSidecars() throws {
        RecordingStore.ensureDirectory()
        let url = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-02-120000-DDDDDDDD.wav")
        let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        try AudioArchiveIntegrity.markInvalid(url)
        defer { AudioRecorder.discardRecoveryArtifacts(for: url) }
        let meta = RecordingStore.RecordingMeta(appVersion: "test", engine: "fake", model: "fake", inputDevice: nil,
            date: "2026-10-02", durationSeconds: 1, transcriptChars: 5, targetApp: nil)
        RecordingStore.finishRecording(audioURL: url, keep: true, raw: "words", text: "words", meta: meta)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("meta.json").path))
    }

    func testPruningInvalidMarkerAlsoRemovesSurvivingDamagedCanonicalFile() throws {
        RecordingStore.ensureDirectory()
        let old = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-01-120000-AAAAAAAA.wav")
        let recent = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-02-120000-BBBBBBBB.wav")
        for url in [old, recent] {
            let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        }
        try AudioArchiveIntegrity.markInvalid(old)
        RecordingStore.prune(maxCount: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testTrashMovesInvalidMarkerWithEvidenceAndClearsCurrentProcessBlock() throws {
        RecordingStore.ensureDirectory()
        let url = RecordingStore.recordingsDir.appendingPathComponent("recording-2026-10-02-120000-EEEEEEEE.wav")
        let writer = try WavWriter(url: url); try writer.append([0.2]); try writer.finish()
        try AudioArchiveIntegrity.markInvalid(url)
        let destination = directory.appendingPathComponent("isolated-trash")
        let result = RecordingStore.trashAllRecordings(trash: { folder in
            try FileManager.default.moveItem(at: folder, to: destination)
            return destination
        })
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(AudioArchiveIntegrity.isInvalid(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(url.lastPathComponent).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(AudioArchiveIntegrity.marker(for: url).lastPathComponent).path))
    }

}
