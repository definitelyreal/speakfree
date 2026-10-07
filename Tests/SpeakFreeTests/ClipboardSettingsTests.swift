// ai-suggestion:unverified · session:unknown · 2026-10-05
import Foundation
import XCTest
@testable import SpeakFreeLib

/// Scratch configuration only; no clipboard, keyboard hooks, recording, or live app.
final class ClipboardSettingsTests: XCTestCase {
    private var scratch: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-clipboard-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        previousOverride = Config.configDirOverride
        Config.configDirOverride = scratch
    }

    override func tearDownWithError() throws {
        Config.configDirOverride = previousOverride
        try FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    func testLegacyConfigDisplaysClipboardDefaultsWithoutWritingOrChangingDictation() throws {
        let data = legacyConfigData()
        try data.write(to: Config.configFile)
        let original = try JSONDecoder().decode(Config.self, from: data)
        let model = SettingsViewModel(config: original)
        XCTAssertNil(original.history)
        XCTAssertFalse(model.historySettings.includeClipboard)
        XCTAssertEqual(model.historySettings.retention, .session)
        XCTAssertEqual(model.historySettings.shortcut(for: .dictation).label, "⌥⇧V")
        XCTAssertEqual(model.historySettings.shortcut(for: .clipboard).label, "⇧⌘V")
        XCTAssertFalse(model.historySettings.shortcut(for: .all).isAssigned)
        model.selectedSettingsTab = .clipboard
        XCTAssertEqual(try Data(contentsOf: Config.configFile), data)
        XCTAssertEqual(model.hotkeyKeyCode, 63)
        XCTAssertEqual(model.keyMode, .hold)
        XCTAssertEqual(model.engine, "whisper")
    }

    func testClipboardSaveChangesOnlyHistoryIncludingWhenMicrophoneWasChangedElsewhere() throws {
        let initial = legacyConfigData()
        try initial.write(to: Config.configFile)
        let model = SettingsViewModel(config: try JSONDecoder().decode(Config.self, from: initial))
        var current = try JSONDecoder().decode(Config.self, from: initial)
        current.inputDeviceUID = "synthetic-later-microphone"
        current.preDictationModeInputUID = "synthetic-restore-microphone"
        try current.save()
        let before = try nonHistoryJSON(Data(contentsOf: Config.configFile))
        var callbacks = 0
        model.onHistorySave = { callbacks += 1 }
        model.onSave = { XCTFail("Clipboard must not request a dictation reload") }
        model.historySettings.retention = .week
        model.historySettings.includeClipboard = true
        model.historySettings.setShortcut(.init(keyCode: 8, modifiers: ["ctrl", "shift"]), for: .all)
        model.saveHistorySettings()
        let savedData = try Data(contentsOf: Config.configFile)
        let saved = try JSONDecoder().decode(Config.self, from: savedData)
        XCTAssertEqual(try nonHistoryJSON(savedData), before)
        XCTAssertEqual(saved.history, model.historySettings)
        XCTAssertNil(saved.engine, "Clipboard must not persist a resolved legacy engine default")
        XCTAssertNil(saved.parakeetModel)
        XCTAssertEqual(saved.maxRecordings, 30, "Clipboard does not persist an unrelated retention migration")
        XCTAssertNil(saved.maxRecordingsUserConfirmed)
        XCTAssertEqual(saved.inputDeviceUID, "synthetic-later-microphone")
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(model.saveError)
    }

    func testClipboardSaveRefusesToOverwriteInvalidExistingConfig() throws {
        let model = SettingsViewModel(config: Config.defaultConfig)
        let invalid = Data("{broken config".utf8)
        try invalid.write(to: Config.configFile)
        var callbacks = 0
        model.onHistorySave = { callbacks += 1 }
        model.historySettings.includeClipboard = true
        model.saveHistorySettings()
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(try Data(contentsOf: Config.configFile), invalid)
    }

    func testRefreshUpdatesHistoryWithoutResettingSelectedPane() throws {
        var config = Config.defaultConfig
        let model = SettingsViewModel(config: config)
        model.selectedSettingsTab = .clipboard
        config.history = HistorySettings()
        config.history?.retention = .week
        config.history?.includeClipboard = true
        config.history?.dictationShortcut = .unassigned
        try config.save()
        model.refreshFromDisk()
        XCTAssertEqual(model.selectedSettingsTab, .clipboard)
        XCTAssertEqual(model.historySettings, config.history)
        XCTAssertEqual(model.toConfig().history, config.history)
    }

    func testRefreshAndUnchangedDefaultsDoNotSaveOrNotify() throws {
        for hasExplicitHistory in [false, true] {
            var config = try JSONDecoder().decode(Config.self, from: legacyConfigData())
            if hasExplicitHistory {
                config.history = HistorySettings()
                config.history?.retention = .week
            }
            try config.save()
            let before = try Data(contentsOf: Config.configFile)
            let model = SettingsViewModel(config: Config.defaultConfig)
            model.historySettings.retention = .off
            var callbacks = 0
            model.onHistorySave = { callbacks += 1 }
            model.refreshFromDisk()
            // The Clipboard pane's onChange receives this published disk refresh.
            model.saveHistorySettings()
            XCTAssertEqual(try Data(contentsOf: Config.configFile), before)
            XCTAssertEqual(callbacks, 0)
            XCTAssertNil(model.saveError)
        }
    }

    private func nonHistoryJSON(_ data: Data) throws -> NSDictionary {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        value.removeValue(forKey: "history")
        return value as NSDictionary
    }

    private func legacyConfigData() -> Data {
        Data("""
        {
          "hotkey": {"keyCode": 63, "modifiers": []},
          "modelSize": "small.en", "language": "en",
          "spokenPunctuation": false, "maxRecordings": 30,
          "inputDeviceUID": "synthetic-original-microphone",
          "preserveAllRecordings": true, "preBuffer": false,
          "saveRecordings": false, "reuseStreamingPartial": false
        }
        """.utf8)
    }
}
