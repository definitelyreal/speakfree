import XCTest
@testable import SpeakFreeLib

final class PasteLastDictationTests: XCTestCase {
    func testPastesTheLastDictation() {
        XCTAssertEqual(PasteLastDictation.textToPaste(last: "hello there"), "hello there")
    }

    func testNothingToPasteBeforeAnyDictation() {
        XCTAssertNil(PasteLastDictation.textToPaste(last: nil))
        XCTAssertNil(PasteLastDictation.textToPaste(last: ""))
        XCTAssertNil(PasteLastDictation.textToPaste(last: "  \n"))
    }

    func testThereIsNoShortcutByDefault() {
        XCTAssertNil(Config.defaultConfig.pasteLastHotkey)
        XCTAssertNil(PasteLastDictation.registration(for: nil))
    }

    func testAChosenShortcutIsRegisteredWithItsModifiers() {
        let registration = PasteLastDictation.registration(
            for: HotkeyConfig(keyCode: 9, modifiers: ["ctrl", "option"]))
        XCTAssertEqual(registration?.keyCode, 9)
        XCTAssertEqual(registration?.carbonModifiers, UInt32(4096 | 2048))  // controlKey | optionKey
        let all = PasteLastDictation.registration(
            for: HotkeyConfig(keyCode: 35, modifiers: ["cmd", "shift"]))
        XCTAssertEqual(all?.carbonModifiers, UInt32(256 | 512))  // cmdKey | shiftKey
    }

    func testAShortcutNeedsARealModifier() {
        // A bare key, or Shift alone, would swallow ordinary typing system-wide.
        XCTAssertFalse(PasteLastDictation.isUsable(HotkeyConfig(keyCode: 9, modifiers: [])))
        XCTAssertFalse(PasteLastDictation.isUsable(HotkeyConfig(keyCode: 9, modifiers: ["shift"])))
        XCTAssertNil(PasteLastDictation.registration(for: HotkeyConfig(keyCode: 9, modifiers: [])))
        XCTAssertTrue(PasteLastDictation.isUsable(HotkeyConfig(keyCode: 9, modifiers: ["cmd", "shift"])))
    }

    func testAModifierKeyOnItsOwnIsNotAShortcut() {
        for modifierKeyCode: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            XCTAssertFalse(PasteLastDictation.isUsable(
                HotkeyConfig(keyCode: modifierKeyCode, modifiers: ["ctrl"])))
        }
    }

    func testTheShortcutSurvivesAConfigRoundTripAndIsAbsentWhenUnset() throws {
        var config = Config.defaultConfig
        var json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        XCTAssertFalse(json.contains("pasteLastHotkey"))
        config.pasteLastHotkey = HotkeyConfig(keyCode: 9, modifiers: ["ctrl", "option"])
        json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pasteLastHotkey?.keyCode, 9)
        XCTAssertEqual(decoded.pasteLastHotkey?.modifiers, ["ctrl", "option"])
    }

    func testSettingsCarryTheShortcutThrough() {
        let viewModel = SettingsViewModel(config: Config.defaultConfig)
        XCTAssertNil(viewModel.pasteLastHotkey)
        viewModel.pasteLastHotkey = HotkeyConfig(keyCode: 9, modifiers: ["ctrl", "option"])
        XCTAssertEqual(viewModel.toConfig().pasteLastHotkey?.keyCode, 9)
        viewModel.pasteLastHotkey = nil
        XCTAssertNil(viewModel.toConfig().pasteLastHotkey)
    }

    func testWaitsForTheShortcutModifiersToBeReleasedBeforeInserting() {
        XCTAssertFalse(PasteLastDictation.modifiersReleased([.maskControl, .maskAlternate]))
        XCTAssertFalse(PasteLastDictation.modifiersReleased([.maskAlternate]))
        XCTAssertFalse(PasteLastDictation.modifiersReleased([.maskCommand]))
        XCTAssertTrue(PasteLastDictation.modifiersReleased([]))
        XCTAssertTrue(PasteLastDictation.modifiersReleased([.maskAlphaShift, .maskNonCoalesced]))
    }
}
