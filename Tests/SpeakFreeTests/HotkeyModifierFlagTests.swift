// Claude · 2026-07-26 · Session: 9bae1ecf-fead-495f-b611-049bccc8e80c
// Revised 2026-07-26 · Session: 78338551-f6c1-40e1-aa9b-b5793e491135 after Codex round 1
import CoreGraphics
import XCTest
@testable import SpeakFreeLib

/// Regression cover for the modifier-hotkey flag mapping.
///
/// The CGEventTap used to test `.maskSecondaryFn` for EVERY modifier hotkey, so only
/// fn (63) ever fired. Selecting Right Command — or Option, Shift, Control, either
/// side — produced a tap that received the events and did nothing, with no error
/// anywhere (Michael, 2026-07-26: "i set it to right command and it didn't work").
/// Eight of the nine selectable modifier hotkeys were dead.
///
/// The first fix carried an aggregate-bit fallback for remapped keyboards. Codex round 1
/// showed that fallback could strand a recording (the class bit stays set while the
/// OPPOSITE side is held, so a release read as "still down"), so sided modifiers are now
/// decided by the device bit alone. These tests pin that: inert beats stuck.
final class HotkeyModifierFlagTests: XCTestCase {

    // Device-dependent bits, from IOKit/hidsystem/IOLLEvent.h. Written out per key so a
    // left/right swap in the implementation fails here rather than passing a set-union check.
    private let lCmd: UInt64   = 0x0000_0008   // NX_DEVICELCMDKEYMASK
    private let rCmd: UInt64   = 0x0000_0010   // NX_DEVICERCMDKEYMASK
    private let lShift: UInt64 = 0x0000_0002   // NX_DEVICELSHIFTKEYMASK
    private let rShift: UInt64 = 0x0000_0004   // NX_DEVICERSHIFTKEYMASK
    private let lAlt: UInt64   = 0x0000_0020   // NX_DEVICELALTKEYMASK
    private let rAlt: UInt64   = 0x0000_0040   // NX_DEVICERALTKEYMASK
    private let lCtrl: UInt64  = 0x0000_0001   // NX_DEVICELCTLKEYMASK
    private let rCtrl: UInt64  = 0x0000_2000   // NX_DEVICERCTLKEYMASK

    private let aggCmd   = UInt64(CGEventFlags.maskCommand.rawValue)
    private let aggShift = UInt64(CGEventFlags.maskShift.rawValue)
    private let aggAlt   = UInt64(CGEventFlags.maskAlternate.rawValue)
    private let aggCtrl  = UInt64(CGEventFlags.maskControl.rawValue)
    private let fnBit    = UInt64(CGEventFlags.maskSecondaryFn.rawValue)

    /// keycode → (its own device bit, its class's aggregate bit, a readable name)
    private var sidedKeys: [(code: UInt16, bit: UInt64, aggregate: UInt64, name: String)] {
        [(54, rCmd, aggCmd, "right command"), (55, lCmd, aggCmd, "left command"),
         (56, lShift, aggShift, "left shift"), (60, rShift, aggShift, "right shift"),
         (58, lAlt, aggAlt, "left option"),    (61, rAlt, aggAlt, "right option"),
         (59, lCtrl, aggCtrl, "left control"), (62, rCtrl, aggCtrl, "right control")]
    }

    private func isDown(_ raw: UInt64, _ keyCode: UInt16) -> Bool {
        HotkeyManager.hotkeyIsDown(CGEventFlags(rawValue: raw), keyCode: keyCode)
    }

    // MARK: - Every selectable modifier reports its own key

    func testEachModifierKeycodeDetectsItsOwnDeviceBit() {
        for key in sidedKeys {
            XCTAssertTrue(isDown(key.bit | key.aggregate, key.code),
                          "\(key.name) (\(key.code)) not detected as down")
            XCTAssertFalse(isDown(0, key.code),
                           "\(key.name) (\(key.code)) reported down with no flags")
        }
    }

