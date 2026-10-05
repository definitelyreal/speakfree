// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-10-04
//
// On 2026-10-04, in a loud airplane cabin, the Whisper rescue typed "*Dramatic music*",
// "- Thank you." and subtitle dialogue that nobody said. These tests pin the guard with
// invented strings and synthetic audio only: no recordings folder, no real config, no
// keystrokes, no clipboard.
import XCTest
@testable import SpeakFreeLib

enum CabinAudio {
    /// Loud low rumble that never dips: the shape of the MacBook microphone in the cabin
    /// (level about 0.15, almost all energy under 1 kHz, a flat speech band).
    static func rumble(seconds: Double, rms: Float = 0.15, seed: UInt64 = 3) -> [Float] {
        let white = SyntheticAudio.staticNoise(seconds: seconds, rms: 1, seed: seed)
        var low: Float = 0
        var shaped = white.map { x -> Float in low = low * 0.95 + x * 0.05; return low + x * 0.02 }
        let level = (shaped.reduce(Float(0)) { $0 + $1 * $1 } / Float(shaped.count)).squareRoot()
        shaped = shaped.map { $0 * rms / level }
        return shaped
    }

    /// A voice that rises and falls, over the same rumble: real speech in a loud room.
    static func voiceOverRumble(seconds: Double) -> [Float] {
        zip(rumble(seconds: seconds), SyntheticAudio.voice(seconds: seconds, peak: 0.6)).map { $0 + $1 }
    }
}

final class WhisperHallucinationGuardTextTests: XCTestCase {
    func testStockPhrasesAndSoundTags() {
        for text in ["Thank you.", "- Thank you.", "Thank you. Thank you.", "thank you!", "You", "Bye.",
                     "Thanks for watching!", "Thank you for watching.", "*Dramatic music*", "[Music]",
                     "(applause)", "[Music] [Applause]", "♪♪", "♪ la la ♪", "*click* *click*",
                     "Subtitles by the Amara.org community", "- Thank you very much."] {
            XCTAssertTrue(WhisperHallucinationGuard.isStockPhrase(text), text)
        }
    }

    func testOrdinaryDictationIsNotAStockPhrase() {
        for text in ["Thank you for the notes.", "I'm gonna use your space.", "Do you have somebody to do this?",
                     "-5 degrees outside", "(see below) the plan", "Yes.", "Okay, ship it.",
                     "Thanks, see you at the meeting.", "The music was too loud.", "Please subscribe Alex to the list."] {
            XCTAssertFalse(WhisperHallucinationGuard.isStockPhrase(text), text)
        }
    }

    func testDialogueDash() {
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("- I'm gonna use your space."), "I'm gonna use your space.")
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("– Okay."), "Okay.")
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("- Do you have it? - Yes."), "Do you have it? - Yes.")
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("-5 degrees"), "-5 degrees")
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("Plan A - or B"), "Plan A - or B")
        XCTAssertTrue(WhisperHallucinationGuard.hasDialogueDash("- Yes."))
        XCTAssertFalse(WhisperHallucinationGuard.hasDialogueDash("-5 degrees"))
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("- 5 degrees"), "- 5 degrees", "a minus sign")
        XCTAssertEqual(WhisperHallucinationGuard.stripDialogueDash("- buy milk\n- eggs"), "- buy milk\n- eggs", "a list")
        XCTAssertFalse(WhisperHallucinationGuard.hasDialogueDash("- buy milk\n- eggs"))
    }

    func testCommaJoinedStockAndMusicNotes() {
        XCTAssertTrue(WhisperHallucinationGuard.isStockPhrase("Thank you, bye."))
        XCTAssertTrue(WhisperHallucinationGuard.isStockPhrase("Thank you, thank you."))
        XCTAssertFalse(WhisperHallucinationGuard.isStockPhrase("Thank you, Sam."))
        XCTAssertFalse(WhisperHallucinationGuard.isStockPhrase("♪ This is my real sentence"))
        XCTAssertTrue(WhisperHallucinationGuard.isStockPhrase("♪ Happy birthday ♪"))
    }
}

