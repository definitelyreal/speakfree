// Claude · 2026-07-26 · Session: ec24b5ef-be6a-4c4b-be38-a3b84ca63074
//
// Two UI-honesty rules, both from Michael's 2026-07-26 decisions:
//
//   1. The Globe-key notice appears exactly when the fn hotkey in toggle mode costs the user
//      the macOS emoji drawer, and its one-click fix moves the hotkey somewhere with no
//      system action attached.
//   2. The recordings checkbox must show the state the app is actually in. On a developer
//      machine DevMode forces saving ON while the checkbox bound the raw config value and
//      read "off" — so it reported not-saving while writing every dictation to disk.

import XCTest
@testable import SpeakFreeLib

final class GlobeKeyAndDevModeUITests: XCTestCase {

    // MARK: - Globe-key notice

    func test_noticeShowsOnlyForFnKeyInToggleMode() {
        XCTAssertTrue(HotkeyAdvice.suppressesGlobeKeyAction(
            keyCode: KeyCodes.fnKeyCode, toggleMode: true))

        // fn in hold mode: suppression is real but the user never taps the key, so warning
        // them would be noise (Michael's call).
        XCTAssertFalse(HotkeyAdvice.suppressesGlobeKeyAction(
            keyCode: KeyCodes.fnKeyCode, toggleMode: false))

        // No other modifier has a macOS action bound to it, in either mode.
        for keyCode in [UInt16(54), 55, 56, 58, 59, 60, 61, 62] {
            XCTAssertFalse(HotkeyAdvice.suppressesGlobeKeyAction(keyCode: keyCode, toggleMode: true),
                           "keycode \(keyCode) has no globe action to lose")
            XCTAssertFalse(HotkeyAdvice.suppressesGlobeKeyAction(keyCode: keyCode, toggleMode: false))
        }
    }

    /// The fix must not swap one conflict for another: the suggested key must itself be
    /// conflict-free in the mode the user is in.
    func test_theSuggestedFixIsItselfConflictFree() {
        XCTAssertEqual(HotkeyAdvice.globeKeyFixKeyCode, KeyCodes.rightOptionKeyCode)
        XCTAssertFalse(HotkeyAdvice.suppressesGlobeKeyAction(
            keyCode: HotkeyAdvice.globeKeyFixKeyCode, toggleMode: true))
        XCTAssertNotEqual(HotkeyAdvice.globeKeyFixKeyCode, KeyCodes.fnKeyCode)
    }

    /// The fix key must be a working hotkey. It was not until 2026-07-26: handleCGEvent tested
    /// the fn bit for every modifier, so Right Option produced a live tap that did nothing.
    /// Sending users there while it was broken would have been worse than the emoji drawer.
    func test_theSuggestedFixKeyIsActuallyDetectable() {
        let code = HotkeyAdvice.globeKeyFixKeyCode
        // Bits written out INDEPENDENTLY from IOLLEvent.h, not read back from
        // modifierFlagBit(). Deriving them from the implementation made this
        // `bit & bit != 0`, which is true for any nonzero bit and would have passed even if
        // Right Option mapped to the fn bit (2026-07-26 review).
        let rightOptionBit: UInt64 = 0x0000_0040   // NX_DEVICERALTKEYMASK
        let leftOptionBit: UInt64 = 0x0000_0020    // NX_DEVICELALTKEYMASK
        XCTAssertEqual(HotkeyManager.modifierFlagBit(for: code), rightOptionBit)
        XCTAssertTrue(HotkeyManager.hotkeyIsDown(CGEventFlags(rawValue: rightOptionBit),
                                                 keyCode: code),
                      "Right Option's own device bit does not register as down")
        XCTAssertFalse(HotkeyManager.hotkeyIsDown([], keyCode: code))
        XCTAssertFalse(HotkeyManager.hotkeyIsDown(CGEventFlags(rawValue: leftOptionBit),
                                                 keyCode: code),
                       "Left Option triggers the Right Option hotkey")
    }

