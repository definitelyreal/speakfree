// ai-processed:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_elegance_audit · 2026-10-01
import XCTest
@testable import SpeakFreeLib

/// Pure injected warning checks: no application loop, window, sound, process signal, or mic.
final class UpdateVisibleWarningTests: XCTestCase {
    private final class Harness {
        var now: TimeInterval = 0
        var consoleAvailable = true
        var panelVisible = true
        var toneSucceeds = true
        var toneAttempts = 0
        var reports: [(Int32, String)] = []
        lazy var controller = UpdatePreparationController(
            timeout: 120, mode: .panel, requireVisibleWarning: true,
            observe: { XCTFail("Must not observe real activity"); return UpdateActivitySnapshot(active: false, changed: false) },
            consoleAvailable: { [unowned self] in self.consoleAvailable },
            warningVisible: { [unowned self] in self.panelVisible },
            playWarningTone: { [unowned self] in self.toneAttempts += 1; return self.toneSucceeds },
            clock: { [unowned self] in self.now },
            report: { [unowned self] in self.reports.append(($0, $1)) })
        func apply(at time: TimeInterval, active: Bool = false, changed: Bool = false,
                   observedAt: TimeInterval? = nil) {
            _ = controller // initialize the policy at the original clock value
            now = time
            controller.apply(UpdateActivitySnapshot(active: active, changed: changed), observedAt: observedAt ?? time)
        }
    }

    func testStrictCLIFlagComposesWithTimeoutInEitherOrder() {
        let expected = UpdatePreparation.Options(timeout: 90, requireVisibleWarning: true)
        XCTAssertEqual(UpdatePreparation.Options.parse(["--timeout", "90", "--require-visible-warning"]), expected)
        XCTAssertEqual(UpdatePreparation.Options.parse(["--require-visible-warning", "--timeout", "90"]), expected)
        XCTAssertEqual(UpdatePreparation.Options.parse(["--require-visible-warning"])?.timeout, 600)
        XCTAssertEqual(UpdatePreparation.Options.parse([])?.requireVisibleWarning, false)
        for invalid in [["--require-visible-warning", "--require-visible-warning"],
                        ["--timeout", "60", "--timeout", "90"], ["--timeout"],
                        ["--require-visible-warning", "--force"], ["--timeout", "nan"]] {
            XCTAssertNil(UpdatePreparation.Options.parse(invalid))
        }
    }

    func testStrictQuietModeRefusesBeforeAnyActivityReadOrApplicationLoop() {
        var reports: [Int32] = []
        let controller = UpdatePreparationController(
            timeout: 60, mode: .quiet, requireVisibleWarning: true,
            observe: { XCTFail("Must reject headless mode before observation"); return UpdateActivitySnapshot(active: false, changed: false) },
            consoleAvailable: { false }, report: { code, _ in reports.append(code) })
        XCTAssertEqual(controller.runToCompletion(), 4)
        XCTAssertEqual(reports, [4])
    }

    func testVisibleWarningRequiresFullQuietThenSuccessfulToneAndCountdown() {
        let h = Harness()
        h.apply(at: 0)
        h.apply(at: 29)
        XCTAssertEqual(h.toneAttempts, 0)
        XCTAssertNil(h.controller.result)
        h.apply(at: 30)
        XCTAssertEqual(h.toneAttempts, 1)
        h.apply(at: 34)
        XCTAssertNil(h.controller.result)
        h.apply(at: 35)
        XCTAssertEqual(h.controller.result, 0)
        XCTAssertEqual(h.reports.map(\.1), ["SPEAKFREE_UPDATE_READY"])
        h.apply(at: 36)
        XCTAssertEqual(h.reports.count, 1)
        XCTAssertEqual(h.toneAttempts, 1)
    }

    func testToneFailureCannotProduceReadyEvenAfterDeadline() {
        let h = Harness()
        h.toneSucceeds = false
        h.apply(at: 0)
        h.apply(at: 30)
        XCTAssertEqual(h.controller.result, 4)
        h.apply(at: 35)
        XCTAssertEqual(h.reports.map(\.0), [4])
        XCTAssertEqual(h.toneAttempts, 1)
    }

    func testLostConsoleOrPanelAbortsAtAnyStageIncludingFinalReadyObservation() {
        for loseConsole in [true, false] {
            for failureTime: TimeInterval in [0, 15, 32, 35] {
                let h = Harness()
                if failureTime > 0 { h.apply(at: 0) }
                if failureTime >= 30 { h.apply(at: 30) }
                if loseConsole { h.consoleAvailable = false } else { h.panelVisible = false }
                h.apply(at: failureTime)
                XCTAssertEqual(h.controller.result, 4)
                h.consoleAvailable = true
                h.panelVisible = true
                h.apply(at: 36)
                XCTAssertEqual(h.reports.map(\.0), [4], "A returned console must not revive a canceled attempt")
            }
        }
    }

    func testActivityDuringWarningRequiresAnotherFullWaitAndTone() {
        let h = Harness()
        h.apply(at: 0)
        h.apply(at: 30)
        h.apply(at: 31, active: true)
        h.apply(at: 32)
        h.apply(at: 59)
        XCTAssertNil(h.controller.result)
        XCTAssertEqual(h.toneAttempts, 1)
        h.apply(at: 62)
        XCTAssertEqual(h.toneAttempts, 2)
        XCTAssertNil(h.controller.result)
        h.apply(at: 67)
        XCTAssertEqual(h.controller.result, 0)
    }

    func testTimeoutNeverProducesReady() {
        let h = Harness()
        h.apply(at: 0, active: true)
        h.apply(at: 119, active: true)
        h.apply(at: 120)
        XCTAssertEqual(h.reports.map(\.0), [3])
    }

    func testChangedOrStaleActivityRestartsWarning() {
        for changed in [true, false] {
            let h = Harness()
            h.apply(at: 0)
            h.apply(at: 30)
            h.apply(at: 31, changed: changed, observedAt: changed ? 31 : 28)
            h.apply(at: 35)
            XCTAssertNil(h.controller.result)
            XCTAssertEqual(h.toneAttempts, 1)
        }
    }

    func testStrictInstallNowCannotBypassQuietOrTone() {
        let h = Harness()
        h.controller.installNow()
        h.apply(at: 0)
        XCTAssertNil(h.controller.result)
        h.apply(at: 30)
        h.controller.installNow()
        h.apply(at: 31)
        XCTAssertNil(h.controller.result)
        h.apply(at: 35)
        XCTAssertEqual(h.controller.result, 0)
        XCTAssertEqual(h.toneAttempts, 1)
    }

    func testCancellationNeverProducesReady() {
        let h = Harness()
        h.apply(at: 0)
        h.apply(at: 30)
        h.controller.cancelUpdate()
        h.apply(at: 35)
        XCTAssertEqual(h.reports.map(\.0), [2])
    }
}