final class WhisperHallucinationGuardAudioTests: XCTestCase {
    func testLoudFlatRumbleIsNoiseOnly() {
        let verdict = WhisperHallucinationGuard.noiseVerdict(CabinAudio.rumble(seconds: 4))
        XCTAssertFalse(verdict.isStatic, "rumble is low-pitched, not headset hiss: \(verdict.summary)")
        XCTAssertTrue(verdict.isNoiseOnly, verdict.summary)
    }

    func testHeadsetStaticIsNoiseOnly() {
        XCTAssertTrue(WhisperHallucinationGuard.noiseVerdict(SyntheticAudio.staticNoise(seconds: 4, rms: 0.06)).isNoiseOnly)
    }

    func testSpeechInALoudRoomIsNotNoise() {
        let verdict = WhisperHallucinationGuard.noiseVerdict(CabinAudio.voiceOverRumble(seconds: 4))
        XCTAssertGreaterThanOrEqual(verdict.floorRMS, WhisperHallucinationGuard.loudFloorRMS, verdict.summary)
        XCTAssertFalse(verdict.isNoiseOnly, verdict.summary)
        XCTAssertFalse(verdict.leansNoise, verdict.summary)
    }

    func testQuietVoiceAndQuietRoomAreNotNoise() {
        XCTAssertFalse(WhisperHallucinationGuard.noiseVerdict(SyntheticAudio.voice(seconds: 3)).leansNoise)
        XCTAssertFalse(WhisperHallucinationGuard.noiseVerdict(SyntheticAudio.fan(seconds: 3)).leansNoise,
                       "a quiet fan is flat but not loud")
        XCTAssertFalse(WhisperHallucinationGuard.noiseVerdict(CabinAudio.rumble(seconds: 1)).isNoiseOnly,
                       "too short to judge")
    }

    func testDecisions() {
        let rumble = WhisperHallucinationGuard.noiseVerdict(CabinAudio.rumble(seconds: 4))
        let voice = WhisperHallucinationGuard.noiseVerdict(SyntheticAudio.voice(seconds: 3))
        let loudRoom = WhisperHallucinationGuard.noiseVerdict(CabinAudio.voiceOverRumble(seconds: 4))
        func block(_ w: String, _ n: WhisperHallucinationGuard.NoiseVerdict, _ p: String?) -> Bool {
            WhisperHallucinationGuard.assess(whisperText: w, noise: n, parakeetText: p).block
        }
        // The evening's outputs: Parakeet heard nothing.
        XCTAssertTrue(block("*Dramatic music*", voice, ""))
        XCTAssertTrue(block("Thank you.", voice, ""), "a stock phrase Parakeet did not hear")
        XCTAssertTrue(block("- Thank you.", rumble, ""))
        XCTAssertTrue(block("- I'm gonna use your space.", rumble, ""))
        XCTAssertTrue(block("- Do you have somebody to do this? - Yes.", rumble, ""))
        XCTAssertTrue(block("I'm gonna use your space.", rumble, "Okay"), "one Parakeet word is near-empty")
        // Real speech still gets through.
        XCTAssertFalse(block("Let's ship the build tonight.", loudRoom, ""), "a rescue in a loud room with a voice")
        XCTAssertFalse(block("- Let's ship it.", voice, ""), "a dash alone is not enough")
        XCTAssertFalse(block("Thank you.", rumble, "Thank you."), "Parakeet heard the same words")
        XCTAssertFalse(block("Thank you so much for the notes, Sam.", rumble, "Thank you so much for the notes"))
        // Whisper as the chosen engine: no Parakeet opinion.
        XCTAssertFalse(block("Thank you.", voice, nil), "real short dictation with clear speech")
        XCTAssertTrue(block("Thank you.", rumble, nil))
        XCTAssertFalse(block("I'm gonna use your space.", rumble, nil), "no stock phrase, no second opinion")
        XCTAssertTrue(block("- I'm gonna use your space.", rumble, nil), "a subtitle dash on noise")
        XCTAssertFalse(block("- Send it to Sam.", voice, nil))
        let hiss = WhisperHallucinationGuard.noiseVerdict(SyntheticAudio.staticNoise(seconds: 4, rms: 0.06))
        XCTAssertTrue(block("Okay so the plan is good.", hiss, nil), "anything read out of headset static")
        // Nothing to judge.
        XCTAssertFalse(block("", rumble, ""))
    }
}

