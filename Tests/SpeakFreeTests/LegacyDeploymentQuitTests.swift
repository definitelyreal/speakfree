// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import XCTest
@testable import SpeakFreeLib

final class LegacyDeploymentQuitTests: XCTestCase {
    private let installedExecutable = URL(fileURLWithPath: "/Applications/speakfree.app/Contents/MacOS/speakfree")

    func testExactLegacyIdentityRequestsNormalQuitOnce() {
        var quits = 0
        let environment = LegacyQuitEnvironment(installedCommit: { "9f4f749" }, application: { pid in
            .init(pid: pid, bundleIdentifier: "com.definitelyreal.speakfree",
                  executableURL: self.installedExecutable, terminate: { quits += 1; return true })
        })
        XCTAssertEqual(LegacyDeploymentQuit.request(pid: 42, environment: environment), .requested)
        XCTAssertEqual(quits, 1)
    }

    func testMissingOrOtherBuildNeverEvenLooksUpAProcess() {
        let commits: [String?] = [nil, "", "55fa02a", "dc80ad8", "9f4f749-other"]
        for commit in commits {
            var lookedUp = false
            let environment = LegacyQuitEnvironment(installedCommit: { commit }, application: { _ in
                lookedUp = true
                return nil
            })
            XCTAssertEqual(LegacyDeploymentQuit.request(pid: 42, environment: environment), .wrongBuild)
            XCTAssertFalse(lookedUp)
        }
    }

    func testWrongPIDBundleOrExecutableNeverQuits() {
        let cases: [(Int32, String?, URL?)] = [
            (43, "com.definitelyreal.speakfree", installedExecutable),
            (42, "com.clipy-app.Clipy", installedExecutable),
            (42, nil, installedExecutable),
            (42, "com.definitelyreal.speakfree", nil),
            (42, "com.definitelyreal.speakfree", URL(fileURLWithPath: "/tmp/speakfree")),
            (42, "com.definitelyreal.speakfree", URL(fileURLWithPath: "/Applications/speakfree.app/Contents/MacOS/another")),
        ]
        for (pid, bundle, executable) in cases {
            var quits = 0
            let environment = LegacyQuitEnvironment(installedCommit: { "9f4f749" }, application: { _ in
                .init(pid: pid, bundleIdentifier: bundle, executableURL: executable,
                      terminate: { quits += 1; return true })
            })
            XCTAssertEqual(LegacyDeploymentQuit.request(pid: 42, environment: environment), .wrongProcess)
            XCTAssertEqual(quits, 0)
        }
    }

    func testMissingProcessFailsClosed() {
        let environment = LegacyQuitEnvironment(installedCommit: { "9f4f749" }, application: { _ in nil })
        XCTAssertEqual(LegacyDeploymentQuit.request(pid: 42, environment: environment), .wrongProcess)
    }

    func testRefusedNormalQuitDoesNotRetry() {
        var quits = 0
        let environment = LegacyQuitEnvironment(installedCommit: { "9f4f749" }, application: { pid in
            .init(pid: pid, bundleIdentifier: "com.definitelyreal.speakfree",
                  executableURL: self.installedExecutable, terminate: { quits += 1; return false })
        })
        XCTAssertEqual(LegacyDeploymentQuit.request(pid: 42, environment: environment), .refused)
        XCTAssertEqual(quits, 1)
    }

    func testCommandRequiresOnePositivePID() {
        XCTAssertEqual(LegacyDeploymentQuit.pid(arguments: ["--pid", "42"]), 42)
        for args in [[], ["--pid"], ["--pid", "0"], ["--pid", "-1"],
                     ["--pid", "2147483648"], ["--pid", "42", "extra"],
                     ["--force", "42"], ["--pid", "invalid"]] {
            XCTAssertNil(LegacyDeploymentQuit.pid(arguments: args), "\(args)")
        }
    }
}
