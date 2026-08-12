// Claude · 2026-08-11 · Session: 9bb7d552-ac60-4aeb-b987-841018c752be
import XCTest
@testable import SpeakFreeLib

/// Regression cover for the tap-outage watchdog (2026-08-11).
///
/// The 2026-07-26 round-3 review enumerated recovery paths that lost the event tap
/// without ever reconciling the pressed state: `ensureTapHealthy`'s re-enable and
/// recreate branches, `startEventTap`'s retry ladder, `stop()`, and there was no
/// sleep/wake or fast-user-switch handling at all. Worse, the 30s health poll was
/// gated on `!isPressed` — disabled during exactly the stranded take it guards.
/// A release lost in any of those windows stranded the recording silently.
///
/// These tests drive the REAL `ensureTapHealthy` / `handleSystemResume` / `stop`
/// entry points on an un-started manager, with two seams injected: the repair action
/// (so no live CGEventTap is ever created in the test process — Worktree & Test
/// Safety) and the hardware key-state read. Each positive test was mutation-tested:
/// deleting the corresponding `reconcilePressedState` call makes it fail.
final class HotkeyWatchdogTests: XCTestCase {

    /// Keeps managers alive for the duration of each test: letting one deallocate
    /// mid-test runs `deinit → stop()`, which (correctly) force-ends the primed take
    /// and fulfills inverted expectations from the wrong path. That behavior has its
    /// own test below; everything else must hold its manager.
    private var managers: [HotkeyManager] = []

    override func tearDown() {
        // Neutralize before release so deinit's stop() has nothing to force-end and
        // can't fire a stale closure into a later test; then stop() to remove any real
        // (passive, observe-only) global monitor the real-repair test installed.
        for manager in managers {
            manager.primeForTesting(pressed: false, onKeyUp: {})
            manager.stop()
        }
        managers.removeAll()
        super.tearDown()
    }

    /// An un-started fn-hotkey manager with a stranded take: `modifierPressed` is true
    /// but (by default) the hardware says the key is up.
    private func strandedManager(
        repair: HotkeyManager.TapRepair,
        physicallyDown: Bool = false,
        onKeyUp: @escaping () -> Void
    ) -> HotkeyManager {
        let manager = HotkeyManager(keyCode: 63)
        manager.tapRepairOverride = { repair }
        manager.physicallyDownRead = { _ in physicallyDown }
        manager.primeForTesting(onKeyUp: onKeyUp)
        managers.append(manager)
        return manager
    }

    private func expectKeyUp(_ description: String, fires: Bool,
                             _ body: (@escaping () -> Void) -> Void) {
        let exp = expectation(description: description)
        exp.isInverted = !fires
        body { exp.fulfill() }
        waitForExpectations(timeout: fires ? 1.0 : 0.3)
    }

    // MARK: - The two ensureTapHealthy branches that never reconciled

    func testHealthCheckReEnableEndsAStrandedTake() {
        expectKeyUp("re-enable ends the stranded take", fires: true) { fulfill in
            let manager = strandedManager(repair: .reEnabled, onKeyUp: fulfill)
            manager.ensureTapHealthy()
        }
    }

    func testHealthCheckRecreateEndsAStrandedTake() {
        expectKeyUp("recreate ends the stranded take", fires: true) { fulfill in
            let manager = strandedManager(repair: .recreated, onKeyUp: fulfill)
            manager.ensureTapHealthy()
        }
    }

    /// The safety property that makes un-gating the 30s poll acceptable: a HEALTHY
    /// mechanism must never reconcile, so a spurious hardware "key up" read cannot
    /// truncate a live take on an ordinary poll tick.
    func testHealthyTapNeverEndsATakeEvenIfHardwareReadsUp() {
        expectKeyUp("healthy poll must not touch the take", fires: false) { fulfill in
            let manager = strandedManager(repair: .none, onKeyUp: fulfill)
            manager.ensureTapHealthy()
        }
    }

    /// A repair while the key is GENUINELY held must not end the take — the re-enabled
    /// tap will deliver the real release. This is the d2f47dd lesson: never end a take
    /// the hardware says is still running.
    func testRepairLeavesAGenuinelyHeldTakeRunning() {
        expectKeyUp("held take survives a mid-take repair", fires: false) { fulfill in
            let manager = strandedManager(repair: .reEnabled, physicallyDown: true,
                                          onKeyUp: fulfill)
            manager.ensureTapHealthy()
        }
    }

    // MARK: - Sleep / wake / fast-user-switch (known-blind windows)

    /// Wake reconciles even when the tap looks healthy: sleep is a known-blind window,
    /// and the tap usually comes back reporting enabled while the release is long gone.
    func testSystemResumeEndsAStrandedTakeEvenWithAHealthyTap() {
        expectKeyUp("wake ends the stranded take", fires: true) { fulfill in
            let manager = strandedManager(repair: .none, onKeyUp: fulfill)
            manager.handleSystemResume("wake from sleep")
        }
    }

