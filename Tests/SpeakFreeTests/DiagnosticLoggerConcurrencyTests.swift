// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import XCTest
@testable import SpeakFreeLib

final class DiagnosticLoggerConcurrencyTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testConcurrentLinesAndDisableBoundary() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = DiagnosticLogger(logsDirectory: dir)
        logger.setEnabled(true)
        DispatchQueue.concurrentPerform(iterations: 200) { logger.log("unique-line-\($0)-end") }
        logger.setEnabled(false)
        logger.log("must-not-appear")
        logger.flush()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        for i in 0..<200 { XCTAssertEqual(text.components(separatedBy: "unique-line-\(i)-end").count, 2) }
        XCTAssertFalse(text.contains("must-not-appear"))
        XCTAssertFalse(logger.isEnabled)
    }

    func testRotationBoundsDiskUseAndKeepsNewestMessages() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = DiagnosticLogger(logsDirectory: dir, maxFileBytes: 1024)
        logger.setEnabled(true)
        for i in 0..<100 { logger.log("\(i):" + String(repeating: "x", count: 180)) }
        logger.log("last-message")
        logger.flush()
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files {
            let attrs = try fm.attributesOfItem(atPath: file.path)
            XCTAssertLessThanOrEqual((attrs[.size] as! NSNumber).intValue, 1024)
            XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue, 0o600)
        }
        let current = try XCTUnwrap(files.first { !$0.lastPathComponent.contains(".previous.") && !$0.lastPathComponent.contains(".older.") })
        XCTAssertTrue(try String(contentsOf: current, encoding: .utf8).contains("last-message"))
        XCTAssertEqual((try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber).intValue, 0o700)
    }

    func testConcurrentInstancesUseDifferentFilesAndReenableAppends() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = DiagnosticLogger(logsDirectory: dir), b = DiagnosticLogger(logsDirectory: dir)
        a.setEnabled(true); b.setEnabled(true)
        a.log("first-instance-before"); b.log("second-instance")
        a.setEnabled(false); a.setEnabled(true); a.log("first-instance-after")
        a.flush(); b.flush()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let texts = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(texts.contains { $0.contains("first-instance-before") && $0.contains("first-instance-after") && !$0.contains("second-instance") })
    }
}
