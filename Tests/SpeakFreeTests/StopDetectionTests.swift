import XCTest
@testable import SpeakFreeLib

final class StopDetectionTests: XCTestCase {
    private let windowMs = 30.0

    /// 16 kHz samples of a steady tone at the given RMS.
    private func steady(rms: Float, ms: Double) -> [Float] {
        let count = Int(ms * 16)
        let amplitude = rms * Float(2).squareRoot()
        return (0..<count).map { amplitude * sinf(Float($0) * 0.3) }
    }

    // MARK: - Levels per mode

    func testTheFixedLevelIsTodaysBehaviourByDefault() {
        let levels = PostBufferPolicy.stopLevels(for: .fixed, quietLevel: PostBufferPolicy.defaultSilenceThreshold,
                                                 recordedSoFar: [])
        XCTAssertEqual(levels, PostBufferPolicy.StopLevels(silence: 0.01, speech: 0.02))
    }

    func testARaisedFixedLevelRaisesTheSpeakingLineWithIt() {
        let levels = PostBufferPolicy.stopLevels(for: .fixed, quietLevel: 0.03, recordedSoFar: [])
        XCTAssertEqual(levels, PostBufferPolicy.StopLevels(silence: 0.03, speech: 0.06))
    }

    func testInstantHasNoLevelsBecauseItDoesNotWait() {
        XCTAssertNil(PostBufferPolicy.stopLevels(for: .instant, quietLevel: 0.01, recordedSoFar: []))
    }

    func testMatchingTheRoomChangesNothingInAQuietRoom() {
        let quietRoom = steady(rms: 0.0005, ms: 2_000)
        XCTAssertEqual(PostBufferPolicy.stopLevels(for: .room, quietLevel: 0.01, recordedSoFar: quietRoom),
                       PostBufferPolicy.StopLevels(silence: 0.01, speech: 0.02))
    }

    func testMatchingTheRoomRisesAboveANoisyBackground() throws {
        let noisyRoom = steady(rms: 0.012, ms: 2_000)
        let levels = try XCTUnwrap(PostBufferPolicy.stopLevels(for: .room, quietLevel: 0.01,
                                                               recordedSoFar: noisyRoom))
        XCTAssertEqual(levels.silence, 0.024, accuracy: 0.001)
        XCTAssertEqual(levels.speech, 0.048, accuracy: 0.002)
    }

    func testTheBackgroundIsTheQuietestTenthNotTheSpeech() {
        // 90% loud speech, 10% room tone: the background is the room tone.
        let recording = steady(rms: 0.2, ms: 1_800) + steady(rms: 0.004, ms: 300)
        XCTAssertEqual(PostBufferPolicy.backgroundLevel(of: recording), 0.004, accuracy: 0.001)
        XCTAssertEqual(PostBufferPolicy.backgroundLevel(of: []), 0)
    }

    // MARK: - The wait in a noisy room (15 Oct: every take waited the full 1.2 s)

    func testANoisyRoomWaitsTheFullCapWithFixedLevelsButNotWhenMatched() throws {
        let room = steady(rms: 0.012, ms: 3_000)
        let tailAfterStop = steady(rms: 0.021, ms: 1_200)  // room noise, nobody speaking

        let fixed = PostBufferPolicy.decideWaitMs(trailingSamples: tailAfterStop, windowMs: windowMs)
        XCTAssertEqual(fixed, PostBufferPolicy.defaultExtendedCapMs)

        let levels = try XCTUnwrap(PostBufferPolicy.stopLevels(for: .room, quietLevel: 0.01, recordedSoFar: room))
        let matched = PostBufferPolicy.decideWaitMs(trailingSamples: tailAfterStop, windowMs: windowMs,
                                                    levels: levels)
        XCTAssertEqual(matched, PostBufferPolicy.defaultSilenceNeededMs, accuracy: 0.5)
    }

    func testSpeechAboveTheMatchedLevelsStillHoldsTheRecordingOpen() throws {
        let room = steady(rms: 0.012, ms: 3_000)
        let lastWord = steady(rms: 0.08, ms: 600)
        let levels = try XCTUnwrap(PostBufferPolicy.stopLevels(for: .room, quietLevel: 0.01, recordedSoFar: room))
        XCTAssertEqual(PostBufferPolicy.decideWaitMs(trailingSamples: lastWord, windowMs: windowMs, levels: levels),
                       PostBufferPolicy.defaultExtendedCapMs)
    }

    // MARK: - The setting

    func testAnOlderConfigKeepsTodaysBehaviour() {
        let config = Config.defaultConfig
        XCTAssertEqual(config.effectiveStopDetection, .fixed)
        XCTAssertEqual(config.effectiveStopQuietLevel, PostBufferPolicy.defaultSilenceThreshold)
    }

    func testAnUnknownModeFallsBackAndTheLevelIsKeptInRange() {
        var config = Config.defaultConfig
        config.stopDetection = "nonsense"
        XCTAssertEqual(config.effectiveStopDetection, .fixed)
        config.stopQuietLevel = 5
        XCTAssertEqual(config.effectiveStopQuietLevel, PostBufferPolicy.quietLevelRange.upperBound)
        config.stopQuietLevel = 0
        XCTAssertEqual(config.effectiveStopQuietLevel, PostBufferPolicy.quietLevelRange.lowerBound)
    }

    func testTheSettingSurvivesARoundTripAndIsAbsentWhenUnset() throws {
        var config = Config.defaultConfig
        var json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        XCTAssertFalse(json.contains("stopDetection"))
        XCTAssertFalse(json.contains("stopQuietLevel"))
        config.stopDetection = StopDetection.room.rawValue
        config.stopQuietLevel = 0.02
        json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.effectiveStopDetection, .room)
        XCTAssertEqual(decoded.effectiveStopQuietLevel, 0.02, accuracy: 0.0001)
    }

    func testSettingsLeaveTheKeysOutUntilTheUserChangesThem() {
        let viewModel = SettingsViewModel(config: Config.defaultConfig)
        XCTAssertEqual(viewModel.stopDetection, .fixed)
        XCTAssertNil(viewModel.toConfig().stopDetection)
        XCTAssertNil(viewModel.toConfig().stopQuietLevel)

        viewModel.stopDetection = .instant
        XCTAssertEqual(viewModel.toConfig().effectiveStopDetection, .instant)
        viewModel.stopQuietLevel = 0.03
        XCTAssertEqual(viewModel.toConfig().effectiveStopQuietLevel, 0.03, accuracy: 0.0001)
    }
}
