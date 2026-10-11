import XCTest
@testable import SpeakFreeLib

final class DiscardedDictationTests: XCTestCase {
    func testADiscardedDictationIsRemembered() {
        XCTAssertEqual(DiscardedDictation.remembering("first thought", over: nil), "first thought")
    }

    func testEachDiscardOverwritesTheOneBefore() {
        XCTAssertEqual(DiscardedDictation.remembering("second", over: "first"), "second")
    }

    func testADiscardWithNoWordsKeepsTheEarlierOne() {
        // Cancelling a take where nothing was said must not wipe a recoverable dictation.
        XCTAssertEqual(DiscardedDictation.remembering("", over: "first"), "first")
        XCTAssertEqual(DiscardedDictation.remembering("  \n", over: "first"), "first")
        XCTAssertNil(DiscardedDictation.remembering("", over: nil))
    }

    func testADiscardedTakeIsNeverSavedToDisk() {
        XCTAssertFalse(DiscardedDictation.keepsRecording(savingEnabled: true, discarded: true))
        XCTAssertFalse(DiscardedDictation.keepsRecording(savingEnabled: false, discarded: true))
        XCTAssertTrue(DiscardedDictation.keepsRecording(savingEnabled: true, discarded: false))
        XCTAssertFalse(DiscardedDictation.keepsRecording(savingEnabled: false, discarded: false))
    }

    func testATakeIsOnlyDiscardedOnceMarked() {
        let take = DictationTake()
        XCTAssertFalse(take.isDiscarded)
        take.discard()
        XCTAssertTrue(take.isDiscarded)
    }

    func testDiscardingOneTakeLeavesTheNextAlone() {
        let cancelled = DictationTake()
        cancelled.discard()
        XCTAssertFalse(DictationTake().isDiscarded)
        XCTAssertTrue(DictationTake(discarded: true).isDiscarded)
    }

    func testTheRecentMenuShowsACancelledDictationLikeAnyOtherRow() {
        XCTAssertEqual(StatusBarController.recentRowTitle(age: "2m", text: "Hello there."),
                       "2m — Hello there.")
        let long = String(repeating: "word ", count: 20)
        let title = StatusBarController.recentRowTitle(age: "now", text: long)
        XCTAssertTrue(title.hasPrefix("now — word word"))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title.count, "now — ".count + 51)
        XCTAssertEqual(StatusBarController.recentRowTitle(age: "1m", text: "one\ntwo"), "1m — one two")
        XCTAssertEqual(StatusBarController.recentRowTitle(age: "1m", text: nil), "1m — (no transcript)")
        // The cancelled row carries a label in place of an age.
        XCTAssertEqual(StatusBarController.recentRowTitle(age: "Last cancelled", text: "Never mind."),
                       "Last cancelled — Never mind.")
    }

    func testThereIsNoRecoverShortcutByDefault() {
        XCTAssertNil(Config.defaultConfig.recoverDiscardedHotkey)
    }

    func testTheRecoverShortcutSurvivesAConfigRoundTripAndIsAbsentWhenUnset() throws {
        var config = Config.defaultConfig
        var json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        XCTAssertFalse(json.contains("recoverDiscardedHotkey"))
        config.recoverDiscardedHotkey = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "option", "shift"])
        json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.recoverDiscardedHotkey?.keyCode, 49)
        XCTAssertEqual(decoded.recoverDiscardedHotkey?.modifiers, ["cmd", "option", "shift"])
    }

    func testSettingsCarryTheRecoverShortcutThrough() {
        let viewModel = SettingsViewModel(config: Config.defaultConfig)
        XCTAssertNil(viewModel.recoverDiscardedHotkey)
        viewModel.recoverDiscardedHotkey = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "option", "shift"])
        XCTAssertEqual(viewModel.toConfig().recoverDiscardedHotkey?.keyCode, 49)
        viewModel.recoverDiscardedHotkey = nil
        XCTAssertNil(viewModel.toConfig().recoverDiscardedHotkey)
    }

    func testTheTwoShortcutsAreToldApart() {
        // Both shortcuts arrive through one Carbon event stream; each must only answer its own.
        XCTAssertNotEqual(PasteLastDictation(kind: .pasteLast).hotKeyID,
                          PasteLastDictation(kind: .recoverDiscarded).hotKeyID)
        XCTAssertTrue(PasteLastDictation(kind: .pasteLast).answers(hotKeyID: 1))
        XCTAssertFalse(PasteLastDictation(kind: .pasteLast).answers(hotKeyID: 2))
        XCTAssertTrue(PasteLastDictation(kind: .recoverDiscarded).answers(hotKeyID: 2))
    }
}
