// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-23
//
// "Load Whisper as fallback for errors" and the one-time backup download offer.

import XCTest
@testable import SpeakFreeLib

final class WhisperFallbackTests: XCTestCase {
    private func config(_ fallback: Bool?, declinedDaysAgo: Double? = nil, now: Date) -> Config {
        var c = Config.defaultConfig
        c.whisperFallback = fallback.map { FlexBool($0) }
        c.whisperFallbackOfferDeclinedAt = declinedDaysAgo.map { now.timeIntervalSince1970 - $0 * 86_400 }
        return c
    }

    func testUnsetMeansOnSoExistingInstallsKeepTheirRescue() {
        let now = Date()
        XCTAssertTrue(WhisperFallback.isEnabled(config(nil, now: now)))
        XCTAssertTrue(WhisperFallback.isEnabled(config(true, now: now)))
        XCTAssertFalse(WhisperFallback.isEnabled(config(false, now: now)))
    }

    func testOfferOnlyForParakeetWithoutTheModelAndNotWhileDownloading() {
        let now = Date(), c = config(nil, now: now)
        XCTAssertTrue(WhisperFallback.shouldOfferDownload(config: c, engine: "parakeet", modelPresent: false, downloading: false, now: now))
        XCTAssertFalse(WhisperFallback.shouldOfferDownload(config: c, engine: "whisper", modelPresent: false, downloading: false, now: now))
        XCTAssertFalse(WhisperFallback.shouldOfferDownload(config: c, engine: "parakeet", modelPresent: true, downloading: false, now: now))
        XCTAssertFalse(WhisperFallback.shouldOfferDownload(config: c, engine: "parakeet", modelPresent: false, downloading: true, now: now))
    }

    func testTurnedOffOrRecentlyDeclinedSuppressesTheOffer() {
        let now = Date()
        XCTAssertFalse(WhisperFallback.shouldOfferDownload(config: config(false, now: now), engine: "parakeet", modelPresent: false, downloading: false, now: now))
        XCTAssertFalse(WhisperFallback.shouldOfferDownload(config: config(nil, declinedDaysAgo: 3, now: now), engine: "parakeet", modelPresent: false, downloading: false, now: now))
        XCTAssertTrue(WhisperFallback.shouldOfferDownload(config: config(nil, declinedDaysAgo: 15, now: now), engine: "parakeet", modelPresent: false, downloading: false, now: now))
    }

    func testCopySaysItWillBeReadyNextTimeWithoutDashes() {
        XCTAssertTrue(WhisperFallback.offerMessage.contains("ready for future times"))
        XCTAssertFalse(WhisperFallback.offerMessage.contains("\u{2014}"))
        XCTAssertFalse(Transcriber.SecondOpinionStatus.missed.message.contains("\u{2014}"))
        XCTAssertEqual(Transcriber.SecondOpinionStatus.missed.message, "Didn't catch that. Try again.")
    }

    func testFallbackRoundTripsThroughConfigJSON() throws {
        var c = Config.defaultConfig
        c.whisperFallback = FlexBool(false)
        c.whisperFallbackOfferDeclinedAt = 1_700_000_000
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded.whisperFallback?.value, false)
        XCTAssertEqual(decoded.whisperFallbackOfferDeclinedAt, 1_700_000_000)
    }

    /// Parakeet returns nothing on voiced speech, fallback off: the take reports `.missed` and no
    /// Whisper runs. The empty-result retries still happen first ("retry parakeet just in case").
    func testEmptyVoicedTakeWithFallbackOffReportsMissedAfterRetries() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previous = Config.configDirOverride
        Config.configDirOverride = scratch
        defer { Config.configDirOverride = previous; try? FileManager.default.removeItem(at: scratch) }

        let engine = FakeEngine(engineID: "parakeet", cannedTranscript: "", supportsStreaming: false)
        let transcriber = Transcriber(engine: engine, modelID: "parakeet-tdt-0.6b-v2", language: "en")
        transcriber.whisperFallbackEnabled = false
        var statuses: [Transcriber.SecondOpinionStatus] = []
        transcriber.onSecondOpinionStatus = { statuses.append($0) }
        // 2 s of a 150 Hz voiced tone at 0.1 RMS-ish: sustained, voiced speech energy.
        let samples = (0..<32_000).map { Float(0.14 * sin(2 * Double.pi * 150 * Double($0) / 16_000)) }
        let url = scratch.appendingPathComponent("take.wav")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let text = try await transcriber.transcribe(audioURL: url, samples: samples)
        XCTAssertEqual(text, "")
        XCTAssertEqual(statuses, [.missed])
        XCTAssertEqual(engine.transcribeCalls.count, 1 + Transcriber.maxEmptyRetriesOnVoicedSpeech)
    }
}
