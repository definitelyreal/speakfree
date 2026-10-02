// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import XCTest
@testable import SpeakFreeLib

final class ClipyQuitTests: XCTestCase {
    private final class App {
        let pid: Int32
        var terminated = false
        var acceptsQuit = true
        var quits = 0
        var onQuit: (() -> Void)?
        init(_ pid: Int32) { self.pid = pid }
        var value: ClipyQuitEnvironment.Application {
            .init(pid: pid, isTerminated: { self.terminated }, terminate: {
                self.quits += 1
                self.onQuit?()
                return self.acceptsQuit
            })
        }
    }

    private final class Rig {
        var apps: [App] = []
        var now: TimeInterval = 0
        var waits = 0
        var onWait: (() -> Void)?
        var environment: ClipyQuitEnvironment {
            .init(applications: { self.apps.filter { !$0.terminated }.map(\.value) },
                  uptime: { self.now }, wait: {
                      self.now += 0.25
                      self.waits += 1
                      self.onWait?()
                  })
        }
    }

    func testAbsentClipyIsImmediateNoOp() {
        let rig = Rig()
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .stopped)
        XCTAssertEqual(rig.waits, 0)
    }

    func testEveryExistingInstanceMustExitAfterNormalQuit() {
        let rig = Rig()
        let first = App(11), second = App(12)
        rig.apps = [first, second]
        rig.onWait = {
            first.terminated = true
            second.terminated = rig.waits >= 2
        }
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .stopped)
        XCTAssertEqual(first.quits, 1)
        XCTAssertEqual(second.quits, 1)
        XCTAssertEqual(rig.waits, 2)
    }

    func testRefusedQuitAbortsWithoutRetryOrWaiting() {
        let rig = Rig()
        let app = App(11)
        app.acceptsQuit = false
        rig.apps = [app]
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .refused)
        XCTAssertEqual(app.quits, 1)
        XCTAssertEqual(rig.waits, 0)
    }

    func testAcceptedRequestThatNeverExitsTimesOutWithoutEscalation() {
        let rig = Rig()
        let app = App(11)
        rig.apps = [app]
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .timedOut)
        XCTAssertEqual(app.quits, 1)
        XCTAssertEqual(rig.now, 1)
        XCTAssertFalse(app.terminated)
    }

    func testNewInstanceDuringWaitAbortsWithoutQuittingNewInstance() {
        let rig = Rig()
        let original = App(11), replacement = App(12)
        rig.apps = [original]
        rig.onWait = {
            original.terminated = true
            rig.apps = [replacement]
        }
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .relaunched)
        XCTAssertEqual(original.quits, 1)
        XCTAssertEqual(replacement.quits, 0)
    }

    func testExitRacingRefusedRequestStillSucceedsAfterAbsentReadback() {
        let rig = Rig()
        let app = App(11)
        app.acceptsQuit = false
        app.onQuit = { app.terminated = true }
        rig.apps = [app]
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .stopped)
        XCTAssertEqual(app.quits, 1)
    }

    func testDeadlineCannotBeExtendedByAnEarlierQuitRequest() {
        let rig = Rig()
        let first = App(11), second = App(12)
        first.onQuit = { rig.now = 2 }
        rig.apps = [first, second]
        XCTAssertEqual(DeploymentClipyQuit.quit(environment: rig.environment, timeout: 1), .timedOut)
        XCTAssertEqual(first.quits, 1)
        XCTAssertEqual(second.quits, 0)
    }

    func testCLIOnlyAcceptsBoundedTimeoutArguments() {
        XCTAssertEqual(DeploymentClipyQuit.timeout(arguments: []), 30)
        XCTAssertEqual(DeploymentClipyQuit.timeout(arguments: ["--timeout", "1"]), 1)
        XCTAssertEqual(DeploymentClipyQuit.timeout(arguments: ["--timeout", "60"]), 60)
        for args in [["--timeout"], ["--force"], ["--timeout", "0"],
                     ["--timeout", "61"], ["--timeout", "nan"],
                     ["--timeout", "-1"], ["--timeout", "30", "extra"]] {
            XCTAssertNil(DeploymentClipyQuit.timeout(arguments: args), "\(args)")
        }
    }
}