    /// The banner's fix link sets the picker's selection. If Right Option were ever dropped from
    /// the picker's options, that selection would have no matching tag and the picker would
    /// render blank, with a fully green suite.
    func test_theSuggestedFixKeyIsOfferedByThePicker() {
        XCTAssertTrue(standardHotkeyOptions.contains { $0.keyCode == HotkeyAdvice.globeKeyFixKeyCode },
                      "The banner sends users to a key the hotkey picker does not offer")
        XCTAssertTrue(standardHotkeyOptions.contains { $0.keyCode == KeyCodes.fnKeyCode },
                      "fn is no longer offered, so the banner's condition is unreachable")
    }

    /// The whole feature rests on the switch actually reaching disk, and nothing covered that
    /// path (2026-07-26 review, named as the highest-value missing test). Exercised at the view
    /// model level, against a scratch config dir — never the developer's real one.
    func test_switchingToTheFixKeyPersistsAndClearsTheNotice() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-globekey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Config.configDirOverride = scratch
        defer {
            Config.configDirOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }

        var config = Config.defaultConfig
        config.hotkey = HotkeyConfig(keyCode: KeyCodes.fnKeyCode, modifiers: [])
        config.toggleMode = FlexBool(true)
        try config.save()

        let viewModel = SettingsViewModel(config: config)
        XCTAssertTrue(HotkeyAdvice.suppressesGlobeKeyAction(keyCode: viewModel.hotkeyKeyCode,
                                                           toggleMode: viewModel.toggleMode),
                      "Precondition: the banner should be showing")

        // Exactly what the banner's button body does.
        viewModel.hotkeyKeyCode = HotkeyAdvice.globeKeyFixKeyCode
        viewModel.hotkeyModifiers = []
        viewModel.save()

