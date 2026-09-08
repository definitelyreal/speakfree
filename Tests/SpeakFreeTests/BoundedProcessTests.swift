// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import XCTest
@testable import SpeakFreeLib

final class BoundedProcessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testDrainsBothPipesAndPreservesExitStatus() throws {
        let output = try BoundedProcess.run(executable: shell,
            arguments: ["-c", "printf output; printf error >&2; exit 7"], timeout: 2)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "output")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "error")
        XCTAssertEqual(output.status, 7)
    }

    func testFullPipesDoNotDeadlock() throws {
        let script = "i=0; while [ $i -lt 12000 ]; do printf abcdefghij; printf 0123456789 >&2; i=$((i+1)); done"
        let output = try BoundedProcess.run(executable: shell, arguments: ["-c", script], timeout: 5)
        XCTAssertEqual(output.stdout.count, 120_000)
        XCTAssertEqual(output.stderr.count, 120_000)
    }

    func testTimeoutKillsChildThatIgnoresTermination() {
        let start = Date()
        XCTAssertThrowsError(try BoundedProcess.run(executable: shell,
            arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15)) {
            guard case BoundedProcess.Failure.timedOut = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testOutputLimitStopsUnboundedWriter() {
        XCTAssertThrowsError(try BoundedProcess.run(executable: shell,
            arguments: ["-c", "while :; do printf aaaaaaaaaaaaaaaaaaaaa; done"], timeout: 5, maxOutputBytes: 1024)) {
            guard case BoundedProcess.Failure.outputTooLarge = $0 else { return XCTFail("\($0)") }
        }
    }

    func testBudgetsScaleWithAudioButStayBounded() {
        XCTAssertEqual(Transcriber.cliTimeout(audioDuration: 3, background: false), 30)
        XCTAssertEqual(Transcriber.cliTimeout(audioDuration: 600, background: false), 1215)
        XCTAssertEqual(Transcriber.cliTimeout(audioDuration: 600, background: true), 120)
        XCTAssertEqual(Transcriber.cliTimeout(audioDuration: 3600, background: false), 1800)
    }
}
