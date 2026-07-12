import XCTest
@testable import SpeakFreeLib

/// config.json holds localAPIToken and the logs directory holds session diagnostics;
/// both were world-readable until 2026-07-11. These tests pin the hardened permissions
/// and the log-retention cap.
final class PrivacyHardeningTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakfree-privacy-tests-\(UUID().uuidString)")
        Config.configDirOverride = tempDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Config permissions

    func testSaveRestrictsConfigFileToOwner() throws {
        try Config.defaultConfig.save()
        XCTAssertEqual(try posixPermissions(at: Config.configFile), 0o600,
                       "config.json holds localAPIToken and must be owner-only")
    }

    func testSaveRestrictsConfigDirToOwner() throws {
        try Config.defaultConfig.save()
        XCTAssertEqual(try posixPermissions(at: Config.configDir), 0o700)
    }

    func testSaveReassertsPermissionsOnExistingWorldReadableFiles() throws {
        // Simulate a pre-fix install: dir and file already exist with loose permissions.
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: Config.configFile.path, contents: Data("{}".utf8),
                      attributes: [.posixPermissions: 0o644])

        try Config.defaultConfig.save()

        XCTAssertEqual(try posixPermissions(at: Config.configDir), 0o700)
        XCTAssertEqual(try posixPermissions(at: Config.configFile), 0o600)
    }

    // MARK: - Log pruning

    func testPruneDeletesOnlyStaleSessionLogs() throws {
        let fm = FileManager.default
        let logsDir = tempDir.appendingPathComponent("logs")
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let staleLog = logsDir.appendingPathComponent("speakfree-2026-01-01.log")
        let freshLog = logsDir.appendingPathComponent("speakfree-2026-07-11.log")
        let unrelated = logsDir.appendingPathComponent("keep-me.txt")
        for file in [staleLog, freshLog, unrelated] {
            fm.createFile(atPath: file.path, contents: Data("x".utf8))
        }
        let staleDate = Date().addingTimeInterval(-30 * 86_400)
        try fm.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleLog.path)
        try fm.setAttributes([.modificationDate: staleDate], ofItemAtPath: unrelated.path)

        DiagnosticLogger.pruneOldLogs(in: logsDir, olderThanDays: 14)

        XCTAssertFalse(fm.fileExists(atPath: staleLog.path), "stale session log should be pruned")
        XCTAssertTrue(fm.fileExists(atPath: freshLog.path), "recent session log must survive")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "non-log files are not ours to delete")
    }

    func testPruneKeepsLogsInsideRetentionWindow() throws {
        let fm = FileManager.default
        let logsDir = tempDir.appendingPathComponent("logs")
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let recent = logsDir.appendingPathComponent("speakfree-recent.log")
        fm.createFile(atPath: recent.path, contents: Data("x".utf8))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 86_400)],
                             ofItemAtPath: recent.path)

        DiagnosticLogger.pruneOldLogs(in: logsDir, olderThanDays: 14)

        XCTAssertTrue(fm.fileExists(atPath: recent.path))
    }
}
