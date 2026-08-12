// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import XCTest
@testable import SpeakFreeLib

final class SpeechAuditDefectTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/tmp/speech-audit-defect.wav")

    func testZeroPayloadIsCaptureFailureInsteadOfAccidentalTap() {
        let result = FinalizePipeline.resolveGateSamples(
            memorySamples: [], readWav: { [] })

        XCTAssertEqual(result.failure, .captureFailed)
        XCTAssertFalse(result.usedWavFallback)
    }

    func testWavPayloadStillRescuesEmptyMemoryCapture() {
        let wavSamples = [Float](repeating: 0.1, count: FinalizePipeline.minSamples)
        let result = FinalizePipeline.resolveGateSamples(
            memorySamples: [], readWav: { wavSamples })

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.samples, wavSamples)
        XCTAssertTrue(result.usedWavFallback)
    }

    func testFirstBufferGuardOnlyRecoversCurrentActiveTake() {
        XCTAssertTrue(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: true, scheduledGeneration: 4, currentGeneration: 4,
            firstBufferArrived: false))
        XCTAssertFalse(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: true, scheduledGeneration: 4, currentGeneration: 4,
            firstBufferArrived: true))
        XCTAssertFalse(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: false, scheduledGeneration: 4, currentGeneration: 4,
            firstBufferArrived: false))
        XCTAssertFalse(AudioRecorder.shouldRecoverMissingFirstBuffer(
            isRecording: true, scheduledGeneration: 4, currentGeneration: 5,
            firstBufferArrived: false))
    }

    func testRealShortYeahSurvivesHallucinationFilter() async throws {
        let engine = FakeEngine(cannedTranscript: "Yeah.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = speechSamples(seconds: 0.8)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "Yeah.")
    }

    func testRealShortSoSurvivesHallucinationFilter() async throws {
        let engine = FakeEngine(cannedTranscript: "So")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = speechSamples(seconds: 0.7)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "So")
    }

    func testEmptyRoomFillerRemainsFiltered() async throws {
        let engine = FakeEngine(cannedTranscript: "Yeah.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        let samples = [Float](repeating: 0.001, count: 16_000 * 6)

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "")
    }

    func testLongTakeWithSomeSpeechSparesBareFiller() async throws {
        let engine = FakeEngine(cannedTranscript: "Okay.")
        let transcriber = Transcriber(engine: engine, modelID: "fake", language: "en")
        var samples = [Float](repeating: 0.001, count: 16_000 * 3)
        samples.replaceSubrange(20_000..<20_480, with: [Float](repeating: 0.08, count: 480))

        let result = try await transcriber.transcribe(
            audioURL: audioURL, samples: samples)

        XCTAssertEqual(result, "Okay.")
    }

    func testElectronRejectsLiveAXButKeepsRememberedTailEligible() {
        XCTAssertNil(AppDelegate.liveCursorContext(
            "untrusted Electron AX text", isElectronClass: true))
        XCTAssertEqual(AppDelegate.liveCursorContext(
            "native editor text", isElectronClass: false), "native editor text")

        let remembered = FinalizePipeline.fallbackCursorContext(
            lastInsertedTail: "Remembered tail ",
            lastInsertedBundleID: "com.microsoft.VSCode",
            lastInsertedAt: Date(),
            frontmostBundleID: "com.microsoft.VSCode",
            now: Date())
        XCTAssertEqual(remembered, "Remembered tail ")
    }

    func testLegacyNilPunctuationDisplaysAutomaticOnlyEverywhere() throws {
        var config = Config.defaultConfig
        config.spokenPunctuation = nil

        XCTAssertEqual(SettingsViewModel(config: config).punctuationMode, .off)
        let facts = HelpFacts.live(config: config)
        XCTAssertEqual(facts.punctuationMode, .off)
        XCTAssertEqual(facts.punctuationDisplayName, "Automatic Only")
    }

    private func speechSamples(seconds: Double) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { index in
            sin(Float(index) * 0.08) * 0.08
        }
    }
}
