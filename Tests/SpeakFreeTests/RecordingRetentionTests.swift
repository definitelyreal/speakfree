// ai-suggestion:unverified · session:unknown · 2026-09-15
import XCTest
@testable import SpeakFreeLib

final class RecordingRetentionTests: XCTestCase {
    func testAvailableChoicesIncludeUnlimitedNoneAndBothLargeLimits() {
        XCTAssertEqual(RecordingRetention.options, [0, -1, 1_000, 10_000])
        XCTAssertEqual(RecordingRetention.title(0), "Keep All")
        XCTAssertEqual(RecordingRetention.title(-1), "Keep None")
    }

    func testNoneDisablesSavingAndClearsEveryPreviousPruningOverride() {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(true)
        config.maxRecordings = 10_000
        config.maxRecordingsUserConfirmed = nil
        config.preserveAllRecordings = FlexBool(true)

        RecordingRetention.apply(-1, to: &config)

        XCTAssertEqual(config.saveRecordings?.value, false)
        XCTAssertEqual(Config.effectiveMaxRecordings(config.maxRecordings), 0,
                       "Launch pruning must not retain a hidden old cap after selecting None")
        XCTAssertNil(config.preserveAllRecordings)
        XCTAssertEqual(config.maxRecordingsUserConfirmed, true)
        XCTAssertEqual(RecordingRetention.selection(in: config), -1)
    }

    func testKeepAllEnablesSavingAndRemovesAnExistingCap() {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(false)
        config.maxRecordings = 1_000
        config.preserveAllRecordings = FlexBool(false)

        RecordingRetention.apply(0, to: &config)

        XCTAssertEqual(config.saveRecordings?.value, true)
        XCTAssertEqual(Config.effectiveMaxRecordings(config.maxRecordings), 0)
        XCTAssertNil(config.preserveAllRecordings)
        XCTAssertEqual(RecordingRetention.selection(in: config), 0)
    }

    func testBothLargeLimitsSurviveConfigEncodingAndRemoveTheUnlimitedOverride() throws {
        for limit in [1_000, 10_000] {
            var config = Config.defaultConfig
            config.saveRecordings = FlexBool(false)
            config.preserveAllRecordings = FlexBool(true)

            RecordingRetention.apply(limit, to: &config)
            let reloaded = try Config.decode(from: JSONEncoder().encode(config))

            XCTAssertEqual(reloaded.saveRecordings?.value, true)
            XCTAssertNil(reloaded.preserveAllRecordings)
            XCTAssertEqual(reloaded.maxRecordingsUserConfirmed, true)
            XCTAssertEqual(reloaded.maxRecordings, limit)
            XCTAssertEqual(Config.effectiveMaxRecordings(reloaded.maxRecordings), limit,
                           "The engine must use the same limit that the picker displays")
            XCTAssertEqual(RecordingRetention.selection(in: reloaded), limit)
        }
    }

    func testReadingSelectionDoesNotOptInOrRewriteExistingPreferences() throws {
        var config = Config.defaultConfig
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let fresh = try encoder.encode(config)
        XCTAssertEqual(RecordingRetention.selection(in: config), -1)
        XCTAssertEqual(try encoder.encode(config), fresh,
                       "Displaying the initial choice must not opt a fresh config into saving")

        config.saveRecordings = FlexBool(true)
        config.maxRecordings = 42
        config.maxRecordingsUserConfirmed = nil
        config.preserveAllRecordings = FlexBool(true)
        let existing = try encoder.encode(config)
        XCTAssertEqual(RecordingRetention.selection(in: config), 0)
        XCTAssertEqual(try encoder.encode(config), existing,
                       "Reading an unlimited legacy override must not normalize or confirm it")

        config.saveRecordings = FlexBool(false)
        let disabled = try encoder.encode(config)
        XCTAssertEqual(RecordingRetention.selection(in: config), -1)
        XCTAssertEqual(try encoder.encode(config), disabled,
                       "An explicit opt-out must remain intact despite a legacy unlimited override")
    }

    func testReadingLegacyCustomCapPreservesTheUsersExactLimit() {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(true)
        config.maxRecordings = 321
        XCTAssertEqual(RecordingRetention.selection(in: config), 321)
    }

    func testApplyingRetentionPreservesUnrelatedSettingsAndNoticeResolution() {
        for choice in RecordingRetention.options {
            var config = Config.defaultConfig
            config.language = "fr"
            config.modelPath = "/custom/model.bin"
            config.recordingsNoticeDecision = "keep"
            config.recordingsSetupCompleted = true

            RecordingRetention.apply(choice, to: &config)

            XCTAssertEqual(config.language, "fr")
            XCTAssertEqual(config.modelPath, "/custom/model.bin")
            XCTAssertEqual(config.recordingsNoticeDecision, "keep",
                           "Changing future retention alone must not resolve or delete an existing corpus")
            XCTAssertEqual(config.recordingsSetupCompleted, true)
        }
    }
}
