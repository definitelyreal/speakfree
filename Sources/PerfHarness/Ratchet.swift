// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Latency ratchet (perf round 2). A committed file of CEILINGS for key-release-to-text on the
// golden fixtures that may only go down, in the style of the claude.ai speed work: a guard that
// lets the metric improve and fails the build when it gets worse.
//
// Two layers, because wall-clock time on shared CI runners is too noisy to block on (the perf job
// comment in ci.yml records +35-66% run-to-run swings):
//
//   1. Deterministic (blocks everywhere, tolerance 0): the post-release wait the production
//      PostBufferPolicy decides over each fixture's tail. This is the part of key-release-to-text
//      that produced the 1.2 s field peak, and it is arithmetic, so any increase is a real change.
//   2. Timed (blocks on a machine whose fingerprint has an entry, e.g. the dev M3 Max): the median
//      simulated key-release-to-text (post-release wait + engine inference + TextPipeline) and the
//      median inference per fixture and engine, with a tolerance (default +15%, the maintainer's locked
//      perf threshold). A first failure re-measures once so one noisy run cannot fail the gate.
//
// Subcommands (perf-harness ratchet <sub>):
//   check      measure and fail (exit 1) if anything is above its ceiling
//   lower      measure and rewrite the file with min(old, measured); never raises a ceiling
//   monotonic  <old.json> <new.json>: fail if any ceiling in new is higher than in old, or missing
//
// The timed runs use an isolated, empty config dir so the user's vocabulary, glossary, and
// settings cannot change the numbers (on the dev Mac the vocabulary boost alone moved one fixture's
// inference from ~90 ms to ~375 ms). Only the Whisper model folder is linked in (a symlink; nothing here writes to it).

import Foundation
import SpeakFreeLib

struct RatchetFile: Codable, Equatable {
    var schemaVersion: Int
    var about: String?
    /// fixture wav name -> ceiling on the decided post-release wait, ms. Tolerance 0.
    var postBufferCeilingsMs: [String: Double]
    /// Allowed slack on timed ceilings, percent. May only go down.
    var timedTolerancePct: Double
    var machines: [RatchetMachine]

    static let currentSchema = 1
}

struct RatchetMachine: Codable, Equatable {
    var fingerprint: Fingerprint
    var updatedAt: String
    var engines: [RatchetEngine]
}

struct RatchetEngine: Codable, Equatable {
    var engine: String
    var model: String
    /// fixture wav name -> ceilings
    var fixtures: [String: RatchetCeiling]
}

struct RatchetCeiling: Codable, Equatable {
    var endToEndMedianMs: Double
    var inferenceMedianMs: Double
}

enum Ratchet {

    struct Violation: CustomStringConvertible {
        let what: String
        let ceiling: Double
        let measured: Double
        var description: String {
            String(format: "  %@: measured %.1f ms, allowed %.1f ms", what, measured, ceiling)
        }
    }

    // MARK: - Deterministic layer

    /// Decided post-release wait per fixture: the SAME model the benchmark uses for
    /// `--policy adaptive` (the fixture's last cap-length of audio stands in for the tail the live
    /// poll loop sees, and a tail still at speech level pays the extended cap).
    static func postBufferWaits(fixtures: [URL]) -> [String: Double] {
        var out: [String: Double] = [:]
        for wav in fixtures {
            guard let samples = try? ProcessCommand.loadSamples(from: wav), !samples.isEmpty else {
                fail("ratchet: could not decode fixture \(wav.lastPathComponent)")
            }
            out[wav.lastPathComponent] = Benchmark.adaptiveBufferMs(forSamples: samples)
        }
        return out
    }

    static func checkPostBuffer(measured: [String: Double], ceilings: [String: Double]) -> [String] {
        var problems: [String] = []
        for (fixture, wait) in measured.sorted(by: { $0.key < $1.key }) {
            guard let ceiling = ceilings[fixture] else {
                problems.append("  \(fixture): no post-buffer ceiling (run `perf-harness ratchet lower` to add it)")
                continue
            }
            if wait > ceiling {
                problems.append(String(format: "  post-buffer %@: decided %.1f ms, ceiling %.1f ms", fixture, wait, ceiling))
            }
        }
        for fixture in ceilings.keys.sorted() where measured[fixture] == nil {
            problems.append("  \(fixture): has a ceiling but is not in the fixture manifest (a gated fixture was removed)")
        }
        return problems
    }

    // MARK: - Timed layer

