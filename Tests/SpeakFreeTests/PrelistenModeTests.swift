import XCTest
@testable import SpeakFreeLib

final class PrelistenModeTests: XCTestCase {
    private let option = UInt64(1 << 19)
    private let command = UInt64(1 << 20)
    private let shift = UInt64(1 << 17)

    // MARK: - The setting

    func testAnOlderConfigKeepsItsMeaning() {
        var config = Config.defaultConfig
        config.preBuffer = nil
        XCTAssertEqual(config.effectivePrelistenMode, .always)
        config.preBuffer = FlexBool(true)
        XCTAssertEqual(config.effectivePrelistenMode, .always)
        config.preBuffer = FlexBool(false)
        XCTAssertEqual(config.effectivePrelistenMode, .off)
    }

    func testTheNewSettingWinsOverTheOldOne() {
        var config = Config.defaultConfig
        config.preBuffer = FlexBool(true)
        config.preBufferMode = "shortcut"
        XCTAssertEqual(config.effectivePrelistenMode, .onShortcut)
        config.preBufferMode = "nonsense"
        XCTAssertEqual(config.effectivePrelistenMode, .always)
    }

    func testTheSettingSurvivesAConfigRoundTripAndIsAbsentWhenUnset() throws {
        var config = Config.defaultConfig
        var json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        XCTAssertFalse(json.contains("preBufferMode"))
        config.preBufferMode = PrelistenMode.onShortcut.rawValue
        json = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(json.utf8)).effectivePrelistenMode,
                       .onShortcut)
    }

    func testSettingsWriteBothTheNewSettingAndTheOldSwitch() {
        // The old switch stays truthful, so a build that only knows it still behaves sensibly.
        let viewModel = SettingsViewModel(config: Config.defaultConfig)
        XCTAssertEqual(viewModel.prelistenMode, .always)
        viewModel.prelistenMode = .onShortcut
        XCTAssertEqual(viewModel.toConfig().effectivePrelistenMode, .onShortcut)
        XCTAssertEqual(viewModel.toConfig().preBuffer?.value, false)
        viewModel.prelistenMode = .always
        XCTAssertEqual(viewModel.toConfig().preBuffer?.value, true)
        viewModel.prelistenMode = .off
        XCTAssertEqual(viewModel.toConfig().effectivePrelistenMode, .off)
    }

    // MARK: - Spotting the start of the shortcut

    func testTheShortcutsModifiersAloneArmTheMicrophone() {
        XCTAssertTrue(ShortcutArming.isArmed(flags: option, required: option))
        XCTAssertTrue(ShortcutArming.isArmed(flags: option | command, required: option | command))
    }

    func testOtherModifierCombinationsDoNot() {
        XCTAssertFalse(ShortcutArming.isArmed(flags: 0, required: option))
        XCTAssertFalse(ShortcutArming.isArmed(flags: command, required: option))
        // Option-Command is another shortcut (paste last), not the start of Option-Space.
        XCTAssertFalse(ShortcutArming.isArmed(flags: option | command, required: option))
        XCTAssertFalse(ShortcutArming.isArmed(flags: option, required: option | shift))
    }

    func testCapsLockAndOtherFlagBitsAreIgnored() {
        let capsLock = UInt64(1 << 16), function = UInt64(1 << 23)
        XCTAssertTrue(ShortcutArming.isArmed(flags: option | capsLock | function, required: option))
    }

    func testAShortcutThatIsOneKeyAloneCannotArm() {
        // fn or Right Option alone: there is no first key to see coming.
        XCTAssertFalse(ShortcutArming.isArmed(flags: option, required: 0))
        XCTAssertFalse(ShortcutArming.canArm(required: 0))
        XCTAssertTrue(ShortcutArming.canArm(required: option))
    }

    // MARK: - Opening and closing the microphone

    private final class Clock {
        var pending: [() -> Void] = []
        func schedule(_ work: @escaping () -> Void) -> () -> Void {
            let index = pending.count
            pending.append(work)
            return { [weak self] in self?.pending[index] = {} }
        }
        func fire() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    func testTheMicrophoneOpensAtOnceAndClosesAShortWhileAfterRelease() {
        let clock = Clock()
        var states: [Bool] = []
        let arming = ShortcutArming(schedule: clock.schedule) { states.append($0) }
        arming.required = option

        arming.modifiersChanged(option)
        XCTAssertEqual(states, [true])
        arming.modifiersChanged(0)
        XCTAssertEqual(states, [true], "closing waits, in case the key is pressed again")
        clock.fire()
        XCTAssertEqual(states, [true, false])
    }

    func testPressingAgainBeforeItClosesKeepsItOpen() {
        let clock = Clock()
        var states: [Bool] = []
        let arming = ShortcutArming(schedule: clock.schedule) { states.append($0) }
        arming.required = option

        arming.modifiersChanged(option)
        arming.modifiersChanged(0)
        arming.modifiersChanged(option)
        clock.fire()
        XCTAssertEqual(states, [true])
    }

    func testStoppingClosesTheMicrophone() {
        let clock = Clock()
        var states: [Bool] = []
        let arming = ShortcutArming(schedule: clock.schedule) { states.append($0) }
        arming.required = option
        arming.modifiersChanged(option)
        arming.reset()
        XCTAssertEqual(states, [true, false])
        clock.fire()
        XCTAssertEqual(states, [true, false])
    }
}
