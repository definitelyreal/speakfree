// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.0 — Human-readable table rendering for the benchmark report and the gate result.

import Foundation

enum Table {

    static func render(_ report: PerfReport) -> String {
        var out = ""
        out += "speakfree — perf harness\n"
        out += "machine : \(report.fingerprint.cpu) · \(report.fingerprint.cores) cores · \(report.fingerprint.arch)\n"
        out += "os      : \(report.fingerprint.os)\n"
        out += "iters   : \(report.iterations) timed (1 warm-up discarded) · medians reported\n"
        out += "when    : \(report.generatedAt)\n"

        for eng in report.engines {
            out += "\nengine: \(eng.engine) (\(eng.model))   postBuffer=\(ms(eng.postBufferMs))\n"
            out += row("fixture", "audio", "infer(med)", "infer(min/max)", "e2e(med)", header: true)
            out += divider()
            for f in eng.fixtures {
                out += row(
                    f.fixture,
                    String(format: "%.1fs", f.audioSeconds),
                    ms(f.inferenceMs.median),
                    "\(ms(f.inferenceMs.min))/\(ms(f.inferenceMs.max))",
                    ms(f.endToEndMs.median)
                )
            }
            // Aggregate medians across fixtures (median of the per-fixture medians).
            let inferMeds = eng.fixtures.map { $0.inferenceMs.median }.sorted()
            let e2eMeds = eng.fixtures.map { $0.endToEndMs.median }.sorted()
            out += divider()
            out += row("ALL (median of medians)", "", ms(Stat.medianOf(inferMeds)), "", ms(Stat.medianOf(e2eMeds)))
        }
        return out
    }

    /// A compact whisper-vs-parakeet comparison (used in the B4 doc generation).
    static func renderEngineComparison(_ report: PerfReport) -> String {
        guard report.engines.count >= 2 else {
            return "(only one engine measured — no comparison table)\n"
        }
        var out = ""
        out += "| fixture | audio | "
        out += report.engines.map { "\($0.engine) infer(med) | \($0.engine) e2e(med)" }.joined(separator: " | ")
        out += " |\n"
        out += "|---|---|" + String(repeating: "---|---|", count: report.engines.count) + "\n"

        // Use the first engine's fixture order.
        let fixtures = report.engines[0].fixtures.map { $0.fixture }
        for fx in fixtures {
            var audio = ""
            var cells: [String] = []
            for eng in report.engines {
                if let f = eng.fixtures.first(where: { $0.fixture == fx }) {
                    audio = String(format: "%.1fs", f.audioSeconds)
                    cells.append("\(ms(f.inferenceMs.median)) | \(ms(f.endToEndMs.median))")
                } else {
                    cells.append("— | —")
                }
            }
            out += "| \(fx) | \(audio) | " + cells.joined(separator: " | ") + " |\n"
        }
        return out
    }

    static func render(gate: GateResult, thresholdPct: Double) -> String {
        switch gate {
        case .pass(let note):
            return "GATE: PASS\n\(note)\n"
        case .regression(let rows):
            var out = "GATE: FAIL — \(rows.count) median regression(s) > +\(String(format: "%.0f", thresholdPct))%\n"
            out += "  " + pad("engine", 9) + pad("fixture", 30) + pad("metric", 10)
                 + lpad("baseline", 12) + lpad("candidate", 12) + lpad("delta", 9) + "\n"
            for r in rows {
                out += "  " + pad(r.engine, 9) + pad(r.fixture, 30) + pad(r.metric, 10)
                     + lpad(ms(r.baselineMs), 12) + lpad(ms(r.candidateMs), 12)
                     + lpad(String(format: "%+.1f%%", r.deltaPct), 9) + "\n"
            }
            return out
        }
    }

    // MARK: - cell helpers

    private static func ms(_ v: Double) -> String { String(format: "%.1fms", v) }

    /// Left-justify `s` in a field of `width` (truncate if too long).
    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return String(s.prefix(width - 1)) + " " }
        return s + String(repeating: " ", count: width - s.count)
    }

    /// Right-justify `s` in a field of `width` (plus a trailing space separator).
    private static func lpad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s + " " }
        return String(repeating: " ", count: width - s.count) + s + " "
    }

    private static func row(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String,
                            header: Bool = false) -> String {
        "  " + pad(a, 30) + pad(b, 8) + pad(c, 13) + pad(d, 18) + pad(e, 12) + "\n"
    }

    private static func divider() -> String {
        "  " + String(repeating: "-", count: 80) + "\n"
    }
}