    func testFnStillDetected() {
        XCTAssertTrue(isDown(fnBit, 63))
        XCTAssertFalse(isDown(0, 63))
    }

    /// The original bug, stated directly: the fn bit alone must NOT read as a
    /// Right Command press, and Right Command must NOT need the fn bit.
    func testRightCommandDoesNotDependOnTheFnBit() {
        XCTAssertFalse(isDown(fnBit, 54), "fn bit alone must not read as right command")
        XCTAssertTrue(isDown(rCmd | aggCmd, 54))
    }

    /// And the converse: no sided modifier may satisfy the fn hotkey.
    func testNoSidedModifierSatisfiesTheFnHotkey() {
        for key in sidedKeys {
            XCTAssertFalse(isDown(key.bit | key.aggregate, 63),
                           "\(key.name) must not read as fn down")
        }
    }

    // MARK: - Sides are told apart

    func testOppositeSideNeverTriggersThisKey() {
        for key in sidedKeys {
            guard let other = HotkeyManager.oppositeSide(of: key.code) else {
                return XCTFail("\(key.name) has no recorded opposite side")
            }
            let otherBit = HotkeyManager.modifierFlagBit(for: other)
            XCTAssertFalse(isDown(otherBit | key.aggregate, key.code),
                           "\(key.name) fired from its opposite side (\(other))")
        }
    }

    /// BLOCKER 1 from Codex round 1. With left Command already held, releasing right
    /// Command still leaves the AGGREGATE command bit set. If the aggregate bit were
    /// trusted, that key-up would read as "still down", `modifierPressed` would never
    /// clear, and the recording could never be stopped.
    func testReleaseIsSeenWhileTheOtherSideIsStillHeld() {
        for key in sidedKeys {
            guard let other = HotkeyManager.oppositeSide(of: key.code) else { continue }
            let otherBit = HotkeyManager.modifierFlagBit(for: other)
            XCTAssertTrue(isDown(key.bit | otherBit | key.aggregate, key.code),
                          "\(key.name): both sides down, this one is down")
            XCTAssertFalse(isDown(otherBit | key.aggregate, key.code),
                           "\(key.name): released while the other side is held must read UP")
        }
    }

    // MARK: - No aggregate fallback (the fix for the stranded-recording blocker)

    /// Aggregate-only flags must NOT read as down. An exotic remapper that posts only
    /// class bits leaves a sided hotkey inert — which is the pre-fix behavior, harmless
    /// and visible. Trusting the aggregate instead risked a take that never ends.
    func testAggregateOnlyFlagsDoNotStartASidedHotkey() {
        for key in sidedKeys {
            XCTAssertFalse(isDown(key.aggregate, key.code),
                           "\(key.name) must not fire on the aggregate class bit alone")
        }
    }

    /// The symmetric half: aggregate-only can never make a release look like a hold.
    /// This is the property that makes "inert" safe — down and up agree.
    func testAggregateOnlyIsConsistentBetweenPressAndRelease() {
        for key in sidedKeys {
            XCTAssertEqual(isDown(key.aggregate, key.code), isDown(0, key.code),
                           "\(key.name): aggregate-only must be indistinguishable from released")
        }
    }

    // MARK: - Mapping table integrity

    func testEveryModifierKeycodeMapsToItsExactDeviceBit() {
        for key in sidedKeys {
            XCTAssertEqual(HotkeyManager.modifierFlagBit(for: key.code), key.bit,
                           "\(key.name) (\(key.code)) maps to the wrong device bit")
            XCTAssertNotEqual(HotkeyManager.modifierFlagBit(for: key.code), fnBit,
                              "no non-fn modifier may map to the fn bit — that was the bug")
        }
        XCTAssertEqual(HotkeyManager.modifierFlagBit(for: 63), fnBit)
        let bits = sidedKeys.map(\.bit)
        XCTAssertEqual(Set(bits).count, bits.count, "device bits must be unique per key")
    }

