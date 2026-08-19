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

    // MARK: - Archive recovery from memory (2026-08-14)
    // The empty-recording bug: crash-safety streaming write skipped, wav left header-only while
    // the in-memory buffer held real audio. stopRecording rewrites from memory as a backstop.

    func test_recoverArchive_rewritesHeaderOnlyWavFromMemory() throws {
        let url = dir.appendingPathComponent("empty.wav")
        // Header-only: open + close with no append, exactly the observed 44-byte failure.
        let w = try WavWriter(url: url)
        w.close()
        let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThanOrEqual(before, 100, "precondition: header-only file")

        let samples = sine(2.0)   // 32000 samples of real audio
        AudioRecorder.recoverArchiveIfHeaderOnly(url: url, samples: samples)

        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(f.length), 2.0 * 16_000, accuracy: 4,
                       "wav must be rewritten to hold the in-memory audio")
    }

    func test_recoverArchive_leavesAValidRecordingUntouched() throws {
        let url = dir.appendingPathComponent("full.wav")
        let samples = sine(2.0)
        let w = try WavWriter(url: url)
        try w.append(samples)
        w.close()
        let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        AudioRecorder.recoverArchiveIfHeaderOnly(url: url, samples: samples)

        let after = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertEqual(after, before, "a valid, full recording must never be rewritten")
    }

    func test_recoverArchive_skipsSubSecondTaps() throws {
        let url = dir.appendingPathComponent("tap.wav")
        let w = try WavWriter(url: url)
        w.close()
        let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        AudioRecorder.recoverArchiveIfHeaderOnly(url: url, samples: sine(0.4))  // < 1s

        let after = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertEqual(after, before, "sub-second taps are not worth recovering and must be skipped")
    }


    /// Adversarial review F3/F7: a recording that lost only part of its audio (real PCM on disk,
    /// but short) must NOT be rewritten from memory — the guard is header-only, not "half size" —
    /// because a rewrite that failed mid-way (disk full) could otherwise destroy the partial audio.
    func test_recoverArchive_doesNotClobberPartiallyWrittenAudio() throws {
        let url = dir.appendingPathComponent("partial.wav")
        let w = try WavWriter(url: url)
        try w.append(sine(1.0))   // 16000 samples of REAL audio already on disk
        w.close()
        let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(before, 64, "precondition: real audio present, not header-only")

        // Memory claims a longer take, but the on-disk file holds real audio and must be left alone.
        AudioRecorder.recoverArchiveIfHeaderOnly(url: url, samples: sine(2.0))

        let after = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertEqual(after, before, "a partially-written recording must never be clobbered")
    }

}
