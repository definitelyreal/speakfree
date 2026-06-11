// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.0 — Perf-regression harness CLI.
//
// Subcommands:
//   run        Benchmark the fixtures and print a table + write JSON.
//   compare    Gate a candidate JSON against a baseline JSON (exit 1 on >+15% median regression
//              vs a MATCHING-fingerprint baseline; exit 0 + note otherwise).
//   bench-and-gate   Benchmark, write JSON, then gate against a baseline in one shot (CI helper).
//
// Flags (for run / bench-and-gate):
//   --iterations N    timed iterations (default 5, minimum 5)
//   --out PATH        write the report JSON here
//   --engines LIST    comma list of whisper,parakeet (default: whisper; parakeet auto-skips if
//                     its CoreML assets aren't on disk)
//   --baseline PATH   (bench-and-gate) baseline to compare against
//   --threshold PCT   regression threshold percent (default 15)
//
// Exit codes: 0 = pass / no comparable baseline; 1 = regression; 2 = usage/runtime error.

import Foundation
import OpenWisprLib

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "run"

func value(for flag: String, in args: [String], default def: String? = nil) -> String? {
    if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
    return def
}

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("perf-harness: \(msg)\n".utf8))
    exit(code)
}

// MARK: - Engine specs

/// Build the engine specs requested via --engines, skipping parakeet if its CoreML assets aren't
/// present (B4 is best-effort: do NOT download multi-GB models).
func resolveEngineSpecs(_ list: String) -> [Benchmark.EngineSpec] {
    let requested = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    var specs: [Benchmark.EngineSpec] = []
    for id in requested {
        switch id {
        case "whisper":
            specs.append(.init(engineID: "whisper", model: "tiny.en", language: "en"))
        case "parakeet":
            let model = "parakeet-tdt-0.6b-v3"
            if parakeetModelPresent(model) {
                specs.append(.init(engineID: "parakeet", model: model, language: "en"))
            } else {
                FileHandle.standardError.write(Data(
                    "perf-harness: parakeet model '\(model)' not on disk — skipping (no download)\n".utf8))
            }
        default:
            fail("unknown engine '\(id)' (want whisper,parakeet)")
        }
    }
    if specs.isEmpty { fail("no runnable engines (whisper model missing? parakeet not on disk?)") }
    return specs
}

/// FluidAudio caches models under Application Support/FluidAudio/Models/<id> with mlmodelc dirs.
func parakeetModelPresent(_ model: String) -> Bool {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    guard let base else { return false }
    let dir = base.appendingPathComponent("FluidAudio/Models/\(model)")
    let encoder = dir.appendingPathComponent("Encoder.mlmodelc")
    return FileManager.default.fileExists(atPath: encoder.path)
}

// MARK: - run

func runBenchmark(iterations: Int, engines: [Benchmark.EngineSpec]) -> PerfReport {
    let dir = Benchmark.fixturesDir()
    let fixtures = Benchmark.fixtureWavs(in: dir)
    guard !fixtures.isEmpty else { fail("no fixtures found in \(dir.path)") }

    var engineReports: [EngineReport] = []
    for spec in engines {
        FileHandle.standardError.write(Data("perf-harness: benchmarking \(spec.engineID)/\(spec.model) over \(fixtures.count) fixtures × \(iterations) iters…\n".utf8))
        guard let rep = Benchmark.runEngine(spec, fixtures: fixtures, iterations: iterations) else {
            fail("benchmark failed for engine \(spec.engineID)")
        }
        engineReports.append(rep)
    }

    let iso = ISO8601DateFormatter()
    return PerfReport(
        schemaVersion: PerfReport.currentSchema,
        generatedAt: iso.string(from: Date()),
        fingerprint: Fingerprint.current(),
        iterations: iterations,
        engines: engineReports
    )
}

func writeReport(_ report: PerfReport, to path: String) {
    do {
        let data = try PerfJSON.encode(report)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        FileHandle.standardError.write(Data("perf-harness: wrote \(path)\n".utf8))
    } catch {
        fail("could not write report to \(path): \(error)")
    }
}