    /// Point Config at an empty scratch dir (plus a symlink to the Whisper models) so
    /// the timed run cannot pick up the user's vocabulary or settings.
    static func isolateConfig(repoRoot: URL) {
        let dir = repoRoot.appendingPathComponent(".build/perf-ratchet-config")
        let fm = FileManager.default
        // Fresh every run: Config.load() writes a default config.json here, and nothing from a
        // previous run may leak into this one. Removing the dir removes the models symlink, never
        // its target.
        try? fm.removeItem(at: dir)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fail("ratchet: could not create isolated config dir \(dir.path): \(error)") }
        let realModels = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/speakfree/models")
        let link = dir.appendingPathComponent("models")
        if fm.fileExists(atPath: realModels.path) {
            try? fm.createSymbolicLink(at: link, withDestinationURL: realModels)
        }
        Config.configDirOverride = dir
    }

    static func measureTimed(specs: [Benchmark.EngineSpec], fixtures: [URL], iterations: Int) -> [EngineReport] {
        specs.map { spec in
            FileHandle.standardError.write(Data("perf-harness ratchet: timing \(spec.engineID)/\(spec.model), \(fixtures.count) fixtures x \(iterations)\n".utf8))
            guard let rep = Benchmark.runEngine(spec, fixtures: fixtures, iterations: iterations, postBuffer: .adaptive) else {
                fail("ratchet: benchmark failed for \(spec.engineID)/\(spec.model)")
            }
            return rep
        }
    }

    static func timedViolations(reports: [EngineReport], machine: RatchetMachine, tolerancePct: Double) -> [Violation] {
        var out: [Violation] = []
        let slack = 1.0 + tolerancePct / 100.0
        for rep in reports {
            guard let gated = machine.engines.first(where: { $0.engine == rep.engine && $0.model == rep.model }) else { continue }
            for f in rep.fixtures {
                guard let c = gated.fixtures[f.fixture] else {
                    out.append(Violation(what: "\(rep.engine) \(f.fixture) has no timed ceiling (run `ratchet lower`)",
                                         ceiling: 0, measured: f.endToEndMs.median))
                    continue
                }
                if f.endToEndMs.median > c.endToEndMedianMs * slack {
                    out.append(Violation(what: "\(rep.engine) \(f.fixture) key-release-to-text",
                                         ceiling: c.endToEndMedianMs * slack, measured: f.endToEndMs.median))
                }
                if f.inferenceMs.median > c.inferenceMedianMs * slack {
                    out.append(Violation(what: "\(rep.engine) \(f.fixture) inference",
                                         ceiling: c.inferenceMedianMs * slack, measured: f.inferenceMs.median))
                }
            }
        }
        return out
    }

    // MARK: - Monotonic guard

    /// Every ceiling present in `old` must be present in `new` and not higher. New entries
    /// (a new fixture, machine, or engine) are allowed.
    static func monotonicProblems(old: RatchetFile, new: RatchetFile) -> [String] {
        var p: [String] = []
        if new.timedTolerancePct > old.timedTolerancePct {
            p.append("timedTolerancePct rose \(old.timedTolerancePct) -> \(new.timedTolerancePct)")
        }
        for (fx, v) in old.postBufferCeilingsMs.sorted(by: { $0.key < $1.key }) {
            guard let nv = new.postBufferCeilingsMs[fx] else { p.append("post-buffer ceiling for \(fx) was removed"); continue }
            if nv > v { p.append("post-buffer ceiling for \(fx) rose \(v) -> \(nv)") }
        }
        for m in old.machines {
            guard let nm = new.machines.first(where: { $0.fingerprint.isComparable(to: m.fingerprint) }) else {
                p.append("machine \(m.fingerprint.matchKey) was removed"); continue
            }
            for e in m.engines {
                guard let ne = nm.engines.first(where: { $0.engine == e.engine && $0.model == e.model }) else {
                    p.append("\(m.fingerprint.matchKey) \(e.engine)/\(e.model) was removed"); continue
                }
                for (fx, c) in e.fixtures.sorted(by: { $0.key < $1.key }) {
                    guard let nc = ne.fixtures[fx] else { p.append("\(e.engine) \(fx) ceilings were removed"); continue }
                    if nc.endToEndMedianMs > c.endToEndMedianMs {
                        p.append("\(e.engine) \(fx) key-release-to-text ceiling rose \(c.endToEndMedianMs) -> \(nc.endToEndMedianMs)")
                    }
                    if nc.inferenceMedianMs > c.inferenceMedianMs {
                        p.append("\(e.engine) \(fx) inference ceiling rose \(c.inferenceMedianMs) -> \(nc.inferenceMedianMs)")
                    }
                }
            }
        }
        return p
    }

    // MARK: - Lowering

    /// Round a measurement UP to a whole ms so a ceiling is never below what was observed.
    static func ceilMs(_ v: Double) -> Double { v.rounded(.up) }

    static func lowered(_ file: RatchetFile, postBuffer: [String: Double], reports: [EngineReport],
                        fingerprint: Fingerprint, now: String) -> RatchetFile {
        var out = file
        for (fx, wait) in postBuffer {
            let m = ceilMs(wait)
            out.postBufferCeilingsMs[fx] = min(file.postBufferCeilingsMs[fx] ?? m, m)
        }
        guard !reports.isEmpty else { return out }
        var machine = out.machines.first(where: { $0.fingerprint.isComparable(to: fingerprint) })
            ?? RatchetMachine(fingerprint: fingerprint, updatedAt: now, engines: [])
        let before = machine
        for rep in reports {
            var eng = machine.engines.first(where: { $0.engine == rep.engine && $0.model == rep.model })
                ?? RatchetEngine(engine: rep.engine, model: rep.model, fixtures: [:])
            for f in rep.fixtures {
                let e2e = ceilMs(f.endToEndMs.median), inf = ceilMs(f.inferenceMs.median)
                if let old = eng.fixtures[f.fixture] {
                    eng.fixtures[f.fixture] = RatchetCeiling(endToEndMedianMs: min(old.endToEndMedianMs, e2e),
                                                             inferenceMedianMs: min(old.inferenceMedianMs, inf))
                } else {
                    eng.fixtures[f.fixture] = RatchetCeiling(endToEndMedianMs: e2e, inferenceMedianMs: inf)
                }
            }
            machine.engines.removeAll { $0.engine == rep.engine && $0.model == rep.model }
            machine.engines.append(eng)
        }
        machine.engines.sort { ($0.engine, $0.model) < ($1.engine, $1.model) }
        // Only stamp a new date when a ceiling actually moved.
        if machine.engines != before.engines { machine.updatedAt = now }
        out.machines.removeAll { $0.fingerprint.isComparable(to: fingerprint) }
        out.machines.append(machine)
        out.machines.sort { $0.fingerprint.matchKey < $1.fingerprint.matchKey }
        return out
    }

    // MARK: - IO

    static func load(_ path: String) -> RatchetFile {
        do { return try PerfJSON.decode(RatchetFile.self, from: URL(fileURLWithPath: path)) }
        catch { fail("ratchet: could not read \(path): \(error)") }
    }

    static func save(_ file: RatchetFile, to path: String) {
        do { try PerfJSON.encode(file).write(to: URL(fileURLWithPath: path)) }
        catch { fail("ratchet: could not write \(path): \(error)") }
    }

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func defaultPath() -> String {
        repoRoot().appendingPathComponent("Tests/PerfBaseline/latency-ratchet.json").path
    }

    // MARK: - CLI

    static func run(args: [String]) -> Int32 {
        let sub = args.first ?? "check"
        let rest = Array(args.dropFirst())
        switch sub {
        case "monotonic":
            let pos = rest.filter { !$0.hasPrefix("--") }
            guard pos.count >= 2 else { fail("usage: perf-harness ratchet monotonic <old.json> <new.json>") }
            let problems = monotonicProblems(old: load(pos[0]), new: load(pos[1]))
            if problems.isEmpty { print("RATCHET MONOTONIC: PASS (no ceiling rose or disappeared)"); return 0 }
            print("RATCHET MONOTONIC: FAIL, the latency ratchet may only go down:")
            problems.forEach { print("  " + $0) }
            return 1
        case "check", "lower":
            return checkOrLower(lower: sub == "lower", args: rest)
        default:
            fail("unknown ratchet subcommand '\(sub)' (check | lower | monotonic)")
        }
    }

    private static func checkOrLower(lower: Bool, args: [String]) -> Int32 {
        let path = value(for: "--ratchet", in: args) ?? defaultPath()
        let deterministicOnly = args.contains("--deterministic-only")
        let requireTimed = args.contains("--require-timed")
        let iterations = max(5, Int(value(for: "--iterations", in: args) ?? "7") ?? 7)
        let dir = value(for: "--fixtures-dir", in: args).map { URL(fileURLWithPath: $0) } ?? Benchmark.fixturesDir()
        let fixtures = Benchmark.fixtureWavs(in: dir)
        guard !fixtures.isEmpty else { fail("ratchet: no fixtures in \(dir.path)") }

        var file = FileManager.default.fileExists(atPath: path) || !lower
            ? load(path)
            : RatchetFile(schemaVersion: RatchetFile.currentSchema, about: nil,
                          postBufferCeilingsMs: [:], timedTolerancePct: Compare.defaultThresholdPct, machines: [])
        guard file.schemaVersion == RatchetFile.currentSchema else {
            fail("ratchet: schema \(file.schemaVersion) not supported (want \(RatchetFile.currentSchema))")
        }

        // Layer 1: deterministic post-release wait.
        let waits = postBufferWaits(fixtures: fixtures)
        print("latency ratchet: \(path)")
        print("post-release wait (deterministic, tolerance 0):")
        for (fx, w) in waits.sorted(by: { $0.key < $1.key }) {
            let c = file.postBufferCeilingsMs[fx].map { String(format: "%.0f", $0) } ?? "none"
            print("  " + padded(fx, 40) + String(format: "%7.1f ms   ceiling %@", w, c))
        }
        var failures = lower ? [] : checkPostBuffer(measured: waits, ceilings: file.postBufferCeilingsMs)

        // Layer 2: timed, only on a machine with an entry (check) or when asked to (lower).
        let fp = Fingerprint.current()
        var reports: [EngineReport] = []
        if !deterministicOnly {
            let machine = file.machines.first(where: { $0.fingerprint.isComparable(to: fp) })
            let engineList: String
            if let e = value(for: "--engines", in: args) {
                engineList = e
            } else if let machine, !machine.engines.isEmpty {
                engineList = machine.engines.map { engineName($0) }.joined(separator: ",")
            } else {
                engineList = "parakeet"
            }
            if machine == nil && !lower {
                let note = "no timed ceilings for this machine (\(fp.matchKey)); timed layer skipped"
                if requireTimed { failures.append("  " + note + " but --require-timed was set") }
                else { print("timed: " + note) }
            } else {
                isolateConfig(repoRoot: repoRoot())
                let specs = resolveEngineSpecs(engineList)
                reports = measureTimed(specs: specs, fixtures: fixtures, iterations: iterations)
                if !lower, let machine {
                    let missing = machine.engines.filter { e in !reports.contains { $0.engine == e.engine && $0.model == e.model } }
                    for e in missing { failures.append("  \(e.engine)/\(e.model) is gated on this machine but was not measured") }
                    var v = timedViolations(reports: reports, machine: machine, tolerancePct: file.timedTolerancePct)
                    if !v.isEmpty {
                        print("timed: \(v.count) over the allowed value; re-measuring once to rule out noise")
                        let again = measureTimed(specs: specs, fixtures: fixtures, iterations: iterations)
                        let second = timedViolations(reports: again, machine: machine, tolerancePct: file.timedTolerancePct)
                        // Fail only what failed both times.
                        v = second.filter { s in v.contains { $0.what == s.what } }
                        reports = again
                    }
                    failures += v.map { $0.description }
                }
                printTimed(reports: reports, machine: machine, tolerancePct: file.timedTolerancePct)
            }
        }

        if lower {
            let before = file
            file = lowered(file, postBuffer: waits, reports: reports, fingerprint: fp,
                           now: ISO8601DateFormatter().string(from: Date()))
            if file == before { print("RATCHET LOWER: nothing to lower"); return 0 }
            let problems = monotonicProblems(old: before, new: file)
            guard problems.isEmpty else { fail("ratchet: internal error, lowering raised a ceiling: \(problems)") }
            save(file, to: path)
            print("RATCHET LOWER: wrote \(path); review the diff and commit it")
            return 0
        }

        if failures.isEmpty { print("RATCHET: PASS"); return 0 }
        print("RATCHET: FAIL, key-release-to-text got slower than the committed ceiling:")
        failures.forEach { print($0) }
        print("The ceilings may only be lowered; see Tests/PerfBaseline/README.md.")
        return 1
    }

    static func padded(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }

    /// The --engines token that resolves back to this gated engine/model.
    static func engineName(_ e: RatchetEngine) -> String {
        guard e.engine == "parakeet" else { return e.engine }
        return e.model.hasSuffix("-v3") ? "parakeet-v3" : "parakeet"
    }

    private static func printTimed(reports: [EngineReport], machine: RatchetMachine?, tolerancePct: Double) {
        print(String(format: "timed (medians, tolerance +%.0f%%):", tolerancePct))
        for rep in reports {
            let gated = machine?.engines.first(where: { $0.engine == rep.engine && $0.model == rep.model })
            print("  \(rep.engine) \(rep.model)")
            for f in rep.fixtures {
                let c = gated?.fixtures[f.fixture]
                print("    " + padded(f.fixture, 40) + String(format: "e2e %7.1f ms (ceiling %@)  infer %6.1f ms (ceiling %@)",
                             f.endToEndMs.median,
                             c.map { String(format: "%.0f", $0.endToEndMedianMs) } ?? "none",
                             f.inferenceMs.median,
                             c.map { String(format: "%.0f", $0.inferenceMedianMs) } ?? "none"))
            }
        }
    }
}