final class WhisperHallucinationGuardTranscriberTests: XCTestCase {
    private final class FixedEngine: TranscriptionEngine {
        let engineID: String
        let words: String
        init(_ engineID: String, words: String) { self.engineID = engineID; self.words = words }
        var keepModelLoaded = "auto"
        var supportsStreaming: Bool { false }
        var supportsPrompt: Bool { false }
        var isLoaded = true
        var lastDiagnostics: TranscriptionDiagnostics? { nil }
        func loadModel(modelID: String) async throws {}
        func unloadModel() async {}
        func startMemoryPressureMonitoring() {}
        func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String { words }
        func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                                 onPartialResult: @escaping (String) -> Void) async throws -> String {
            throw TranscriptionEngineError.streamingUnsupported
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("hallucination-guard-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Config.configDirOverride = root
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ samples: [Float], engine: FixedEngine, whisper: String?,
                     name: String = "recording-2026-10-04-211023-test")
        async throws -> (text: String, statuses: [Transcriber.SecondOpinionStatus], sidecar: String?) {
        let url = root.appendingPathComponent("\(name).wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        let transcriber = Transcriber(engine: engine, modelID: "synthetic", language: "en")
        transcriber.whisperBackupAvailableOverride = whisper != nil
        transcriber.cliTranscriptionOverride = { _ in whisper ?? "" }
        var statuses: [Transcriber.SecondOpinionStatus] = []
        transcriber.onSecondOpinionStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        let sidecar = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("whisper.txt"), encoding: .utf8)
        return (text, statuses, sidecar)
    }

    func testRescueOnCabinNoiseTypesNothingAndSaysDidntCatchThat() async throws {
        let result = try await run(CabinAudio.rumble(seconds: 4), engine: FixedEngine("parakeet-test", words: ""),
                                   whisper: "- I'm gonna use your space.")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.statuses.last, .likelyHallucination, "\(result.statuses)")
        XCTAssertFalse(result.statuses.contains { if case .failed = $0 { return true }; return false })
        XCTAssertEqual(result.sidecar, "- I'm gonna use your space.", "kept for review, never typed")
        XCTAssertEqual(Transcriber.SecondOpinionStatus.likelyHallucination.message, "Didn't catch that. Try again.")
    }

