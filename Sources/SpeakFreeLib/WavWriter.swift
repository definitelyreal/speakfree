import Foundation
import AVFoundation

/// Crash-safe 16 kHz mono s16 WAV writer.
///
/// Replaces `AVAudioFile` on the RECORDING path because AVAudioFile commits the RIFF/data
/// chunk sizes only when the file is closed — a process killed mid-recording leaves every
/// byte of PCM on disk reading as a 0-sample file (2026-07-25 recovery audit: 94 such
/// orphans in the live corpus, one holding 37 minutes of audio). This writer:
///   * writes a plain 44-byte header up front,
///   * appends interleaved s16 samples,
///   * re-patches the header sizes on a cadence (`headerPatchInterval` samples ≈ 5 s),
///     so a SIGKILL at any moment loses at most that window plus unflushed page cache,
///   * patches once more on `close()`.
/// All calls must come from one queue (AudioRecorder's writeQueue) — the class is not
/// itself thread-safe, matching how the AVAudioFile it replaces was used.
final class WavWriter {
    private let handle: FileHandle
    let url: URL
    private var samplesWritten: Int = 0
    private var samplesAtLastPatch: Int = 0
    /// Patch the header every ~5 s of audio (16 kHz).
    private let headerPatchInterval = 80_000

    init(url: URL) throws {
        self.url = url
        // Owner-only before any audio lands in it (mirrors the previous AVAudioFile +
        // setAttributes sequence, without the world-readable window).
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        guard let h = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "WavWriter", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot open \(url.lastPathComponent) for writing"])
        }
        handle = h
        try handle.write(contentsOf: WavWriter.header(dataBytes: 0))
    }

    /// Append float samples in [-1, 1]; converted to interleaved s16.
    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            var v = Int16((clamped * 32767.0).rounded())
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        samplesWritten += samples.count
        if samplesWritten - samplesAtLastPatch >= headerPatchInterval {
            // A patch failure must not poison the stream: if it throws mid-seek, the
            // offset could sit in the header region and the NEXT append would write
            // PCM over it. Restore end-of-file positioning before continuing.
            do { try patchHeader() } catch { try? handle.seekToEnd() }
        }
    }

    /// Rewrite the RIFF + data chunk sizes to match what's on disk, then return to the end.
    private func patchHeader() throws {
        let dataBytes = UInt32(samplesWritten * 2)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: WavWriter.le32(36 + dataBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: WavWriter.le32(dataBytes))
        try handle.seekToEnd()
        samplesAtLastPatch = samplesWritten
    }

    /// Final header patch + close. Safe to call once; the deinit also closes defensively.
    func close() {
        try? patchHeader()
        try? handle.close()
    }

    deinit { try? handle.close() }

    // MARK: - Header bytes

    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }
    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func header(dataBytes: UInt32) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16))
        d.append(le16(1))                    // PCM
        d.append(le16(1))                    // mono
        d.append(le32(16_000))               // sample rate
        d.append(le32(16_000 * 2))           // byte rate
        d.append(le16(2))                    // block align
        d.append(le16(16))                   // bits per sample
        d.append(contentsOf: Array("data".utf8)); d.append(le32(dataBytes))
        return d
    }

    // MARK: - Orphan repair (recovery path)

    /// Repair a wav whose header claims fewer bytes than the file holds (the AVAudioFile
    /// crash signature, or a stale periodic patch). Walks the chunk list to find `data`,
    /// sets its size to the physical remainder, and fixes the RIFF size. Returns the
    /// repaired duration in seconds, or nil if the file isn't a parseable RIFF/WAVE or
    /// needs no repair.
    @discardableResult
    static func repairHeader(at url: URL) -> Double? {
        guard let h = FileHandle(forUpdatingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        guard let fileSize = try? h.seekToEnd(), fileSize > 44 else { return nil }
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 8192), head.count >= 44,
              head.prefix(4).elementsEqual(Array("RIFF".utf8)),
              head[8..<12].elementsEqual(Array("WAVE".utf8)) else { return nil }

        func u32(_ off: Int) -> UInt32 {
            head[off..<off+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        var off = 12
        var sampleRate = 16_000.0
        var bytesPerFrame = 2.0
        while off + 8 <= head.count {
            let id = head[off..<off+4]
            let size = Int(u32(off + 4))
            if id.elementsEqual(Array("fmt ".utf8)), off + 8 + 16 <= head.count {
                let rate = u32(off + 12)
                let blockAlign = head[(off+20)..<(off+22)].withUnsafeBytes {
                    $0.loadUnaligned(as: UInt16.self) }.littleEndian
                if rate > 0 { sampleRate = Double(rate) }
                if blockAlign > 0 { bytesPerFrame = Double(blockAlign) }
            }
            if id.elementsEqual(Array("data".utf8)) {
                let dataOffset = UInt64(off + 8)
                let physical = fileSize - dataOffset
                let claimed = UInt64(size)
                guard physical > claimed else { return nil }  // header already correct
                try? h.seek(toOffset: UInt64(off + 4))
                try? h.write(contentsOf: le32(UInt32(min(physical, UInt64(UInt32.max)))))
                try? h.seek(toOffset: 4)
                try? h.write(contentsOf: le32(UInt32(min(fileSize - 8, UInt64(UInt32.max)))))
                return Double(physical) / bytesPerFrame / sampleRate
            }
            off += 8 + size + (size & 1)
        }
        return nil
    }
}
