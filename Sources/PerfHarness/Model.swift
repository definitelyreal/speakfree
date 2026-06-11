// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.0 — Perf-regression harness data model + machine fingerprint + summary stats.
//
// The JSON written here is the tracked baseline (Tests/PerfBaseline/baseline.json). It is
// keyed by a machine/environment fingerprint so the comparison gate only fails on a
// like-for-like baseline — a CI runner and this Mac produce different absolute numbers, so
// comparing across fingerprints would be meaningless. See compare() for the gate logic.

import Foundation

// MARK: - Machine / environment fingerprint

/// A coarse hardware fingerprint. Two reports are "comparable" iff their fingerprints match
/// on `cpu`, `cores`, and `arch` — the axes that dominate inference wall-clock. The OS version
/// is recorded for context but NOT part of the match key (point releases shouldn't invalidate
/// a baseline).
struct Fingerprint: Codable, Equatable {
    let cpu: String        // e.g. "Apple M3 Max"
    let cores: Int         // logical core count
    let arch: String       // "arm64" | "x86_64"
    let os: String         // e.g. "macOS 26.0" — context only, not part of match key

    /// The stable key two reports must agree on to be comparable.
    var matchKey: String { "\(cpu)|\(cores)|\(arch)" }

    func isComparable(to other: Fingerprint) -> Bool { matchKey == other.matchKey }

    static func current() -> Fingerprint {
        Fingerprint(
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown-cpu",
            cores: sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            arch: machineArch(),
            os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? "unknown-arch" : machine
    }
}

// MARK: - Per-fixture + per-engine measurements

/// Summary statistics over the per-iteration timing samples for a single (fixture, metric).
/// All times are milliseconds.
struct Stat: Codable, Equatable {
    let median: Double
    let min: Double
    let max: Double
    let mean: Double
    let iterations: Int

    init(samplesMs: [Double]) {
        precondition(!samplesMs.isEmpty, "Stat requires ≥1 sample")
        let sorted = samplesMs.sorted()
        self.median = Stat.medianOf(sorted)
        self.min = sorted.first!
        self.max = sorted.last!
        self.mean = samplesMs.reduce(0, +) / Double(samplesMs.count)
        self.iterations = samplesMs.count
    }

    static func medianOf(_ sorted: [Double]) -> Double {
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}

/// One fixture's measured metrics for one engine.
struct FixtureResult: Codable, Equatable {
    let fixture: String          // wav filename
    let audioSeconds: Double     // decoded duration (16k mono)
    let transcript: String       // last-iteration transcript (sanity / drift visibility)
    let inferenceMs: Stat        // engine inference wall-clock (key metric)
    let endToEndMs: Stat         // simulated key-release → text-ready (postBuffer + inference + post-proc)
    // T2.1 — the post-buffer wait baked into endToEnd for THIS fixture. With the flat policy this
    // equals EngineReport.postBufferMs (300); with the adaptive policy it's PostBufferPolicy's
    // decision over the fixture's trailing audio (≤300). Optional so pre-T2.1 baselines still decode.
    let postBufferMs: Double?
}

/// All fixtures for one engine (whisper or parakeet).
struct EngineReport: Codable, Equatable {
    let engine: String           // "whisper" | "parakeet"
    let model: String            // model id ("tiny.en", "parakeet-tdt-0.6b-v3")
    let postBufferMs: Double     // the post-key-release CAP (300) — worst-case wait baked into e2e
    // T2.1 — "flat" (legacy 300ms tax) or "adaptive" (stop on ~150ms trailing silence, 300 cap).
    // Optional so pre-T2.1 baselines decode as flat.
    let postBufferPolicy: String?
    let fixtures: [FixtureResult]
}

/// The full benchmark report = baseline file schema.
struct PerfReport: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String      // ISO-8601
    let fingerprint: Fingerprint
    let iterations: Int          // requested iterations (medians taken over this many)
    let engines: [EngineReport]

    static let currentSchema = 1
}

// MARK: - JSON helpers

enum PerfJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
