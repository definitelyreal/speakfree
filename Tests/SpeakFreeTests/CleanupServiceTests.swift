import XCTest
@testable import SpeakFreeLib

/// The confined cleanup subprocess. The pure parts (executable resolution, sanitized environment,
/// prompt hardening, model IDs) are pinned directly; the process plumbing is exercised against a
/// FAKE `claude` fixture script — never the real CLI — covering valid, fenced, prose-wrapped,
/// malformed, oversized, hanging, control-char, and preflight-failure output.
final class CleanupServiceTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speakfree-cleanup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        Config.configDirOverride = scratchDir
    }

    override func tearDown() {
        Config.configDirOverride = nil
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    /// Write a fake `claude` at an absolute path in the scratch dir. Uses ONLY bash builtins plus
    /// absolute-path externals (/bin/sleep), because the sanitized PATH the service sets points only
    /// at the executable's own directory — a fixture that shelled out to `cat`/`printf` on PATH would
    /// silently fail to launch.
    private func writeFixture(mode: String, versionOK: Bool = true) -> String {
        let versionBranch = versionOK
            ? "  echo \"fake-claude 2.1.247 (test)\"\n  exit 0"
            : "  exit 3"   // no output, non-zero → preflight fails
        let body: String
        switch mode {
        case "valid":
            body = #"printf '%s' '[{"find":"teh","replace":"the","reason":"typo"}]'"#
        case "empty-array":
            body = "printf '%s' '[]'"
        case "fenced":
            body = "printf '%s\\n%s\\n%s\\n' '```json' '[{\"find\":\"a\",\"replace\":\"b\",\"reason\":\"c\"}]' '```'"
        case "prose":
            body = #"printf '%s' 'Here you go: [{"find":"a","replace":"b","reason":"c"}]'"#
        case "malformed":
            body = "printf '%s' '[this is not valid json]'"
        case "controlchars":
            body = "printf '[\\a]'"   // a bell (0x07) between the brackets — not valid JSON
        case "oversized":
            body = "printf 'a%.0s' {1..5000}"   // 5000 bytes, all builtin
        case "hanging":
            body = "/bin/sleep 5"
        default:
            body = "printf '[]'"
        }
        let script = """
        #!/bin/bash
        if [ "$1" = "--version" ]; then
        \(versionBranch)
        fi
        \(body)
        """
        let url = scratchDir.appendingPathComponent("claude-\(mode)-\(UUID().uuidString.prefix(6))")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - Pure: executable resolution

    func testResolveExecutablePrefersOverride() {
        let path = CleanupService.resolveExecutable(
            configuredPath: "/custom/claude",
            candidates: ["/opt/homebrew/bin/claude"],
            fileExists: { $0 == "/custom/claude" || $0 == "/opt/homebrew/bin/claude" })
        XCTAssertEqual(path, "/custom/claude")
    }

    func testResolveExecutableFallsThroughToKnownLocations() {
        let path = CleanupService.resolveExecutable(
            configuredPath: nil,
            candidates: ["/nope/claude", "/opt/homebrew/bin/claude"],
            fileExists: { $0 == "/opt/homebrew/bin/claude" })
        XCTAssertEqual(path, "/opt/homebrew/bin/claude")
    }

    func testResolveExecutableNoneFound() {
        let path = CleanupService.resolveExecutable(
            configuredPath: "/nope", candidates: ["/also/nope"], fileExists: { _ in false })
        XCTAssertNil(path)
    }

    // MARK: - Pure: environment

    func testSanitizedEnvironmentIsMinimal() {
        let env = CleanupService.sanitizedEnvironment(
            executablePath: "/Users/x/.local/bin/claude", home: "/Users/x")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["PATH"], "/Users/x/.local/bin")
        XCTAssertEqual(env["TERM"], "dumb")
        XCTAssertNil(env["ANTHROPIC_API_KEY"], "no API key is ever set (estate rule + subscription auth)")
        XCTAssertEqual(env.count, 3, "nothing else is inherited")
    }

    // MARK: - Pure: prompt hardening + model IDs

    func testPromptCarriesEveryHardeningLine() {
        let prompt = CleanupService.buildPrompt(raw: "RAWTEXT", pipelineText: "PIPETEXT")
        for needle in ["REPAIR ONLY", "unfinished trailing fragment", "NEVER add words",
                       "garbled spoken-punctuation", "JSON array", "Kama", "column",
                       "RAWTEXT", "PIPETEXT"] {
            XCTAssertTrue(prompt.contains(needle), "prompt must contain '\(needle)'")
        }
    }

    func testModelIDs() {
        XCTAssertEqual(CleanupService.Model.sonnet.modelID, "claude-sonnet-5")
        XCTAssertEqual(CleanupService.Model.opus.modelID, "claude-opus-5")
        XCTAssertEqual(CleanupService.Model.haiku.modelID, "claude-haiku-4-5-20251001")
    }

    func testConfinementFlagsAreTheRecordedSet() {
        // The exact confined invocation (recorded against CLI 2.1.247). A silent drift here would
        // re-enable hooks/MCP/tools against untrusted transcript input.
        XCTAssertEqual(CleanupService.baseFlags,
                       ["--print", "--safe-mode", "--no-session-persistence",
                        "--tools", "", "--output-format", "text"])
    }

    // MARK: - Subprocess against the fixture

    func testExecutableNotFoundReturnsError() async {
        let svc = CleanupService(configuredExecutablePath: "/does/not/exist",
                                 candidateLocations: [])   // never touches the real CLI
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .failure(.executableNotFound) = result {} else { XCTFail("expected executableNotFound") }
    }

    func testValidOutputParsesToEdits() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "valid"),
                                 candidateLocations: [])
        let result = await svc.cleanup(raw: "teh cat", pipelineText: "teh cat", model: .sonnet)
        switch result {
        case .success(let edits):
            XCTAssertEqual(edits, [SpanEdit(find: "teh", replace: "the", reason: "typo")])
        case .failure(let e):
            XCTFail("expected success, got \(e)")
        }
    }

    func testEmptyArrayOutputSucceedsWithNoEdits() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "empty-array"),
                                 candidateLocations: [])
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .success(let edits) = result { XCTAssertTrue(edits.isEmpty) }
        else { XCTFail("expected success with no edits") }
    }

    func testFencedOutputRejected() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "fenced"),
                                 candidateLocations: [])
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .failure(.badOutput(.notJSONArray)) = result {} else { XCTFail("expected notJSONArray, got \(result)") }
    }

    func testProseWrappedOutputRejected() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "prose"),
                                 candidateLocations: [])
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .failure(.badOutput(.notJSONArray)) = result {} else { XCTFail("expected notJSONArray, got \(result)") }
    }

    func testMalformedOutputRejected() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "malformed"),
                                 candidateLocations: [])
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .failure(.badOutput(.malformed)) = result {} else { XCTFail("expected malformed, got \(result)") }
    }

    func testControlCharOutputRejected() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "controlchars"),
                                 candidateLocations: [])
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        // A control char inside the array is not valid JSON — bounded and rejected, never crashed.
        if case .failure(.badOutput) = result {} else { XCTFail("expected badOutput, got \(result)") }
    }

    func testOversizedOutputRejected() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "oversized"),
                                 candidateLocations: [], maxOutputBytes: 512)
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .failure(.outputTooLarge) = result {} else { XCTFail("expected outputTooLarge, got \(result)") }
    }

    func testHangingOutputTimesOutAfterRetry() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "hanging"),
                                 candidateLocations: [], timeout: 1)
        let start = Date()
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        let elapsed = Date().timeIntervalSince(start)
        if case .failure(.timedOut) = result {} else { XCTFail("expected timedOut, got \(result)") }
        // 1s attempt + 1s retry; must not hang for the fixture's full 5s sleep.
        XCTAssertLessThan(elapsed, 4.5, "cleanup must never block on a stalled CLI")
    }

    func testPreflightFailureSurfacedBeforeCall() async {
        let svc = CleanupService(configuredExecutablePath: writeFixture(mode: "valid", versionOK: false),
                                 candidateLocations: [], timeout: 3)
        let result = await svc.cleanup(raw: "r", pipelineText: "p", model: .sonnet)
        if case .failure(.preflightFailed) = result {} else { XCTFail("expected preflightFailed, got \(result)") }
    }
}
