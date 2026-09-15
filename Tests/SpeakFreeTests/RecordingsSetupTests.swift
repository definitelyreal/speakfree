// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-14
import XCTest
import AppKit
import SwiftUI
@testable import SpeakFreeLib

final class RecordingsSetupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-setup-\(UUID().uuidString)")
        Config.configDirOverride = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testFreshSetupAsksEvenWithAConfiguredModel() {
        for engine in ["parakeet", "whisper"] {
            var config = Config.defaultConfig
            config.engine = engine
            config.parakeetModel = "already-downloaded-model"
            config.modelSize = "already-downloaded-model"
            XCTAssertTrue(RecordingsSetup.shouldPresent(config: config, hasRecordings: false, developerMode: false))
            config.recordingsNoticeDecision = "none-found"
            XCTAssertTrue(RecordingsSetup.shouldPresent(config: config, hasRecordings: false, developerMode: false))
        }
    }

    func testEstablishedPreferencesAndDeveloperModeArePreserved() {
        for saving in [false, true] {
            var config = Config.defaultConfig
            config.saveRecordings = FlexBool(saving)
            XCTAssertFalse(RecordingsSetup.shouldPresent(config: config, hasRecordings: false, developerMode: false))
        }
        XCTAssertFalse(RecordingsSetup.shouldPresent(config: .defaultConfig, hasRecordings: false, developerMode: true))
        for decision in ["keep", "delete"] {
            var config = Config.defaultConfig
            config.recordingsNoticeDecision = decision
            XCTAssertFalse(RecordingsSetup.shouldPresent(config: config, hasRecordings: true, developerMode: false))
        }
    }

    func testUnnotifiedLegacyCorpusStillGetsTheFullNotice() {
        let config = Config.defaultConfig
        XCTAssertFalse(RecordingsSetup.shouldPresent(config: config, hasRecordings: true, developerMode: false))
        XCTAssertEqual(RecordingsNotice.launchAction(decision: nil, hasRecordings: true), .show)
    }

    func testImportedRecordingsAfterEmptyNoticeAllowTheExistingFilesChoice() {
        var config = Config.defaultConfig
        config.recordingsNoticeDecision = "none-found"
        XCTAssertTrue(RecordingsSetup.shouldPresent(config: config, hasRecordings: true, developerMode: false))
    }

    func testDecliningPreservesExistingFilesAndFreshConfigurationChanges() throws {
        try FileManager.default.createDirectory(at: RecordingStore.recordingsDir, withIntermediateDirectories: true)
        let file = RecordingStore.recordingsDir.appendingPathComponent("recording-existing.wav")
        let contents = Data([1, 2, 3, 4])
        try contents.write(to: file)
        var config = Config.defaultConfig
        config.language = "fr"
        config.parakeetModel = "latest-selection"
        try config.save()
        try RecordingsSetup.persist(save: false, existingDecision: "keep")
        let reloaded = Config.load()
        XCTAssertEqual(reloaded.saveRecordings?.value, false)
        XCTAssertEqual(reloaded.recordingsSetupCompleted, true)
        XCTAssertEqual(reloaded.recordingsNoticeDecision, "keep")
        XCTAssertEqual(reloaded.language, "fr")
        XCTAssertEqual(reloaded.parakeetModel, "latest-selection")
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertFalse(RecordingsSetup.shouldPresent(config: reloaded, hasRecordings: true, developerMode: false))
    }

    func testAcceptingPersistsAcrossThePostDownloadSetupPass() throws {
        try RecordingsSetup.persist(save: true, existingDecision: "none-found")
        let reloaded = Config.load()
        XCTAssertEqual(reloaded.saveRecordings?.value, true)
        XCTAssertEqual(reloaded.recordingsSetupCompleted, true)
        XCTAssertFalse(RecordingsSetup.shouldPresent(config: reloaded, hasRecordings: false, developerMode: false))
    }

    func testFailedSaveThrowsWithoutAdvancingPersistedConsent() throws {
        // Make the config destination a directory so the atomic file write fails.
        try FileManager.default.createDirectory(at: Config.configFile, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RecordingsSetup.persist(save: true, existingDecision: "none-found"))
    }

    @MainActor
    func testProgressHeightDoesNotChangeWhenPreparationFindsTheFileCount() {
        let phases: [RecordingRemoval.Progress?] = [nil,
            .init(phase: .preparing, completed: 0, total: 0, elapsedSeconds: 0),
            .init(phase: .moving, completed: 620, total: 1200, elapsedSeconds: 2),
            .init(phase: .finishing, completed: 74321, total: 74321, elapsedSeconds: 4)]
        for width: CGFloat in [300, 460] {
            let sizes = phases.map { progress -> NSSize in
                let view = NSHostingView(rootView: RecordingsTrashProgress(progress: progress)
                    .frame(width: width))
                view.layoutSubtreeIfNeeded()
                return view.fittingSize
            }
            XCTAssertGreaterThan(sizes[0].height, 0)
            for size in sizes.dropFirst() {
                XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5,
                               "the sheet must not jump when a progress bar/count appears")
                XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
            }
        }
    }
}
