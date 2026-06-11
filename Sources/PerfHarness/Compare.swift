// Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626
//
// T2.0 — The regression gate.
//
// compare(candidate, baseline, requireBaseline:):
//   * If the candidate's fingerprint is NOT comparable to the baseline's:
//       - requireBaseline == false → PRINT a "no comparable baseline" note and PASS (exit 0).
//         (Local/dev use: a one-off compare on a machine with no matching baseline shouldn't
//          hard-fail.)
//       - requireBaseline == true  → FAIL (exit 1) with a "no comparable baseline" error.
//         (CI use: a fingerprint mismatch must NOT green-wash. AR-2 finding #3: with the skip
//          path always taken on the runner, a genuine +50% regression passed the gate. CI now
//          passes --require-baseline so a missing CI-fingerprint baseline FAILS loudly instead
//          of silently passing. Either a matching baseline exists and the gate enforces, or CI
//          is red until one is committed — the gate can never be a permanent no-op.)
//   * If comparable → for every (engine, fixture), compare candidate median vs baseline median
//     for BOTH inferenceMs and endToEndMs. Any metric exceeding +`thresholdPct`% is a regression.
//     One or more regressions → FAIL (exit 1) after printing every offending row.
//
// Locked threshold: +15% median (Michael, 2026-06-10).

import Foundation

enum GateResult {
    case pass(note: String)
    case regression(rows: [RegressionRow])
    /// No fingerprint-comparable baseline AND `requireBaseline` was set — a hard failure so CI
    /// can never silently pass on a non-matching baseline (AR-2 finding #3).
    case noComparableBaseline(note: String)
}

struct RegressionRow {
    let engine: String
    let fixture: String
    let metric: String       // "inference" | "endToEnd"
    let baselineMs: Double
    let candidateMs: Double
    var deltaPct: Double { (candidateMs - baselineMs) / baselineMs * 100.0 }
}

enum Compare {

    static let defaultThresholdPct: Double = 15.0

    static func gate(candidate: PerfReport, baseline: PerfReport,
                     thresholdPct: Double = defaultThresholdPct,
                     requireBaseline: Bool = false) -> GateResult {
        guard candidate.fingerprint.isComparable(to: baseline.fingerprint) else {
            let verb = requireBaseline ? "gate FAILS — required baseline missing" : "gate skipped, PASS"
            let note = """
            no comparable baseline — fingerprint mismatch (\(verb)):
              candidate: \(candidate.fingerprint.matchKey)
              baseline:  \(baseline.fingerprint.matchKey)
            A baseline tagged with the candidate's fingerprint must be committed before the gate
            can fail on regressions for this machine (e.g. a CI runner generates + commits its own).
            """
            // AR-2 #3: with requireBaseline (CI), a non-matching baseline is a HARD FAILURE so the
            // +threshold gate can never become a permanent no-op that green-washes regressions.
            return requireBaseline ? .noComparableBaseline(note: note) : .pass(note: note)
        }

        // Index baseline medians by (engine, fixture).
        var baseInfer: [String: Double] = [:]
        var baseE2E: [String: Double] = [:]
        for eng in baseline.engines {
            for f in eng.fixtures {
                baseInfer[key(eng.engine, f.fixture)] = f.inferenceMs.median
                baseE2E[key(eng.engine, f.fixture)] = f.endToEndMs.median
            }
        }

        var rows: [RegressionRow] = []
        for eng in candidate.engines {
            for f in eng.fixtures {
                let k = key(eng.engine, f.fixture)
                if let b = baseInfer[k], regressed(candidate: f.inferenceMs.median, baseline: b, thresholdPct) {
                    rows.append(RegressionRow(engine: eng.engine, fixture: f.fixture,
                        metric: "inference", baselineMs: b, candidateMs: f.inferenceMs.median))
                }
                if let b = baseE2E[k], regressed(candidate: f.endToEndMs.median, baseline: b, thresholdPct) {
                    rows.append(RegressionRow(engine: eng.engine, fixture: f.fixture,
                        metric: "endToEnd", baselineMs: b, candidateMs: f.endToEndMs.median))
                }
            }
        }

        if rows.isEmpty {
            return .pass(note: "all medians within +\(fmt(thresholdPct))% of the matching baseline")
        }
        return .regression(rows: rows)
    }

    private static func regressed(candidate: Double, baseline: Double, _ thresholdPct: Double) -> Bool {
        guard baseline > 0 else { return false }
        return (candidate - baseline) / baseline * 100.0 > thresholdPct
    }

    private static func key(_ engine: String, _ fixture: String) -> String { "\(engine)|\(fixture)" }
    private static func fmt(_ v: Double) -> String { String(format: "%.0f", v) }
}