    func testRescueStockPhraseIsRefusedEvenWithAVoice() async throws {
        let result = try await run(SyntheticAudio.voice(seconds: 3, peak: 0.3), engine: FixedEngine("parakeet-test", words: ""),
                                   whisper: "*Dramatic music*")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.statuses.last, .likelyHallucination)
    }

    func testRealRescueInALoudRoomStillTypesWithoutTheDash() async throws {
        let result = try await run(CabinAudio.voiceOverRumble(seconds: 4), engine: FixedEngine("parakeet-test", words: ""),
                                   whisper: "- Let's ship the build tonight.")
        XCTAssertEqual(result.text, "Let's ship the build tonight.")
        XCTAssertFalse(result.statuses.contains(.likelyHallucination))
    }

    func testParakeetThankYouOnClearSpeechStillTypes() async throws {
        let result = try await run(SyntheticAudio.voice(seconds: 3, peak: 0.3),
                                   engine: FixedEngine("parakeet-test", words: "Thank you."), whisper: nil)
        XCTAssertEqual(result.text, "Thank you.")
    }

    func testWhisperEngineThankYou() async throws {
        let clear = try await run(SyntheticAudio.voice(seconds: 3, peak: 0.3),
                                  engine: FixedEngine("whisper", words: "Thank you."), whisper: nil, name: "recording-clear")
        XCTAssertEqual(clear.text, "Thank you.", "real short dictation with clear speech")
        let cabin = try await run(CabinAudio.rumble(seconds: 4),
                                  engine: FixedEngine("whisper", words: "- Thank you."), whisper: nil, name: "recording-cabin")
        XCTAssertEqual(cabin.text, "")
        XCTAssertEqual(cabin.statuses, [.likelyHallucination])
        let dashed = try await run(SyntheticAudio.voice(seconds: 3, peak: 0.3),
                                   engine: FixedEngine("whisper", words: "- Send it to Sam."), whisper: nil, name: "recording-dash")
        XCTAssertEqual(dashed.text, "Send it to Sam.")
    }

    private func sparseTake(_ samples: [Float], parakeet: String, whisper: String, device: String)
        async throws -> (text: String, statuses: [Transcriber.SecondOpinionStatus], sidecar: URL) {
        let url = root.appendingPathComponent("recording-2026-10-04-sparse-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url)
        try writer.append(samples); writer.close()
        let transcriber = Transcriber(engine: FixedEngine("parakeet-test", words: parakeet), modelID: "synthetic", language: "en")
        transcriber.whisperBackupAvailableOverride = true
        transcriber.cliTranscriptionOverride = { _ in whisper }
        var statuses: [Transcriber.SecondOpinionStatus] = []
        transcriber.onSecondOpinionStatus = { statuses.append($0) }
        let text = try await transcriber.transcribe(audioURL: url, samples: samples, inputDevice: device)
        return (text, statuses, url.deletingPathExtension().appendingPathExtension("whisper.txt"))
    }

    /// Clear audio, Parakeet one word, Whisper an invented outro: the synchronous sparse swap
    /// is refused and the gate learns "no gain".
    func testInventedSparseSwapIsRefusedAndDoesNotTrainTheGate() async throws {
        let device = "test-sparse-\(UUID().uuidString)"
        let invented = "Thank you for watching. Thank you."
        let result = try await sparseTake(SyntheticAudio.voice(seconds: 8, peak: 0.3), parakeet: "Okay",
                                          whisper: invented, device: device)
        XCTAssertTrue(result.statuses.contains { if case .rechecking = $0 { return true }; return false },
                      "the synchronous sparse rescue ran: \(result.statuses)")
        XCTAssertNotEqual(result.text, invented)
        XCTAssertFalse(result.text.contains("watching"))
        XCTAssertFalse(result.statuses.contains(.likelyHallucination), "Parakeet had a word, so no miss is reported")
        XCTAssertEqual(SparseRescueGate.shared.ratio(for: device), SparseRescueGate.initialRatio * SparseRescueGate.step,
                       "a refused invention counts as no gain")
        XCTAssertEqual(try? String(contentsOf: result.sidecar, encoding: .utf8), invented)
    }

    /// Flat cabin noise: the gate skips the synchronous rescue and checks in the background.
    /// An invented background answer must not count as missed words.
    func testInventedBackgroundSkipCheckDoesNotLowerTheGate() async throws {
        let device = "test-skip-\(UUID().uuidString)"
        let result = try await sparseTake(CabinAudio.rumble(seconds: 8), parakeet: "Okay",
                                          whisper: "- I'm gonna use your space, do you have somebody to do this?",
                                          device: device)
        XCTAssertFalse(result.statuses.contains { if case .rechecking = $0 { return true }; return false })
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: result.sidecar.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.sidecar.path), "the background check ran")
        try await Task.sleep(nanoseconds: 100_000_000) // the gate is updated right after the sidecar
        XCTAssertEqual(SparseRescueGate.shared.ratio(for: device), SparseRescueGate.initialRatio,
                       "an invented check is not missed words, so the ratio is not lowered")
    }

    func testBlockedLogLineIsClassifiedForUpdates() {
        let verdict = WhisperHallucinationGuard.assess(
            whisperText: "- Thank you.", noise: WhisperHallucinationGuard.noiseVerdict(CabinAudio.rumble(seconds: 4)),
            parakeetText: "")
        let line = "[20:10:23] Transcriber: whisper rescue text not typed, likely invented (\(verdict.reason ?? "?"); "
            + "\(verdict.noise.summary); 12 chars kept in sidecar only)"
        XCTAssertNotEqual(UpdateLogEvent.classify(line), .unsupported, line)
    }
}
