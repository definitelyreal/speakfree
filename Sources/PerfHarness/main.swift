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

/// Parse `--policy flat|adaptive` (T2.1). Defaults to flat (the legacy 300ms tax = BEFORE baseline).
func postBufferPolicy(in args: [String]) -> Benchmark.PostBuffer {
    let raw = (value(for: "--policy", in: args) ?? "flat").lowercased()
    guard let p = Benchmark.PostBuffer(rawValue: raw) else { fail("unknown --policy '\(raw)' (want flat|adaptive)") }
    return p
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

func runBenchmark(iterations: Int, engines: [Benchmark.EngineSpec],
                  postBuffer: Benchmark.PostBuffer = .flat,
                  fixturesDir: String? = nil) -> PerfReport {
    let dir = fixturesDir.map { URL(fileURLWithPath: $0) } ?? Benchmark.fixturesDir()
    let fixtures = Benchmark.fixtureWavs(in: dir)
    guard !fixtures.isEmpty else { fail("no fixtures found in \(dir.path)") }

    var engineReports: [EngineReport] = []
    for spec in engines {
        FileHandle.standardError.write(Data("perf-harness: benchmarking \(spec.engineID)/\(spec.model) over \(fixtures.count) fixtures × \(iterations) iters (post-buffer: \(postBuffer.rawValue))…\n".utf8))
        guard let rep = Benchmark.runEngine(spec, fixtures: fixtures, iterations: iterations,
                                            postBuffer: postBuffer) else {
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
    let policy = postBufferPolicy(in: args)
    let fixturesDir = value(for: "--fixtures-dir", in: args)
    let specs = resolveEngineSpecs(engineList)
    let report = runBenchmark(iterations: iters, engines: specs, postBuffer: policy, fixturesDir: fixturesDir)
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
    let policy = postBufferPolicy(in: args)
    let specs = resolveEngineSpecs(engineList)
    let candidate = runBenchmark(iterations: iters, engines: specs, postBuffer: policy)
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

case "divergence":
    // T2.3-PRE — measure streaming-partial vs final-pass word divergence on short clips.
    // Usage: perf-harness divergence [--out PATH] [--fixtures-dir DIR] [--work-dir DIR]
    //
    // --out PATH        write the markdown report to PATH (default: stdout)
    // --fixtures-dir    override fixtures dir (default: Tests/OpenWisprTests/AudioFixtures)
    // --work-dir        directory for temp WAV clips (default: build/T2.3-PRE-clips in repo root)
    //
    // Exit codes: 0 = divergence < 1% (T2.3 cleared); 1 = divergence >= 1% (T2.3 cancelled); 2 = error.

    let fixturesDir: URL
    if let fd = value(for: "--fixtures-dir", in: args) {
        fixturesDir = URL(fileURLWithPath: fd)
    } else {
        fixturesDir = Benchmark.fixturesDir()
    }

    // Resolve work dir for temp WAV clips
    let workDir: URL
    if let wd = value(for: "--work-dir", in: args) {
        workDir = URL(fileURLWithPath: wd)
    } else {
        // Repo root is 3 levels up from this source file
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PerfHarness
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
        workDir = repoRoot.appendingPathComponent("build/T2.3-PRE-clips")
    }
    do {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    } catch {
        fail("divergence: could not create work dir \(workDir.path): \(error)")
    }

    // Resolve whisper-cli binary
    guard let whisperPath = Transcriber.findWhisperBinary() else {
        fail("divergence: whisper-cli not found; install with: brew install whisper-cpp")
    }

    // Resolve model path (tiny.en — the plan's specified model for this measurement).
    // Use Transcriber.modelExists (public) to check, then resolve the path from the
    // same candidate list Transcriber.findModel uses (internal, so we duplicate it here).
    let modelSize = "tiny.en"
    let modelFileName = "ggml-\(modelSize).bin"
    let modelCandidates: [String] = [
        "\(Config.configDir.path)/models/\(modelFileName)",
        "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
        "/usr/local/share/whisper-cpp/models/\(modelFileName)",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
    ]
    guard let modelPath = modelCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        fail("divergence: whisper model '\(modelSize)' not found; run: open-wispr download-model \(modelSize)")
    }

    let nCores = ProcessInfo.processInfo.activeProcessorCount
    let fullThreads = nCores
    let halfThreads = max(nCores / 2, 1)

    FileHandle.standardError.write(Data("""
    divergence: model=\(modelSize), whisper=\(URL(fileURLWithPath: whisperPath).lastPathComponent)
    divergence: fullThreads=\(fullThreads) halfThreads=\(halfThreads)
    divergence: fixturesDir=\(fixturesDir.path)
    divergence: workDir=\(workDir.path)
    \n
    """.utf8))

    guard let results = Divergence.measure(
        fixturesDir: fixturesDir,
        shortDurationsSeconds: [2.0, 3.0],
        whisperPath: whisperPath,
        modelPath: modelPath,
        fullThreads: fullThreads,
        halfThreads: halfThreads,
        workDir: workDir
    ) else {
        fail("divergence: measurement failed")
    }

    if results.isEmpty {
        fail("divergence: no short clips produced (are fixtures shorter than 2 s?)")
    }

    let machine = Fingerprint.current()
    let md = Divergence.renderMarkdown(
        results: results,
        whisperPath: whisperPath,
        modelPath: modelPath,
        fullThreads: fullThreads,
        halfThreads: halfThreads,
        machine: machine
    )

    // Write markdown output
    if let outPath = value(for: "--out", in: args) {
        let url = URL(fileURLWithPath: outPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try md.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            FileHandle.standardError.write(Data("divergence: wrote \(outPath)\n".utf8))
        } catch {
            fail("divergence: could not write report to \(outPath): \(error)")
        }
    } else {
        print(md)
    }

    // Compute aggregate divergence to set exit code
    let totalEditDist = results.map { $0.editDistance }.reduce(0, +)
    let totalFinalWords = results.map { $0.finalWordCount }.reduce(0, +)
    let aggregateDivPct: Double = totalFinalWords > 0
        ? Double(totalEditDist) / Double(totalFinalWords) * 100.0
        : 0.0

    FileHandle.standardError.write(Data(
        "divergence: aggregate word divergence = \(String(format: "%.4f", aggregateDivPct))% (threshold 1%)\n".utf8))

    if aggregateDivPct < 1.0 {
        FileHandle.standardError.write(Data("divergence: PROCEED — T2.3 cleared\n".utf8))
        exit(0)
    } else {
        FileHandle.standardError.write(Data("divergence: CANCEL — T2.3 not cleared\n".utf8))
        exit(1)
    }

case "-h", "--help", "help":
    print("""
    perf-harness — speakfree performance-regression harness (T2.0)

    USAGE:
      perf-harness run [--iterations N] [--engines whisper,parakeet] [--policy flat|adaptive] [--out PATH]
      perf-harness compare <candidate.json> <baseline.json> [--threshold PCT]
      perf-harness bench-and-gate [--iterations N] [--engines …] [--policy flat|adaptive] [--out PATH] --baseline PATH [--threshold PCT]
      perf-harness divergence [--out PATH] [--fixtures-dir DIR] [--work-dir DIR]

    --policy: flat = legacy 300ms tax on every dictation (default, = pre-T2.1 baseline);
              adaptive = T2.1 — stop on ~150ms trailing silence, hard cap 300ms.

    Gate fails (exit 1) only on a >+threshold% median regression vs a FINGERPRINT-MATCHING
    baseline. A non-comparable baseline prints a note and passes (exit 0). Default threshold 15%.

    divergence: exit 0 = T2.3 cleared (<1% aggregate word divergence); exit 1 = cancelled.
    """)
    exit(0)

default:
    fail("unknown command '\(command)' (run | compare | bench-and-gate | divergence | help)")
}