    func testOppositeSidePairingIsSymmetricAndComplete() {
        for key in sidedKeys {
            let other = HotkeyManager.oppositeSide(of: key.code)
            XCTAssertNotNil(other, "\(key.name) must have an opposite side")
            XCTAssertEqual(other.flatMap { HotkeyManager.oppositeSide(of: $0) }, key.code,
                           "\(key.name): opposite-of-opposite must be itself")
        }
        XCTAssertNil(HotkeyManager.oppositeSide(of: 63), "fn has no sides")
    }

    /// An unknown keycode owns no key, so it can never read as down — previously the
    /// switch defaulted to the fn bit, which made any junk config alias fn.
    func testUnknownKeycodeOwnsNoBitAndIsNeverDown() {
        XCTAssertEqual(HotkeyManager.modifierFlagBit(for: 999), 0)
        XCTAssertFalse(isDown(fnBit, 999))
        XCTAssertFalse(isDown(UInt64.max, 999))
        XCTAssertFalse(HotkeyManager.hotkeyIsPhysicallyDown(keyCode: 999))
    }

    // MARK: - State machine
    //
    // Codex round 2 was right that helper-level assertions alone don't prove the machine
    // behaves. These drive the SAME two reducers production uses — `fnTransition` and
    // `releaseIsPhantom` — over realistic flag sequences, and count the callbacks that would
    // fire. `hotkeyIsPhysicallyDown` is passed in rather than read, so the hardware-dependent
    // case can be exercised instead of passing vacuously (the old
    // testPhysicalStateReadsUpWhenNoKeyIsHeld asserted false against a machine where nothing
    // was held, which any always-false implementation would also satisfy).

    /// Replays a flag sequence through the real reducers, returning WHICH steps fired a
    /// callback. The indices matter, not just the counts: a take that ends two steps late
    /// still ends, so a count-only assertion passes against the very bug this pins. (Caught
    /// by mutation-testing these tests against the old aggregate-fallback implementation —
    /// the count-only version of `testRightCommandTakeEndsWhileLeftCommandStaysHeld` passed
    /// happily because the final all-keys-up step released it.)
    private func runMachine(
        keyCode: UInt16,
        flagSequence: [UInt64],
        physicallyDown: (UInt64) -> Bool = { _ in false }
    ) -> (downs: [Int], ups: [Int]) {
        var pressed = false
        var streak = 0
        var downs: [Int] = []
        var ups: [Int] = []
        for (step, raw) in flagSequence.enumerated() {
            let isDown = HotkeyManager.hotkeyIsDown(CGEventFlags(rawValue: raw), keyCode: keyCode)
            switch HotkeyManager.fnTransition(fnDown: isDown, modifierPressed: pressed) {
            case .keyDown:
                pressed = true
                downs.append(step)
            case .keyUp:
                if HotkeyManager.releaseIsPhantom(physicallyDown: physicallyDown(raw),
                                                  phantomUpStreak: streak) {
                    streak += 1
                    continue
                }
                streak = 0
                pressed = false
                ups.append(step)
            case .none:
                continue
            }
        }
        return (downs, ups)
    }

    /// The round-1 BLOCKER as a sequence: hold right Command, then left Command, then let go
    /// of right while left stays down. Exactly one take, and it ends.
    func testRightCommandTakeEndsWhileLeftCommandStaysHeld() {
        let result = runMachine(keyCode: 54, flagSequence: [
            rCmd | aggCmd,          // 0: right Cmd down          -> start
            rCmd | lCmd | aggCmd,   // 1: left Cmd joins          -> no change
            lCmd | aggCmd,          // 2: right Cmd released      -> STOP (the bug: didn't)
            aggCmd,                 // 3: left Cmd released (lingering aggregate)
            0,                      // 4: everything up
        ])
        XCTAssertEqual(result.downs, [0], "exactly one take, starting on the right-Cmd press")
        XCTAssertEqual(result.ups, [2],
                       "the take must end ON the right-Cmd release (step 2), not later once "
                       + "the other side happens to come up too")
    }

