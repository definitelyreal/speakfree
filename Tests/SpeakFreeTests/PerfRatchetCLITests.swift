// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Latency ratchet (perf round 2). Drives the real `perf-harness ratchet` CLI:
//   - the committed Tests/PerfBaseline/latency-ratchet.json passes its deterministic layer (the
//     post-release wait the production PostBufferPolicy decides over each golden fixture), so a
//     change that makes key-release-to-text wait longer on a fixture fails this suite;
//   - a ceiling below the decided wait, a missing ceiling, or a ceiling for a removed fixture fails;
//   - `monotonic` rejects any ceiling that rose or disappeared and accepts lowering;
//   - `lower` never raises a ceiling.
// No model is loaded (--deterministic-only), so this runs anywhere the suite runs, including CI.

import XCTest

final class PerfRatchetCLITests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var committedRatchet: URL {
        repoRoot.appendingPathComponent("Tests/PerfBaseline/latency-ratchet.json")
    }

    private func harness() throws -> URL {
        let dir = Bundle(for: PerfRatchetCLITests.self).bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("perf-harness")
        // In CI the unit-test job builds every product, so a missing binary is a build problem;
        // skip locally only when the harness was not built alongside the tests.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "perf-harness not built next to tests at \(url.path)")
        return url
    }

    private lazy var scratch: URL = {
        let dir = Bundle(for: PerfRatchetCLITests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ratchet-scratch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func run(_ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = try harness()
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func committed() throws -> [String: Any] {
        let data = try Data(contentsOf: committedRatchet)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func write(_ obj: [String: Any], _ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return url
    }

    private func withPostBuffer(_ obj: [String: Any], _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var o = obj
        var pb = o["postBufferCeilingsMs"] as? [String: Any] ?? [:]
        edit(&pb)
        o["postBufferCeilingsMs"] = pb
        return o
    }

    // MARK: - check

    func test_committedRatchet_deterministicLayerPasses() throws {
        let r = try run(["ratchet", "check", "--deterministic-only", "--ratchet", committedRatchet.path])
        XCTAssertEqual(r.status, 0, "committed latency ratchet must pass on this tree:\n\(r.out)")
        XCTAssertTrue(r.out.contains("RATCHET: PASS"), r.out)
    }

    func test_committedRatchet_gatesEveryFixture() throws {
        let pb = try XCTUnwrap(try committed()["postBufferCeilingsMs"] as? [String: Any])
        XCTAssertEqual(Set(pb.keys), [
            "fixture-1-clean.wav", "fixture-2-spoken-comma.wav",
            "fixture-3-spoken-period-end.wav", "fixture-4-trailing-silence-period.wav",
        ])
    }

    func test_ceilingBelowDecidedWait_fails() throws {
        // fixture-4 decides 90 ms (the trailing-silence canary); a ceiling of 60 must fail.
        let obj = withPostBuffer(try committed()) { $0["fixture-4-trailing-silence-period.wav"] = 60 }
        let r = try run(["ratchet", "check", "--deterministic-only", "--ratchet", try write(obj, "low").path])
        XCTAssertEqual(r.status, 1, r.out)
        XCTAssertTrue(r.out.contains("fixture-4-trailing-silence-period.wav"), r.out)
    }

    func test_missingCeiling_fails() throws {
        let obj = withPostBuffer(try committed()) { $0.removeValue(forKey: "fixture-2-spoken-comma.wav") }
        let r = try run(["ratchet", "check", "--deterministic-only", "--ratchet", try write(obj, "missing").path])
        XCTAssertEqual(r.status, 1, r.out)
    }

    func test_ceilingForRemovedFixture_fails() throws {
        let obj = withPostBuffer(try committed()) { $0["fixture-9-gone.wav"] = 220 }
        let r = try run(["ratchet", "check", "--deterministic-only", "--ratchet", try write(obj, "gone").path])
        XCTAssertEqual(r.status, 1, r.out)
    }

    // MARK: - monotonic

    func test_monotonic_raisedCeiling_fails() throws {
        let old = try write(try committed(), "old")
        let raised = withPostBuffer(try committed()) { $0["fixture-3-spoken-period-end.wav"] = 221 }
        XCTAssertEqual(try run(["ratchet", "monotonic", old.path, try write(raised, "raised").path]).status, 1)
    }

    func test_monotonic_raisedTimedCeiling_fails() throws {
        var obj = try committed()
        var machines = try XCTUnwrap(obj["machines"] as? [[String: Any]])
        try XCTSkipIf(machines.isEmpty, "no timed machine entries committed")
        var engines = try XCTUnwrap(machines[0]["engines"] as? [[String: Any]])
        var fixtures = try XCTUnwrap(engines[0]["fixtures"] as? [String: [String: Any]])
        let key = try XCTUnwrap(fixtures.keys.sorted().first)
        let e2e = try XCTUnwrap(fixtures[key]?["endToEndMedianMs"] as? Double)
        fixtures[key]?["endToEndMedianMs"] = e2e + 1
        engines[0]["fixtures"] = fixtures
        machines[0]["engines"] = engines
        obj["machines"] = machines
        let old = try write(try committed(), "old")
        XCTAssertEqual(try run(["ratchet", "monotonic", old.path, try write(obj, "raisedTimed").path]).status, 1)
    }

    func test_monotonic_removedCeiling_fails() throws {
        let old = try write(try committed(), "old")
        let removed = withPostBuffer(try committed()) { $0.removeValue(forKey: "fixture-1-clean.wav") }
        XCTAssertEqual(try run(["ratchet", "monotonic", old.path, try write(removed, "removed").path]).status, 1)
    }

    func test_monotonic_raisedTolerance_fails() throws {
        let old = try write(try committed(), "old")
        var loose = try committed()
        loose["timedTolerancePct"] = 50
        XCTAssertEqual(try run(["ratchet", "monotonic", old.path, try write(loose, "loose").path]).status, 1)
    }

    func test_monotonic_loweredCeiling_passes() throws {
        let old = try write(try committed(), "old")
        let lowered = withPostBuffer(try committed()) { $0["fixture-1-clean.wav"] = 900 }
        XCTAssertEqual(try run(["ratchet", "monotonic", old.path, try write(lowered, "lowered").path]).status, 0)
    }

    // MARK: - lower

    func test_lower_neverRaises_andAddsMissing() throws {
        // A ceiling already below what the tree decides stays put; a missing one is added.
        let start = withPostBuffer(try committed()) {
            $0["fixture-4-trailing-silence-period.wav"] = 50
            $0.removeValue(forKey: "fixture-1-clean.wav")
        }
        let url = try write(start, "lower")
        let r = try run(["ratchet", "lower", "--deterministic-only", "--ratchet", url.path])
        XCTAssertEqual(r.status, 0, r.out)
        let after = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pb = try XCTUnwrap(after["postBufferCeilingsMs"] as? [String: Double])
        XCTAssertEqual(pb["fixture-4-trailing-silence-period.wav"], 50, "lower must never raise a ceiling")
        XCTAssertEqual(pb["fixture-1-clean.wav"], 1200, "a missing fixture gets its measured ceiling")
    }
}
