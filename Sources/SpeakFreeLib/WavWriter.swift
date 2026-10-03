// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-processed:unverified · session:unknown/agent:audio_file_integrity · 2026-10-02
import Foundation
import Darwin
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
    /// Instance-scoped injection at real I/O boundaries; production uses no hook.
    enum IOOperation { case append, truncate, patchRIFF, patchData, seekEnd, synchronize, close }
    private let beforeIO: (IOOperation) throws -> Void
    private var closed = false
    private var firstFailure: Error?
    private let handle: FileHandle
    private let activityLease: RecordingActivity.Lease
    let url: URL
    private var samplesWritten: Int = 0
    private var samplesAtLastPatch: Int = 0
    /// Patch the header every ~5 s of audio (16 kHz).
    private let headerPatchInterval = 80_000

    init(url: URL, beforeIO: @escaping (IOOperation) throws -> Void = { _ in }) throws {
        self.beforeIO = beforeIO
        self.url = url
        // Register before the file becomes visible to a maintenance snapshot.
        activityLease = try RecordingActivity.shared.acquire(url)
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
        let data = Self.pcmData(samples)
        do {
            try beforeIO(.append)
            try handle.write(contentsOf: data)
            samplesWritten += samples.count
            if samplesWritten - samplesAtLastPatch >= headerPatchInterval {
                // Restore end positioning on failure so legacy callers cannot overwrite
                // the header with a later append. Live recording stops disk writes.
                try patchHeader()
            }
        } catch {
            firstFailure = firstFailure ?? error
            try? handle.seekToEnd()
            throw error
        }
    }

    /// Allocate once and fill in place. Appending a separate two-byte slice for every
    /// sample spent most of the write queue's CPU in Data's append machinery.
    static func pcmData(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (index, sample) in samples.enumerated() {
                // A malformed device buffer should produce silence, never an invalid
                // Float-to-Int conversion or full-scale noise in the recovery archive.
                let clamped = sample.isFinite ? max(-1.0, min(1.0, sample)) : 0
                let value = Int16((clamped * 32767.0).rounded()).littleEndian
                bytes.storeBytes(of: value, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return data
    }

    /// Rewrite the RIFF + data chunk sizes to match what's on disk, then return to the end.
    private func patchHeader() throws {
        let dataBytes = UInt32(samplesWritten * 2)
        try handle.seek(toOffset: 4)
        try beforeIO(.patchRIFF)
        try handle.write(contentsOf: WavWriter.le32(36 + dataBytes))
        try handle.seek(toOffset: 40)
        try beforeIO(.patchData)
        try handle.write(contentsOf: WavWriter.le32(dataBytes))
        try beforeIO(.seekEnd)
        try handle.seekToEnd()
        samplesAtLastPatch = samplesWritten
    }

    /// Drop everything after the first `count` samples (a headset stretch being replaced by
    /// the built-in microphone's audio). The header is patched so the file stays valid.
    func truncate(toSamples count: Int) throws {
        let keep = min(max(0, count), samplesWritten)
        do {
            try beforeIO(.truncate)
            try handle.truncate(atOffset: UInt64(44 + keep * 2))
            samplesWritten = keep
            samplesAtLastPatch = min(samplesAtLastPatch, keep)
            try patchHeader()
        } catch {
            firstFailure = firstFailure ?? error
            try? handle.seekToEnd()
            throw error
        }
    }

    /// Report every write/finalization failure, including failures earlier in the take.
    /// Even on error, attempt to close the handle before the archive is repaired.
    func finish(synchronize: Bool = false) throws {
        guard !closed else {
            if let firstFailure { throw firstFailure }
            return
        }
        defer { closed = true; activityLease.release() }
        do {
            try patchHeader()
            if synchronize {
                try beforeIO(.synchronize)
                try handle.synchronize()
            }
        } catch { firstFailure = firstFailure ?? error }
        do { try beforeIO(.close); try handle.close() }
        catch { firstFailure = firstFailure ?? error; try? handle.close() }
        if let firstFailure { throw firstFailure }
    }

    /// Best-effort close for legacy callers. Live recording uses throwing `finish()`.
    func close() { try? finish() }

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

    /// Compare the canonical header and expected file length without reading PCM samples.
    static func matchesHeader(_ url: URL, sampleCount: Int) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard sampleCount <= (Int(UInt32.max) - 36) / 2,
              try reader.seekToEnd() == UInt64(44 + sampleCount * 2) else { return false }
        try reader.seek(toOffset: 0)
        return try reader.read(upToCount: 44) == header(dataBytes: UInt32(sampleCount * 2))
    }

    /// Compare the complete canonical header and quantized PCM, including same-size corruption.
    static func matches(_ url: URL, samples: [Float]) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard samples.count <= (Int(UInt32.max) - 36) / 2,
              try reader.seekToEnd() == UInt64(44 + samples.count * 2) else { return false }
        try reader.seek(toOffset: 0)
        guard try reader.read(upToCount: 44) == header(dataBytes: UInt32(samples.count * 2)) else { return false }
        for start in stride(from: 0, to: samples.count, by: 16_000) {
            let pcm = pcmData(Array(samples[start..<min(start + 16_000, samples.count)]))
            guard try reader.read(upToCount: pcm.count) == pcm else { return false }
        }
        return true
    }

    /// Same-directory rename publishes a completely written, validated replacement atomically.
    /// The caller has already preserved the old file before this operation is admitted.
    static func installReplacement(_ replacement: URL, at original: URL) throws {
        guard rename(replacement.path, original.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - Orphan repair (recovery path)

    /// Repair a wav whose header claims fewer bytes than the file holds (the AVAudioFile
    /// crash signature, or a stale periodic patch). Walks the chunk list to find `data`,
    /// sets its size to the physical remainder, and fixes the RIFF size. Returns the
    /// repaired duration in seconds, or nil if the file isn't a parseable RIFF/WAVE or
    /// needs no repair.
    @discardableResult
    static func repairHeader(at url: URL) -> Double? {
        guard let activityLease = try? RecordingActivity.shared.acquireReading(url) else { return nil }
        defer { activityLease.release() }
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
