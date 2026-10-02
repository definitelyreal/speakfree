// ai-suggestion:unverified · session:feat-agent-skills · 2026-09-24
import XCTest
import AVFoundation
@testable import SpeakFreeLib

/// Contract tests for the agent-facing commands (`transcribe`, `history`, `vocab`).
/// Every test runs against a scratch Config.configDirOverride; nothing here touches the real
/// config, recordings, keystrokes, or clipboard, and no speech model is loaded.
final class AgentCLITests: XCTestCase {

    private var scratch: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        previousOverride = Config.configDirOverride
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch.appendingPathComponent("config")
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = previousOverride
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - helpers

    private func json(_ output: AgentCLI.Output) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(output.json.utf8))
        return try XCTUnwrap(obj as? [String: Any], "stdout must be one JSON object")
    }

    private func errorCode(_ output: AgentCLI.Output) throws -> String? {
        (try json(output)["error"] as? [String: Any])?["code"] as? String
    }

    private var configDir: URL { Config.configDir }
    private var recordings: URL { RecordingStore.recordingsDir }

    private func setSaving(_ on: Bool) throws {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(on)
        try config.save()
    }

    /// Write a real, readable audio file (0.5 s of silence) in the given format.
    private func makeAudio(_ name: String, format: AudioFileTypeID = kAudioFileWAVEType) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == kAudioFileAIFFType,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000))
        buffer.frameLength = 8000
        try file.write(from: buffer)
        return url
    }

    private func env(engine: String = "parakeet", modelProblem: String? = nil,
                     run: @escaping (URL, Config) throws -> ProcessResult = { _, _ in
                         ProcessResult(raw: "hello world", processed: "Hello world.", styled: "Hello world.")
                     }) -> AgentCLI.TranscribeEnvironment {
        AgentCLI.TranscribeEnvironment(
            loadConfig: { Config.loadWithoutCreating().config },
            engineID: { _ in engine },
            modelProblem: { _, _ in modelProblem },
            run: run)
    }

    // MARK: - transcribe: usage and exit codes

    func testTranscribeUsageErrors() throws {
        for args in [[], ["a.wav", "b.wav"], ["--help"]] {
            let out = AgentCLI.transcribe(arguments: args, environment: env())
            XCTAssertEqual(out.exitCode, 2, "\(args)")
            XCTAssertEqual(try errorCode(out), "usage")
            XCTAssertEqual(try json(out)["ok"] as? Bool, false)
            XCTAssertEqual(try json(out)["schema"] as? String, "speakfree.transcribe.v1")
        }
    }

    func testTranscribeMissingFileAndDirectory() throws {
        let missing = AgentCLI.transcribe(arguments: [scratch.appendingPathComponent("nope.wav").path], environment: env())
        XCTAssertEqual(missing.exitCode, 3)
        XCTAssertEqual(try errorCode(missing), "file_not_found")
        let dir = AgentCLI.transcribe(arguments: [scratch.path], environment: env())
        XCTAssertEqual(dir.exitCode, 3)
    }

    func testTranscribeUnreadableAudio() throws {
        let junk = scratch.appendingPathComponent("junk.wav")
        try Data("this is not audio".utf8).write(to: junk)
        let out = AgentCLI.transcribe(arguments: [junk.path], environment: env())
        XCTAssertEqual(out.exitCode, 4)
        XCTAssertEqual(try errorCode(out), "unreadable_audio")
    }

    func testWhisperRejectsNonWav() throws {
        let aiff = try makeAudio("clip.aiff", format: kAudioFileAIFFType)
        let out = AgentCLI.transcribe(arguments: [aiff.path], environment: env(engine: "whisper"))
        XCTAssertEqual(out.exitCode, 4)
        XCTAssertEqual(try errorCode(out), "unsupported_format")
    }

    func testModelNotReadyNeverRuns() throws {
        let wav = try makeAudio("clip.wav")
        var ran = false
        let out = AgentCLI.transcribe(arguments: [wav.path], environment: env(
            modelProblem: "Download it once with: speakfree download-parakeet x",
            run: { _, _ in ran = true; return ProcessResult(raw: "", processed: "", styled: "") }))
        XCTAssertEqual(out.exitCode, 5)
        XCTAssertEqual(try errorCode(out), "model_not_downloaded")
        XCTAssertFalse(ran, "must not attempt transcription (or a download) when the model is missing")
    }

    func testRunFailuresMapToExitCodes() throws {
        let wav = try makeAudio("clip.wav")
        let generic = AgentCLI.transcribe(arguments: [wav.path], environment: env(run: { _, _ in
            throw ProcessCommand.Error.transcriptionFailed(NSError(domain: "t", code: 1))
        }))
        XCTAssertEqual(generic.exitCode, 1)
        XCTAssertEqual(try errorCode(generic), "transcription_failed")

        let missing = AgentCLI.transcribe(arguments: [wav.path], environment: env(run: { _, _ in
            throw ProcessCommand.Error.transcriptionFailed(TranscriptionEngineError.modelAssetsMissing("m"))
        }))
        XCTAssertEqual(missing.exitCode, 5)
        XCTAssertEqual(try errorCode(missing), "model_not_downloaded")
    }

    func testTranscribeSuccessShape() throws {
        let wav = try makeAudio("clip.wav")
        let out = AgentCLI.transcribe(arguments: [wav.path], environment: env())
        XCTAssertEqual(out.exitCode, 0)
        let j = try json(out)
        XCTAssertEqual(Set(j.keys), ["schema", "ok", "text", "raw", "engine", "model",
                                     "duration_seconds", "file", "speakfree_version"])
        XCTAssertEqual(j["ok"] as? Bool, true)
        XCTAssertEqual(j["text"] as? String, "Hello world.")
        XCTAssertEqual(j["raw"] as? String, "hello world")
        XCTAssertEqual(j["engine"] as? String, "parakeet")
        XCTAssertEqual(j["model"] as? String, Config.defaultParakeetModel)
        XCTAssertEqual(j["duration_seconds"] as? Double, 0.5)
        XCTAssertEqual(j["file"] as? String, wav.standardizedFileURL.path)
    }

    func testTranscribeDoesNotCreateConfig() throws {
        let wav = try makeAudio("clip.wav")
        _ = AgentCLI.transcribe(arguments: [wav.path], environment: env())
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.configFile.path),
                       "transcribe must not create config.json")
    }

    func testOfflineGateBlocksDownloadsButRunsCachedLoads() async throws {
        ParakeetModelManager.forbidNetwork()
        defer { ParakeetModelManager.allowNetworkForTesting() }
        XCTAssertThrowsError(try ParakeetModelManager.assertNetworkAllowed())
        let value = try await ParakeetModelManager.shared.withSanctionedDownload { 42 }
        XCTAssertEqual(value, 42, "a cache-only op still runs, with FluidAudio kept offline")
    }

    // MARK: - history

    private func addTake(_ stamp: String, text: String?, app: String? = nil, duration: Double = 2.04,
                         suffix: String = "-abcd1234") throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let base = recordings.appendingPathComponent("recording-\(stamp)\(suffix)")
        try Data().write(to: base.appendingPathExtension("wav"))
        if let text { try Data(text.utf8).write(to: base.appendingPathExtension("txt")) }
        let meta = RecordingStore.RecordingMeta(appVersion: "t", engine: "parakeet", model: "m",
                                                inputDevice: nil, date: "", durationSeconds: duration,
                                                transcriptChars: text?.count ?? 0, targetApp: app)
        try JSONEncoder().encode(meta).write(to: base.appendingPathExtension("meta.json"))
    }

    private let utc = TimeZone(identifier: "UTC")!

    func testHistoryDisabledReadsNothing() throws {
        try addTake("2026-09-24-101500", text: "secret")
        for saving in [nil, false] as [Bool?] {
            if let saving { try setSaving(saving) }
            let out = AgentCLI.history(arguments: [], devModeActive: false, timeZone: utc)
            XCTAssertEqual(out.exitCode, 6)
            XCTAssertEqual(try errorCode(out), "history_disabled")
            XCTAssertEqual(try json(out)["saving_enabled"] as? Bool, false)
            XCTAssertFalse(out.json.contains("secret"))
        }
    }

    func testHistoryDevModeCountsAsSaving() throws {
        try addTake("2026-09-24-101500", text: "dev take")
        let out = AgentCLI.history(arguments: [], devModeActive: true, timeZone: utc)
        XCTAssertEqual(out.exitCode, 0)
    }

    func testHistoryNewestFirstWithLimitAndShape() throws {
        try setSaving(true)
        try addTake("2026-09-24-101500", text: "first", app: "com.apple.mail")
        try addTake("2026-09-24-111500", text: "second", app: "com.tinyspeck.slackmacgap")
        try addTake("2026-09-24-121500", text: "  third\n", app: nil)
        let out = AgentCLI.history(arguments: ["--limit", "2"], devModeActive: false, timeZone: utc)
        XCTAssertEqual(out.exitCode, 0)
        let j = try json(out)
        XCTAssertEqual(Set(j.keys), ["schema", "ok", "saving_enabled", "count", "limit",
                                     "scan_limit_reached", "dictations"])
        XCTAssertEqual(j["schema"] as? String, "speakfree.history.v1")
        XCTAssertEqual(j["count"] as? Int, 2)
        let d = try XCTUnwrap(j["dictations"] as? [[String: Any]])
        XCTAssertEqual(d.map { $0["text"] as? String }, ["third", "second"])
        XCTAssertEqual(d[0]["time"] as? String, "2026-09-24T12:15:00Z")
        XCTAssertNil(d[0]["target_app"])
        XCTAssertEqual(d[1]["target_app"] as? String, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(d[1]["duration_seconds"] as? Double, 2.0)
    }

    func testHistoryTimeComesFromMetaWhenPresent() throws {
        try setSaving(true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        // Filename says 08:00 local wall clock; the sidecar's absolute time wins.
        let base = recordings.appendingPathComponent("recording-2026-09-22-080000-abcd1234")
        try Data().write(to: base.appendingPathExtension("wav"))
        try Data("trip".utf8).write(to: base.appendingPathExtension("txt"))
        let meta = RecordingStore.RecordingMeta(appVersion: "t", engine: "parakeet", model: "m",
                                                inputDevice: nil, date: "2026-09-22T15:00:00Z",
                                                durationSeconds: 1, transcriptChars: 4)
        try JSONEncoder().encode(meta).write(to: base.appendingPathExtension("meta.json"))
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let d = try XCTUnwrap(try json(AgentCLI.history(arguments: [], devModeActive: false, timeZone: tokyo))["dictations"] as? [[String: Any]])
        XCTAssertEqual(d.first?["time"] as? String, "2026-09-23T00:00:00+09:00")
    }

    func testHistoryAppFilterIsCaseInsensitive() throws {
        try setSaving(true)
        try addTake("2026-09-24-101500", text: "to mail", app: "com.apple.mail")
        try addTake("2026-09-24-111500", text: "to slack", app: "com.tinyspeck.slackmacgap")
        let out = AgentCLI.history(arguments: ["--app", "COM.APPLE.MAIL"], devModeActive: false, timeZone: utc)
        let d = try XCTUnwrap(try json(out)["dictations"] as? [[String: Any]])
        XCTAssertEqual(d.map { $0["text"] as? String }, ["to mail"])
        XCTAssertEqual(try json(out)["app"] as? String, "COM.APPLE.MAIL")
    }

    func testHistorySkipsEmptyAndForeignFiles() throws {
        try setSaving(true)
        try addTake("2026-09-24-101500", text: "kept")
        try addTake("2026-09-24-111500", text: "   ")          // blank transcript
        try addTake("2026-09-24-121500", text: nil)            // no transcript
        try Data("x".utf8).write(to: recordings.appendingPathComponent("notes.txt"))
        try Data().write(to: recordings.appendingPathComponent("recording-2026-09-24-131500-abcd1234.bt.wav"))
        try Data("bt".utf8).write(to: recordings.appendingPathComponent("recording-2026-09-24-131500-abcd1234.bt.txt"))
        let d = try XCTUnwrap(try json(AgentCLI.history(arguments: [], devModeActive: false, timeZone: utc))["dictations"] as? [[String: Any]])
        XCTAssertEqual(d.map { $0["text"] as? String }, ["kept"])
    }

    func testHistoryRefusesSymlinksOutOfArchive() throws {
        try setSaving(true)
        let outside = scratch.appendingPathComponent("outside.txt")
        try Data("PRIVATE OUTSIDE FILE".utf8).write(to: outside)
        try addTake("2026-09-24-101500", text: nil)
        let link = recordings.appendingPathComponent("recording-2026-09-24-101500-abcd1234.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let out = AgentCLI.history(arguments: [], devModeActive: false, timeZone: utc)
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertFalse(out.json.contains("PRIVATE OUTSIDE FILE"))
        XCTAssertEqual(try json(out)["count"] as? Int, 0)
    }

    func testReadConfinedRejectsTraversalAndOversize() throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: scratch.appendingPathComponent("config/secret.txt"))
        XCTAssertNil(AgentCLI.readConfined(dir: recordings, name: "../secret.txt", maxBytes: 100))
        XCTAssertNil(AgentCLI.readConfined(dir: recordings, name: "a/b.txt", maxBytes: 100))
        let big = recordings.appendingPathComponent("big.txt")
        try Data(repeating: 65, count: 200).write(to: big)
        XCTAssertNil(AgentCLI.readConfined(dir: recordings, name: "big.txt", maxBytes: 100))
        XCTAssertEqual(AgentCLI.readConfined(dir: recordings, name: "big.txt", maxBytes: 200)?.count, 200)
    }

    func testHistoryNoArchiveYetIsEmptySuccess() throws {
        try setSaving(true)
        let out = AgentCLI.history(arguments: [], devModeActive: false, timeZone: utc)
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual(try json(out)["count"] as? Int, 0)
    }

    func testHistoryUsageErrors() throws {
        for args in [["--limit", "0"], ["--limit", "51"], ["--limit", "x"], ["--limit"], ["--app"],
                     ["--app", "--limit", "5"], ["--bogus"]] {
            let out = AgentCLI.history(arguments: args, devModeActive: true, timeZone: utc)
            XCTAssertEqual(out.exitCode, 2, "\(args)")
            XCTAssertEqual(try errorCode(out), "usage")
        }
    }

    func testHistoryDoesNotCreateConfig() throws {
        _ = AgentCLI.history(arguments: [], devModeActive: false, timeZone: utc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.configFile.path))
    }

    // MARK: - vocab

    private func vocabText() throws -> String {
        try String(contentsOf: Config.vocabularyFile, encoding: .utf8)
    }

    func testVocabListWithoutFileCreatesNothing() throws {
        let out = AgentCLI.vocab(arguments: ["list"])
        XCTAssertEqual(out.exitCode, 0)
        let j = try json(out)
        XCTAssertEqual(j["schema"] as? String, "speakfree.vocabulary.v1")
        XCTAssertEqual(j["count"] as? Int, 0)
        XCTAssertEqual(j["words"] as? [String], [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: configDir.path))
    }

    func testVocabAddCreatesFileLikeSettingsAndIsReadByApp() throws {
        let out = AgentCLI.vocab(arguments: ["add", "Quillon"])
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual(try json(out)["changed"] as? Bool, true)
        XCTAssertTrue(try vocabText().hasPrefix("# Vocabulary for speakfree\n"))
        XCTAssertTrue(try vocabText().hasSuffix("Quillon\n"))
        XCTAssertEqual(Config.loadVocabulary(), "Quillon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.configFile.path))
    }

    func testVocabAddNeverDuplicates() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "# mine\nBrio # manual\nTamsin".write(to: Config.vocabularyFile, atomically: true, encoding: .utf8)
        for word in ["brio", "Brio", "TAMSIN"] {
            let out = AgentCLI.vocab(arguments: ["add", word])
            XCTAssertEqual(out.exitCode, 0)
            XCTAssertEqual(try json(out)["changed"] as? Bool, false, word)
            XCTAssertNotNil(try json(out)["existing"] as? String)
        }
        XCTAssertEqual(try vocabText(), "# mine\nBrio # manual\nTamsin", "unchanged file is not rewritten")
        let added = AgentCLI.vocab(arguments: ["add", "Priya", "Raman"])
        XCTAssertEqual(try json(added)["word"] as? String, "Priya Raman")
        XCTAssertEqual(try vocabText(), "# mine\nBrio # manual\nTamsin\nPriya Raman\n")
        XCTAssertEqual(try json(added)["words"] as? [String], ["Brio", "Tamsin", "Priya Raman"])
    }

    func testVocabRemoveKeepsEverythingElse() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "# header\nBrio # manual\nTamsin\n\nbrio\n".write(to: Config.vocabularyFile, atomically: true, encoding: .utf8)
        let out = AgentCLI.vocab(arguments: ["remove", "BRIO"])
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual(try json(out)["changed"] as? Bool, true)
        XCTAssertEqual(try vocabText(), "# header\nTamsin\n\n")
        let again = AgentCLI.vocab(arguments: ["remove", "Brio"])
        XCTAssertEqual(again.exitCode, 0)
        XCTAssertEqual(try json(again)["changed"] as? Bool, false)
    }

    func testVocabRejectsBadWords() throws {
        for args in [["add"], ["add", "   "], ["add", "#tag"], ["add", "a #b"], ["add", "C#"], ["add", "-x"], ["add", "two\nlines"],
                     ["add", String(repeating: "x", count: 81)], ["remove"], ["list", "x"], [], ["frob"]] {
            let out = AgentCLI.vocab(arguments: args)
            XCTAssertEqual(out.exitCode, 2, "\(args)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.vocabularyFile.path))
    }

    func testVocabDoubleDashEndsOptions() throws {
        let out = AgentCLI.vocab(arguments: ["add", "--", "Priya"])
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual(try json(out)["word"] as? String, "Priya")
        XCTAssertEqual(AgentCLI.vocab(arguments: ["add", "--", "--help"]).exitCode, 2)
    }

    func testVocabKeepsCRLFAndPermissions() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "# header\r\nTamsin\r\n".write(to: Config.vocabularyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.vocabularyFile.path)
        _ = AgentCLI.vocab(arguments: ["add", "Quillon"])
        XCTAssertEqual(try vocabText(), "# header\r\nTamsin\r\nQuillon\r\n")
        let perms = try FileManager.default.attributesOfItem(atPath: Config.vocabularyFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testForgetPathUsesSameLockAndStillRemoves() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "Tamsin\nQuillon\n".write(to: Config.vocabularyFile, atomically: true, encoding: .utf8)
        WordMemory.removeFromVocab("Tamsin")
        XCTAssertEqual(try vocabText(), "Quillon\n")
    }

    func testTranscribeVocabularyReachesTextPipeline() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "Tamsin\n".write(to: Config.vocabularyFile, atomically: true, encoding: .utf8)
        try #"{"tamson": "Tamsin"}"#.write(to: Config.overridesFile, atomically: true, encoding: .utf8)
        let on = ProcessCommand.vocabularyInputs(useUserVocabulary: true)
        XCTAssertEqual(on.glossary, "Tamsin")
        XCTAssertEqual(on.overrides, ["tamson": "Tamsin"])
        let off = ProcessCommand.vocabularyInputs(useUserVocabulary: false)
        XCTAssertNil(off.glossary)
        XCTAssertTrue(off.overrides.isEmpty)
        let fixed = ProcessCommand.postProcess(raw: "tamson will call tomorrow.", punctuationMode: .off,
                                               glossary: on.glossary, overrides: on.overrides,
                                               prompt: nil, duration: 2)
        XCTAssertTrue(fixed.styled.contains("Tamsin"), fixed.styled)
        let plain = ProcessCommand.postProcess(raw: "tamson will call tomorrow.", punctuationMode: .off,
                                               glossary: nil, overrides: [:], prompt: nil, duration: 2)
        XCTAssertFalse(plain.styled.contains("Tamsin"), plain.styled)
    }

    func testVocabularyLockTimeoutDoesNotHang() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let held: Bool? = AgentCLI.withVocabularyLock {
            // Nested attempt from a second descriptor must time out, not block forever.
            let start = Date()
            let inner: Bool? = AgentCLI.withVocabularyLock(timeout: 0.2) { true }
            XCTAssertNil(inner)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            return true
        }
        XCTAssertEqual(held, true)
        XCTAssertEqual(AgentCLI.withVocabularyLock(timeout: 0.2) { 7 }, 7)
    }

    func testVocabWritesThroughSymlink() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let real = scratch.appendingPathComponent("dotfiles-vocab.txt")
        try "Tamsin\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: Config.vocabularyFile, withDestinationURL: real)
        _ = AgentCLI.vocab(arguments: ["add", "Quillon"])
        let attrs = try FileManager.default.attributesOfItem(atPath: Config.vocabularyFile.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "Tamsin\nQuillon\n")
    }
}