    func testSystemResumeLeavesAGenuinelyHeldTakeRunning() {
        expectKeyUp("held take survives a resume", fires: false) { fulfill in
            let manager = strandedManager(repair: .none, physicallyDown: true,
                                          onKeyUp: fulfill)
            manager.handleSystemResume("wake from sleep")
        }
    }

    // MARK: - stop() can never deliver a later release

    /// stop() force-ends unconditionally — even if the hardware still reads the key as
    /// held, no future event will arrive through a stopped manager, so ending now is
    /// the only outcome that isn't a stranded take.
    func testStopForceEndsAnInFlightTakeEvenWhileHeld() {
        expectKeyUp("stop force-ends the take", fires: true) { fulfill in
            let manager = strandedManager(repair: .none, physicallyDown: true,
                                          onKeyUp: fulfill)
            manager.stop()
        }
    }

    func testStopWithoutATakeFiresNothing() {
        expectKeyUp("idle stop fires no key-up", fires: false) { fulfill in
            let manager = HotkeyManager(keyCode: 63)
            manager.tapRepairOverride = { .none }
            manager.physicallyDownRead = { _ in false }
            manager.primeForTesting(pressed: false, onKeyUp: fulfill)
            managers.append(manager)
            manager.stop()
        }
    }

    /// Deallocation runs `deinit → stop()`, so a manager dropped mid-take still ends it
    /// rather than stranding it. (Discovered by these very tests: unheld managers were
    /// force-ending their takes from deinit.)
    func testDeallocationForceEndsAnInFlightTake() {
        expectKeyUp("deinit ends the take", fires: true) { fulfill in
            var manager: HotkeyManager? = HotkeyManager(keyCode: 63)
            manager?.tapRepairOverride = { .none }
            manager?.physicallyDownRead = { _ in true }
            manager?.primeForTesting(onKeyUp: fulfill)
            manager = nil
        }
    }

    /// A reconciled take must not be ended twice. Two phases so each claim is pinned
    /// separately (round-1 review: the one-phase version passed even with the resume
    /// reconcile deleted, because stop()'s force-end fired the single expected key-up
    /// instead): first the RESUME must consume the press, then a following stop() must
    /// find nothing left to force-end.
    func testResumeConsumesThePressSoStopFiresNothing() {
        var manager: HotkeyManager?
        expectKeyUp("resume itself consumes the press", fires: true) { fulfill in
            manager = strandedManager(repair: .none, onKeyUp: fulfill)
            manager?.handleSystemResume("consume the stranded press")
        }
        expectKeyUp("stop after reconcile fires nothing", fires: false) { fulfill in
            // Swap only the callback — the pressed state must be whatever the resume
            // actually left, or this phase observes nothing (round-2 review).
            manager?.replaceKeyUpForTesting(fulfill)
            manager?.stop()
        }
    }

    // MARK: - The real repair path (no seam)
    //
    // Everything above injects `tapRepairOverride`, which proves the reconcile POLICY but
    // not the real `repairTapIfNeeded`. This one drives the real thing: a non-modifier
    // hotkey whose global monitor was never installed. ensureTapHealthy must detect the
    // dead mechanism, install the (passive, observe-only — never posts events) monitor,
    // and end the stranded take via startGlobalMonitor's reconcile-on-install. Mutation
    // check: a repairTapIfNeeded that ignores real state and returns .none passes every
    // seam test but fails here. Paths that genuinely cannot run in-process without a live
    // CGEventTap remain uncovered by design: the tap-disable callback, the 5-in-10s
    // rebuild, the retry ladder, the success-path reconcile, and the AppDelegate 30s
    // poll un-gating. Those were verified by review, not test.
    func testRealRepairOfADeadGlobalMonitorEndsAStrandedTake() {
        expectKeyUp("real monitor repair ends the stranded take", fires: true) { fulfill in
            let manager = HotkeyManager(keyCode: 40)  // "Other…" key: global-monitor path
            manager.physicallyDownRead = { _ in false }
            manager.primeForTesting(onKeyUp: fulfill)
            managers.append(manager)
            manager.ensureTapHealthy()  // real repairTapIfNeeded: monitor nil → install + reconcile
        }
    }

    // MARK: - The pure decision

    func testShouldReconcileTruthTable() {
        XCTAssertTrue(HotkeyManager.shouldReconcile(modifierPressed: true, physicallyDown: false),
                      "believed held + hardware up = the stranded take, must reconcile")
        XCTAssertFalse(HotkeyManager.shouldReconcile(modifierPressed: true, physicallyDown: true),
                       "genuinely held take must never be ended")
        XCTAssertFalse(HotkeyManager.shouldReconcile(modifierPressed: false, physicallyDown: false),
                       "no take, nothing to do")
        XCTAssertFalse(HotkeyManager.shouldReconcile(modifierPressed: false, physicallyDown: true),
                       "key down with no take is the OS's business, not ours")
    }
}
