// Crash-safe wav writing + orphan recovery (2026-07-25). The load-bearing contracts:
//   * a WavWriter file is READABLE (correct sizes) after every ~5s header patch, even
//     if the process dies without close() — the AVAudioFile total-loss failure mode;
//   * repairHeader fixes the zero-header crash signature and reports real duration;
//   * sweepRecoverableOrphans finds wavs-without-sidecars and repairs them in passing.

import XCTest
import AVFoundation
@testable import SpeakFreeLib

final class WavWriterTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func sine(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { sinf(Float($0) * 0.05) * 0.5 }
    }

    func test_closedFile_roundTrips() throws {
        let url = dir.appendingPathComponent("clean.wav")
        let w = try WavWriter(url: url)
        try w.append(sine(1.5))
        w.close()
        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(f.length), 1.5 * 16_000, accuracy: 2)
        XCTAssertEqual(f.processingFormat.sampleRate, 16_000)
    }

    /// THE crash contract: drop the writer without close() (process death). Because the
    /// header is patched every ~5s, a 12s recording must read back at least 5s — never 0.
    func test_unclosedFile_readsAtLeastLastPatch() throws {
        let url = dir.appendingPathComponent("killed.wav")
        var w: WavWriter? = try WavWriter(url: url)
        // Append in ~1s chunks so patches (every 80k samples) trigger along the way.
        for _ in 0..<12 { try w?.append(sine(1.0)) }
        w = nil  // deinit closes the handle WITHOUT the final explicit patch-on-close…
        // …but ≥2 periodic patches (at 5s and 10s) already landed. Simulate the worst
        // case anyway: whatever the header says now must be ≥ 10s and readable.
        let f = try AVAudioFile(forReading: url)
        XCTAssertGreaterThanOrEqual(Double(f.length) / 16_000, 10.0 - 0.01,
            "periodic header patches must make a killed recording readable to the last patch")
    }

    /// The historic failure shape: full PCM on disk, header claiming zero. repairHeader
    /// must fix sizes and report the true duration; the file must then read fully.
    func test_repairHeader_fixesZeroHeader() throws {
        let url = dir.appendingPathComponent("orphan.wav")
        let w = try WavWriter(url: url)
        try w.append(sine(3.0))
        w.close()
        // Corrupt: zero the DATA chunk size only (offset 40) — the real crash signature.
        // (RIFF size stays valid; zeroing it too makes CoreAudio refuse to open at all.)
        let h = FileHandle(forUpdatingAtPath: url.path)!
        try h.seek(toOffset: 40); try h.write(contentsOf: Data([0, 0, 0, 0]))
        try h.close()
        let broken = try AVAudioFile(forReading: url)
        XCTAssertEqual(broken.length, 0, "precondition: corrupted header reads as empty")

        let repaired = WavWriter.repairHeader(at: url)
        XCTAssertNotNil(repaired)
        XCTAssertEqual(repaired!, 3.0, accuracy: 0.01)
        let fixed = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(fixed.length), 3.0 * 16_000, accuracy: 2)
    }

    func test_repairHeader_leavesHealthyFileAlone() throws {
        let url = dir.appendingPathComponent("healthy.wav")
        let w = try WavWriter(url: url)
        try w.append(sine(2.0))
        w.close()
        XCTAssertNil(WavWriter.repairHeader(at: url), "healthy header needs no repair")
    }

    func test_sweep_findsRepairsAndFiltersOrphans() throws {
        let cfgDir = dir.appendingPathComponent("cfg")
        Config.configDirOverride = cfgDir
        defer { Config.configDirOverride = nil }
        RecordingStore.ensureDirectory()
        let rec = RecordingStore.recordingsDir

        // 1: orphan with corrupted header (recoverable) — must be found AND repaired.
        let orphan = rec.appendingPathComponent("recording-2026-07-25-120000-AAAAAAAA.wav")
        let w1 = try WavWriter(url: orphan); try w1.append(sine(4.0)); w1.close()
        let h = FileHandle(forUpdatingAtPath: orphan.path)!
        try h.seek(toOffset: 40); try h.write(contentsOf: Data([0, 0, 0, 0]))
        try h.close()

        // 2: wav WITH a sidecar — already transcribed, never swept.
        let done = rec.appendingPathComponent("recording-2026-07-25-120100-BBBBBBBB.wav")
        let w2 = try WavWriter(url: done); try w2.append(sine(4.0)); w2.close()
        RecordingStore.saveTranscription(text: "done", for: done)

        // 3: too-short orphan — filtered by minSeconds.
        let stub = rec.appendingPathComponent("recording-2026-07-25-120200-CCCCCCCC.wav")
        let w3 = try WavWriter(url: stub); try w3.append(sine(0.5)); w3.close()

        // The sweep skips files quiet for <120s (live-capture guard) — backdate the
        // fixtures so they read as settled orphans, not in-flight recordings.
        let past = Date().addingTimeInterval(-300)
        for f in [orphan, done, stub] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: f.path)
        }

        let found = RecordingStore.sweepRecoverableOrphans(minSeconds: 3.0)
        XCTAssertEqual(found.map(\.url.lastPathComponent), [orphan.lastPathComponent])
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.seconds, 4.0, accuracy: 0.05)
        // And the repair stuck: the orphan now reads fully without further help.
        let f = try AVAudioFile(forReading: orphan)
        XCTAssertEqual(Double(f.length), 4.0 * 16_000, accuracy: 2)
    }
}
