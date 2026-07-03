// Claude · 2026-07-03 · Session: 6f785b82-a72f-49de-99dc-89f3a51601e4
//
// Regression tests for ProgressNormalizer — the fix for the 2026-06-27 "download progress
// isn't showing / bar jumps backward" bug. FluidAudio re-emits a full 0→0.5→1.0 sweep per
// component spec, so forwarded verbatim the fraction sawtooths. The normalizer's contract:
// one monotonic, never-decreasing display fraction in [0, 1); only the caller pegs 1.0.

import XCTest
import FluidAudio
@testable import SpeakFreeLib

final class ProgressNormalizerTests: XCTestCase {

    private func download(_ fraction: Double) -> DownloadUtils.DownloadProgress {
        DownloadUtils.DownloadProgress(
            fractionCompleted: fraction,
            phase: .downloading(completedFiles: 0, totalFiles: 4))
    }

    private func compile() -> DownloadUtils.DownloadProgress {
        DownloadUtils.DownloadProgress(fractionCompleted: 1.0, phase: .compiling(modelName: "Encoder"))
    }

    /// The original bug: a per-spec sawtooth (…→0.5→1.0→0.5→…) must never move the bar backward.
    func testSawtoothInputYieldsMonotonicOutput() {
        let n = ProgressNormalizer()
        let sawtooth: [DownloadUtils.DownloadProgress] = [
            download(0.1), download(0.3), download(0.5),  // spec 1 bytes done
            compile(),                                     // spec 1 compile
            download(0.2),                                 // spec 2 restarts the sweep — the sawtooth
            download(0.4), compile(),
            download(0.05),                                // spec 3
            compile(), compile(),
        ]
        var last = -Double.infinity
        for p in sawtooth {
            let v = n.map(p)
            XCTAssertGreaterThanOrEqual(v, last, "display fraction went backward on \(p.phase)")
            XCTAssertLessThan(v, 1.0, "normalizer must never report 1.0 — the caller pegs completion")
            XCTAssertGreaterThanOrEqual(v, 0.0)
            last = v
        }
    }

    func testDownloadBandRescalesHalfToCeiling() {
        let n = ProgressNormalizer()
        // FluidAudio's byte fraction lives in [0, 0.5]; 0.5 maps to the 0.85 download ceiling.
        XCTAssertEqual(n.map(download(0.25)), 0.425, accuracy: 0.0001)
        XCTAssertEqual(n.map(download(0.5)), 0.85, accuracy: 0.0001)
    }

    func testCompileCreepsTowardTailCeilingWithoutReachingIt() {
        let n = ProgressNormalizer()
        _ = n.map(download(0.5))  // reach the download ceiling
        var last = 0.85
        for i in 0..<200 {
            let v = n.map(compile())
            // Strictly increasing early on; after enough steps the geometric creep reaches
            // its floating-point fixed point, so only non-decreasing is guaranteed.
            if i < 20 {
                XCTAssertGreaterThan(v, last)
            } else {
                XCTAssertGreaterThanOrEqual(v, last)
            }
            XCTAssertLessThan(v, 1.0)
            last = v
        }
        // 200 compile callbacks asymptote at the 0.99 tail ceiling, never past it.
        XCTAssertEqual(last, 0.99, accuracy: 0.001)
    }

    func testCompileBeforeAnyDownloadJumpsToDownloadCeiling() {
        // "Already on disk" path: compile callbacks can arrive with no download bytes seen.
        let n = ProgressNormalizer()
        let v = n.map(compile())
        XCTAssertGreaterThanOrEqual(v, 0.85)
        XCTAssertLessThan(v, 1.0)
    }

    func testNonFiniteAndOutOfRangeFractionsAreClamped() {
        let n = ProgressNormalizer()
        XCTAssertEqual(n.map(download(.nan)), 0.0)
        XCTAssertEqual(n.map(download(-1)), 0.0)
        // FluidAudio's "already on disk" 0.5+ spikes clamp to the ceiling, monotonically.
        XCTAssertEqual(n.map(download(7)), 0.85, accuracy: 0.0001)
        XCTAssertEqual(n.map(download(0.1)), 0.85, accuracy: 0.0001, "must hold the high-water mark")
    }
}