        let reloaded = Config.load()
        XCTAssertEqual(reloaded.hotkey.keyCode, HotkeyAdvice.globeKeyFixKeyCode,
                       "The switch never reached disk")
        XCTAssertEqual(reloaded.hotkey.modifiers, [])
        XCTAssertEqual(reloaded.toggleMode?.value, true, "The switch must not change the mode")
        XCTAssertFalse(HotkeyAdvice.suppressesGlobeKeyAction(keyCode: reloaded.hotkey.keyCode,
                                                            toggleMode: reloaded.toggleMode?.value ?? false),
                       "The banner would still show after taking its own advice")
    }

    /// A redundant transition must stay INERT, and this is the assertion that says why.
    ///
    /// A version of the globe-key fix ended the take on a redundant down, reasoning that hardware
    /// cannot repeat a down without an up between. Commit d2f47dd disproves it — a phantom fn-up
    /// followed by an fn-down in the same second, key held throughout — so that version
    /// re-created the mid-clause truncation d2f47dd had fixed. The missed-release case it was
    /// reaching for belongs to `reconcilePressedState`, which asks the hardware.
    ///
    /// `testPhantomUpIsSwallowedButTheRealReleaseStillEndsTheTake` in HotkeyModifierFlagTests is
    /// the behavioral pin (flap must not start a second take); this one pins that the reducer
    /// reports both redundant shapes as `.none` so neither can quietly acquire a side effect.
    func test_redundantTransitionsAreReportedAsNoChange() {
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: true, modifierPressed: true), .none,
                       "a down while already pressed must be a no-change transition")
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: false, modifierPressed: false), .none,
                       "an up while not pressed must be a no-change transition")
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: true, modifierPressed: false), .keyDown)
        XCTAssertEqual(HotkeyManager.fnTransition(fnDown: false, modifierPressed: true), .keyUp)
    }

    /// THE branch the globe-key fix actually is: what the tap does with an event, as opposed to
    /// which callbacks it fires. Nothing tested this. Round-3 review proved it by mutation —
    /// deleting the redundant-transition swallow entirely still left 30 tests green, because
    /// `handleCGEvent` is private and no test could observe a return value. `tapDisposition` was
    /// extracted so this test can exist; verify it still bites by making
    /// `swallowsRedundantTransition` return false and watching this fail.
    func test_tapConsumesFnTransitionsAndPassesOtherModifiersThrough() {
        // The redundant transition — round 1's emoji-drawer leak path.
        XCTAssertEqual(HotkeyManager.tapDisposition(transition: .none,
                                                    keyCode: KeyCodes.fnKeyCode,
                                                    requiredModifiersSatisfied: true),
                       .consume,
                       "a redundant fn transition must not reach the OS, or macOS can pair it "
                       + "with another and open the emoji drawer")
        for code in [UInt16(54), 55, 56, 58, 59, 60, 61, 62] {
            XCTAssertEqual(HotkeyManager.tapDisposition(transition: .none,
                                                        keyCode: code,
                                                        requiredModifiersSatisfied: true),
                           .passThrough,
                           "keycode \(code) must keep passing stray transitions through: those "
                           + "keys carry meaning for other apps")
        }

        // Steady-state suppression: the press and release of the hotkey itself. Also untested
        // before now, and it is the whole reason the emoji drawer stays shut.
        for transition in [HotkeyManager.FnTransition.keyDown, .keyUp] {
            XCTAssertEqual(HotkeyManager.tapDisposition(transition: transition,
                                                        keyCode: KeyCodes.fnKeyCode,
                                                        requiredModifiersSatisfied: true),
                           .consume)
        }

        // A press that is NOT the user's hotkey (required modifier absent) belongs to the OS.
        XCTAssertEqual(HotkeyManager.tapDisposition(transition: .keyDown,
                                                    keyCode: KeyCodes.fnKeyCode,
                                                    requiredModifiersSatisfied: false),
                       .passThrough)
        // Documenting a known asymmetry rather than leaving it latent: with a hand-edited
        // `fn + modifiers` config the down above passes through while this up is still eaten, so
        // macOS sees a down with no up. Not reachable from the Settings picker, which always
        // clears modifiers when a modifier-only key is chosen.
        XCTAssertEqual(HotkeyManager.tapDisposition(transition: .none,
                                                    keyCode: KeyCodes.fnKeyCode,
                                                    requiredModifiersSatisfied: false),
                       .consume)
    }

    /// The notice text names the key the user can actually see in the picker, and follows the
    /// project's no-em-dash rule.
    func test_noticeTextIsUsable() {
        XCTAssertTrue(HotkeyAdvice.globeKeyNotice.contains("fn"))
        XCTAssertTrue(HotkeyAdvice.globeKeyNotice.contains("emoji drawer"))
        XCTAssertTrue(HotkeyAdvice.globeKeyFixLabel.contains("Right Option"))
        XCTAssertFalse(HotkeyAdvice.globeKeyNotice.contains("\u{2014}"))
        XCTAssertFalse(HotkeyAdvice.globeKeyFixLabel.contains("\u{2014}"))
    }

    // Removed 2026-07-26: `test_onlyFnSwallowsRedundantTransitions` restated
    // `swallowsRedundantTransition`'s one-line body using the same constant, and could not see
    // the call site — a mutation that deleted the swallow left it green.
    // `test_tapConsumesFnTransitionsAndPassesOtherModifiersThrough` above covers the same keycode
    // set through the actual disposition decision, and does fail on that mutation.

    // MARK: - Dev-mode recordings checkbox

    /// What the checkbox must display, versus what the config says. The bug was these two
    /// disagreeing silently.
    func test_recordingsCheckboxReflectsWhatIsActuallyHappening() {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(false)

        // Force the marker check off explicitly: THIS Mac has ~/.speakfree-dev, so without the
        // env seam the "dev mode off" half of this test would read the developer's own machine.
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        defer { unsetenv("SPEAKFREE_DEV_MODE") }

        // Dev mode off: the checkbox and the behavior agree, both driven by config.
        XCTAssertFalse(DevMode.isActive)
        XCTAssertFalse(DevMode.effectiveSaveRecordings(config))

        // Dev mode on: saving happens regardless, so the checkbox must read ON (and be
        // disabled, since ticking it changes nothing).
        setenv("SPEAKFREE_DEV_MODE", "1", 1)
        XCTAssertTrue(DevMode.isActive)
        XCTAssertTrue(DevMode.effectiveSaveRecordings(config),
                      "Dev mode must force saving on — this is the behavior the checkbox hid")
        XCTAssertFalse(config.saveRecordings?.value ?? true,
                       "Config still says off; the checkbox must not mirror this raw value")
    }

    /// The disclosure text has to name the file, or "developer mode" is unactionable.
    func test_devModeMarkerNameIsAvailableForDisclosure() {
        XCTAssertEqual(DevMode.markerName, ".speakfree-dev")
    }
}