// MARK: - dispatch

switch command {

case "run":
    let iters = max(5, Int(value(for: "--iterations", in: args) ?? "5") ?? 5)
    let engineList = value(for: "--engines", in: args, default: "whisper")!
    let specs = resolveEngineSpecs(engineList)
    let report = runBenchmark(iterations: iters, engines: specs)
    print(Table.render(report))
    if let out = value(for: "--out", in: args) {
        writeReport(report, to: out)
    }
    exit(0)

case "compare":
    // perf-harness compare <candidate.json> <baseline.json> [--threshold PCT]
    let positionals = args.dropFirst().filter { !$0.hasPrefix("--") }
    guard positionals.count >= 2 else { fail("usage: perf-harness compare <candidate.json> <baseline.json> [--threshold PCT]") }
    let candidatePath = positionals[positionals.startIndex]
    let baselinePath = positionals[positionals.index(after: positionals.startIndex)]
    let threshold = Double(value(for: "--threshold", in: args) ?? "") ?? Compare.defaultThresholdPct
    do {
        let candidate = try PerfJSON.decode(PerfReport.self, from: URL(fileURLWithPath: candidatePath))
        let baseline = try PerfJSON.decode(PerfReport.self, from: URL(fileURLWithPath: baselinePath))
        let gate = Compare.gate(candidate: candidate, baseline: baseline, thresholdPct: threshold)
        print(Table.render(gate: gate, thresholdPct: threshold))
        if case .regression = gate { exit(1) }
        exit(0)
    } catch {
        fail("compare failed: \(error)")
    }

case "bench-and-gate":
    // CI helper: benchmark → write JSON → gate against a baseline (skips if none comparable).
    let iters = max(5, Int(value(for: "--iterations", in: args) ?? "5") ?? 5)
    let engineList = value(for: "--engines", in: args, default: "whisper")!
    let threshold = Double(value(for: "--threshold", in: args) ?? "") ?? Compare.defaultThresholdPct
    let specs = resolveEngineSpecs(engineList)
    let candidate = runBenchmark(iterations: iters, engines: specs)
    print(Table.render(candidate))
    if let out = value(for: "--out", in: args) { writeReport(candidate, to: out) }

    guard let baselinePath = value(for: "--baseline", in: args) else {
        FileHandle.standardError.write(Data("perf-harness: no --baseline given — benchmark only, gate skipped\n".utf8))
        exit(0)
    }
    guard FileManager.default.fileExists(atPath: baselinePath) else {
        print("GATE: SKIP — baseline file \(baselinePath) does not exist (commit a baseline to enable the gate)")
        exit(0)
    }
    do {
        let baseline = try PerfJSON.decode(PerfReport.self, from: URL(fileURLWithPath: baselinePath))
        let gate = Compare.gate(candidate: candidate, baseline: baseline, thresholdPct: threshold)
        print(Table.render(gate: gate, thresholdPct: threshold))
        if case .regression = gate { exit(1) }
        exit(0)
    } catch {
        fail("bench-and-gate: could not read baseline \(baselinePath): \(error)")
    }

case "-h", "--help", "help":
    print("""
    perf-harness — speakfree performance-regression harness (T2.0)

    USAGE:
      perf-harness run [--iterations N] [--engines whisper,parakeet] [--out PATH]
      perf-harness compare <candidate.json> <baseline.json> [--threshold PCT]
      perf-harness bench-and-gate [--iterations N] [--engines …] [--out PATH] --baseline PATH [--threshold PCT]

    Gate fails (exit 1) only on a >+threshold% median regression vs a FINGERPRINT-MATCHING
    baseline. A non-comparable baseline prints a note and passes (exit 0). Default threshold 15%.
    """)
    exit(0)

default:
    fail("unknown command '\(command)' (run | compare | bench-and-gate | help)")
}
