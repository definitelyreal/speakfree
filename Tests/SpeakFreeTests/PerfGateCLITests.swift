// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// AR-2 round-1, finding 2 — the +15% perf-regression CI gate was INERT: a macos-15 runner's
// fingerprint never matched the committed dev-Mac (M3 Max) baseline, so `Compare.gate` took the
// "no comparable baseline" branch and returned PASS unconditionally. Any regression slipped through.
//
// These tests drive the REAL `perf-harness compare` CLI (which only reads two JSON files — no
// whisper / model needed) over crafted reports to pin the fix:
//   - a fingerprint MISMATCH with `--require-baseline` (what CI now passes) → EXIT 1 (loud fail),
//     never a silent green pass;
//   - a fingerprint MATCH with a +50% regression → EXIT 1 (the gate actually enforces);
//   - a fingerprint MATCH within threshold → EXIT 0.
//
// The provenance/gaming half of finding 2 (a PR may not regenerate the baseline) is enforced in
// .github/workflows/ci.yml's "Perf baseline provenance guard" step, which has no unit surface.

import XCTest

final class PerfGateCLITests: XCTestCase {

    /// Locate the built perf-harness binary next to the test bundle (same .build/<config> dir).
    private func perfHarnessURL() throws -> URL {
        let bundleDir = Bundle(for: PerfGateCLITests.self).bundleURL.deletingLastPathComponent()
        let candidate = bundleDir.appendingPathComponent("perf-harness")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: candidate.path),
                          "perf-harness binary not built next to tests at \(candidate.path)")
        return candidate
    }

    /// Minimal valid PerfReport JSON with a given fingerprint and a single whisper fixture whose
    /// inference + e2e medians are `medianMs`.
    private func reportJSON(cpu: String, cores: Int, arch: String, medianMs: Double) -> String {
        """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-06-10T00:00:00Z",
          "fingerprint": { "cpu": "\(cpu)", "cores": \(cores), "arch": "\(arch)", "os": "macOS 26.0" },
          "iterations": 5,
          "engines": [
            {
              "engine": "whisper",
              "model": "tiny.en",
              "postBufferMs": 300,
              "fixtures": [
                {
                  "fixture": "fixture-1-clean.wav",
                  "audioSeconds": 11.1,
                  "transcript": "hello",
                  "inferenceMs": { "median": \(medianMs), "min": \(medianMs), "max": \(medianMs), "mean": \(medianMs), "iterations": 5 },
                  "endToEndMs": { "median": \(medianMs), "min": \(medianMs), "max": \(medianMs), "mean": \(medianMs), "iterations": 5 }
                }
              ]
            }
          ]
        }
        """
    }

    /// Scratch dir under the build output (next to the test bundle) — NOT a system temp dir.
    /// Cleaned up in tearDown.
    private lazy var scratchDir: URL = {
        let dir = Bundle(for: PerfGateCLITests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("perfgate-scratch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func write(_ json: String, _ name: String) throws -> URL {
        let url = scratchDir.appendingPathComponent("\(name).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func runCompare(_ candidate: URL, _ baseline: URL, requireBaseline: Bool) throws -> Int32 {
        let proc = Process()
        proc.executableURL = try perfHarnessURL()
        var args = ["compare", candidate.path, baseline.path, "--threshold", "15"]
        if requireBaseline { args.append("--require-baseline") }
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    // MARK: - The bug: inert gate on fingerprint mismatch

    /// THE finding-2 regression. A fingerprint mismatch with --require-baseline (what CI passes)
    /// MUST fail (exit 1). Before the fix this returned .pass and exited 0 — the gate enforced
    /// nothing on a CI runner whose fingerprint differs from the committed baseline.
    func test_fingerprintMismatch_withRequireBaseline_failsLoudly() throws {
        let candidate = try write(reportJSON(cpu: "Apple M9 Ultra", cores: 99, arch: "arm64", medianMs: 100), "cand")
        let baseline  = try write(reportJSON(cpu: "Apple M3 Max",   cores: 16, arch: "arm64", medianMs: 100), "base")
        let status = try runCompare(candidate, baseline, requireBaseline: true)
        XCTAssertEqual(status, 1, "a non-matching baseline must HARD FAIL under --require-baseline (no silent pass)")
    }

    /// Without --require-baseline (local/dev), a mismatch still passes (exit 0) so a one-off compare
    /// on an unmatched machine doesn't hard-fail — the behavior CI deliberately overrides.
    func test_fingerprintMismatch_withoutRequireBaseline_passes() throws {
        let candidate = try write(reportJSON(cpu: "Apple M9 Ultra", cores: 99, arch: "arm64", medianMs: 100), "cand")
        let baseline  = try write(reportJSON(cpu: "Apple M3 Max",   cores: 16, arch: "arm64", medianMs: 100), "base")
        let status = try runCompare(candidate, baseline, requireBaseline: false)
        XCTAssertEqual(status, 0, "without --require-baseline a mismatch is a soft skip (exit 0)")
    }

    // MARK: - The gate actually enforces when fingerprints match

    /// Same fingerprint + a +50% regression → the gate must FAIL (exit 1). Proves the +15% gate is
    /// not a no-op when a comparable baseline exists.
    func test_matchingFingerprint_withRegression_fails() throws {
        let candidate = try write(reportJSON(cpu: "Apple M3 Max", cores: 16, arch: "arm64", medianMs: 150), "cand")
        let baseline  = try write(reportJSON(cpu: "Apple M3 Max", cores: 16, arch: "arm64", medianMs: 100), "base")
        let status = try runCompare(candidate, baseline, requireBaseline: true)
        XCTAssertEqual(status, 1, "a +50% median regression against a MATCHING baseline must fail the gate")
    }

    /// Same fingerprint, within +15% → pass (exit 0).
    func test_matchingFingerprint_withinThreshold_passes() throws {
        let candidate = try write(reportJSON(cpu: "Apple M3 Max", cores: 16, arch: "arm64", medianMs: 110), "cand")
        let baseline  = try write(reportJSON(cpu: "Apple M3 Max", cores: 16, arch: "arm64", medianMs: 100), "base")
        let status = try runCompare(candidate, baseline, requireBaseline: true)
        XCTAssertEqual(status, 0, "+10% (< +15% threshold) must pass even under --require-baseline")
    }
}