    /// The same shape for every sided modifier, not just the one Michael happened to try.
    func testEverySidedModifierCompletesAPressReleaseCycle() {
        for key in sidedKeys {
            guard let other = HotkeyManager.oppositeSide(of: key.code) else { continue }
            let otherBit = HotkeyManager.modifierFlagBit(for: other)
            let result = runMachine(keyCode: key.code, flagSequence: [
                key.bit | key.aggregate,
                key.bit | otherBit | key.aggregate,
                otherBit | key.aggregate,
                0,
            ])
            XCTAssertEqual(result.downs, [0], "\(key.name): one take, on its own press")
            XCTAssertEqual(result.ups, [2], "\(key.name): take must end on its own release")
        }
    }

    func testFnCompletesAPressReleaseCycle() {
        let result = runMachine(keyCode: 63, flagSequence: [fnBit, fnBit, 0, 0])
        XCTAssertEqual(result.downs, [0])
        XCTAssertEqual(result.ups, [2])
    }

    /// A phantom up mid-hold is swallowed, and the real release still lands: one take.
    func testPhantomUpIsSwallowedButTheRealReleaseStillEndsTheTake() {
        var hardwareSaysDown = true
        let result = runMachine(
            keyCode: 54,
            flagSequence: [
                rCmd | aggCmd,   // down
                0,               // phantom up while the key is physically held
                rCmd | aggCmd,   // flap back down
                0,               // genuine release
            ],
            physicallyDown: { raw in
                // Hardware reports "still down" for the phantom, then the user really lets go.
                if raw == 0 && !hardwareSaysDown { return false }
                if raw == 0 { hardwareSaysDown = false; return true }
                return true
            })
        XCTAssertEqual(result.downs, [0], "the flap must not start a second take")
        XCTAssertEqual(result.ups, [3], "the genuine release must end the take")
    }

    /// The failsafe: if the hardware read is stuck saying "down", the take still ends rather
    /// than recording forever. This is the property that makes trusting the HID read safe.
    func testAStuckHardwareReadStillEndsTheTakeWithinTheStreakCap() {
        let ups = Array(repeating: UInt64(0), count: 12)
        let result = runMachine(keyCode: 54,
                                flagSequence: [rCmd | aggCmd] + ups,
                                physicallyDown: { _ in true })   // hardware always lies "down"
        XCTAssertEqual(result.downs, [0])
        XCTAssertEqual(result.ups, [5], "the streak cap must let a release through after 4 swallows")
    }

    func testReleaseIsPhantomOnlyWhileHeldAndUnderTheCap() {
        for streak in 0..<4 {
            XCTAssertTrue(HotkeyManager.releaseIsPhantom(physicallyDown: true, phantomUpStreak: streak))
        }
        XCTAssertFalse(HotkeyManager.releaseIsPhantom(physicallyDown: true, phantomUpStreak: 4),
                       "the cap must stop swallowing")
        for streak in 0...5 {
            XCTAssertFalse(HotkeyManager.releaseIsPhantom(physicallyDown: false, phantomUpStreak: streak),
                           "a key that is physically up is never a phantom release")
        }
    }

    /// An aggregate-only stream leaves a sided hotkey inert — no take is ever started, so
    /// none can be stranded. This is the trade stated as a test.
    func testAggregateOnlyStreamStartsNoTakeAtAll() {
        let result = runMachine(keyCode: 54, flagSequence: [aggCmd, aggCmd, 0])
        XCTAssertEqual(result.downs, [], "no take may start from aggregate-only flags")
        XCTAssertEqual(result.ups, [], "and so none can be stranded")
    }
}
