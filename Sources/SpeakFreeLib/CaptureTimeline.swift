// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
// ai-suggestion:unverified · session:unknown · 2026-10-02
import Foundation

struct CapturePacket {
    let start: Double // Host-clock seconds, shared by both microphones.
    let samples: [Float] // Mono, 16 kHz.
    var end: Double { start + Double(samples.count) / 16_000 }
}

/// Joins two clocks without replaying overlapping speech. At handover, wait for
/// the slower microphone to reach the committed cursor; this delays delivery,
/// rather than cutting a hole in the recording. Built-in history covers fallback.
struct CaptureTimeline {
    private(set) var cursor: Double?
    private(set) var prefersSecondary = false
    private var fallback: [CapturePacket] = []
    /// Metadata for samples actually emitted, including discontinuities and clipped overlaps.
    /// No PCM is copied here. Adjacent spans merge; older spans expire with base history.
    private struct CommittedSpan {
        let start: Double
        var count: Int
        var end: Double { start + Double(count) / 16_000 }
    }
    private var committed: [CommittedSpan] = []
    /// While a take is recorded, built-in history back to this host time is kept (not just the
    /// last 3 s), so a headset found to be sending static can be replaced by what the Mac's own
    /// microphone heard over the same stretch (`rewind`). Capped at `maxHistorySeconds`.
    var keepFrom: Double?
    static let maxHistorySeconds: Double = 180
    /// Start of the oldest built-in packet still held.
    var oldestHeld: Double? { fallback.first?.start }

    /// Number of emitted samples at/after a host time. Unlike elapsed host time, this does
    /// not count holes in capture. A boundary inside a missing interval is unresolvable.
    func committedSamples(since time: Double) -> Int? {
        guard time.isFinite else { return nil }
        var suffix = 0
        for span in committed.reversed() {
            let tolerance = 0.5 / 16_000 + max(abs(time), abs(span.end), 1).ulp * 4
            if time < span.start - tolerance { suffix += span.count; continue }
            guard time <= span.end + tolerance else { return nil }
            let skipped = min(span.count, max(0, Int(((time - span.start) * 16_000).rounded())))
            return suffix + span.count - skipped
        }
        return nil
    }

    /// Validate the entire suffix `rewind` would emit without copying any samples. The two
    /// microphones may have different sample-grid origins, so the first/last boundary can
    /// round by half a sample. Internal base-packet gaps get only floating-point tolerance;
    /// granting a sample per packet would silently swallow real missing audio.
    func canRewind(to start: Double, preservingThrough end: Double) -> Bool {
        guard start.isFinite, end.isFinite, start <= end, let newest = fallback.last?.end else { return false }
        let halfSample = 0.5 / 16_000.0
        let precision = min(halfSample, max(abs(start), abs(end), abs(newest), 1).ulp * 4)
        // A trailing base stream is the common refusal: check it in constant time.
        guard newest + halfSample + precision >= end else { return false }
        var replayCursor = start
        var hasSamples = false
        var sampleCount = 0
        for packet in fallback {
            guard !packet.samples.isEmpty, packet.end > replayCursor else { continue }
            let allowance = hasSamples ? precision : halfSample + precision
            guard packet.start <= replayCursor + allowance else { return false }
            // Match commit's clipping, including an overlap shorter than half a sample.
            let skipped = min(packet.samples.count, max(0, Int(((replayCursor - packet.start) * 16_000).rounded())))
            guard skipped < packet.samples.count else { continue }
            sampleCount += packet.samples.count - skipped
            replayCursor = packet.end
            hasSamples = true
        }
        // One rounding disagreement is possible at the cross-microphone boundaries. Do
        // not grant that allowance repeatedly across overlapping base packets.
        let expected = max(0, Int(((replayCursor - start) * 16_000).rounded()))
        return hasSamples && replayCursor + halfSample + precision >= end
            && abs(sampleCount - expected) <= 1
    }

    mutating func receiveBase(_ packet: CapturePacket) -> [Float] {
        fallback.append(packet)
        let cutoff = max(min(packet.end - 3, keepFrom ?? .infinity), packet.end - Self.maxHistorySeconds)
        fallback.removeAll { $0.end < cutoff }
        return prefersSecondary ? [] : commit(packet)
    }

    /// Go back to host time `time` and return the built-in audio from there on. Samples
    /// already delivered after `time` are the caller's to discard.
    mutating func rewind(to time: Double) -> [Float] {
        prefersSecondary = false
        // The caller discards the same emitted suffix. Keep the earlier mapping, so a
        // later headset in this take cannot reach backward through the replacement.
        while let last = committed.last, last.end > time {
            if last.start >= time { committed.removeLast(); continue }
            let kept = min(last.count, max(0, Int(((time - last.start) * 16_000).rounded())))
            if kept == 0 { committed.removeLast() }
            else { committed[committed.count - 1].count = kept }
            break
        }
        cursor = time
        return drainFallback(until: .infinity)
    }

    mutating func receiveSecondary(_ packet: CapturePacket) -> [Float] {
        prefersSecondary = true
        var result: [Float] = []
        if let cursor {
            // A whole missing frame can contain speech. Ignore only clock arithmetic
            // noise here; the fallback drain already clips to available whole samples.
            let precision = max(abs(cursor), abs(packet.start), 1).ulp * 4
            if packet.start > cursor + precision { result += drainFallback(until: packet.start) }
        }
        result += commit(packet)
        return result
    }

    mutating func useBase() -> [Float] {
        prefersSecondary = false
        return drainFallback(until: .infinity)
    }

    /// Close a take with the newest available built-in tail when Bluetooth audio
    /// is still in transit. Future secondary packets are clipped at the same cursor.
    mutating func flush() -> [Float] { drainFallback(until: .infinity) }

    mutating func reset() { cursor = nil; fallback = []; committed = []; prefersSecondary = false }

    private mutating func drainFallback(until end: Double) -> [Float] {
        var result: [Float] = []
        for packet in fallback {
            guard packet.start < end else { break }
            // Already delivered: skip without copying (a take can hold 180 s of history).
            if let cursor, packet.end <= cursor { continue }
            let limit = min(end, packet.end)
            let frames = (limit - packet.start) * 16_000
            // Subtracting nonzero host times can put an exact frame boundary just
            // below its integer. Snap only that arithmetic noise; a genuinely
            // partial frame must still be excluded from this prefix.
            let precision = min(0.5, max(abs(limit), abs(packet.start), 1).ulp * 4 * 16_000)
            let nearest = frames.rounded()
            let wholeFrames = abs(frames - nearest) <= precision ? nearest : frames.rounded(.down)
            let count = min(packet.samples.count, max(0, Int(wholeFrames.clampedToSampleCount)))
            result += commit(CapturePacket(start: packet.start, samples: Array(packet.samples.prefix(count))))
        }
        return result
    }

    private mutating func commit(_ packet: CapturePacket) -> [Float] {
        guard !packet.samples.isEmpty else { return [] }
        let skipped = cursor.map { min(packet.samples.count, max(0, Int((($0 - packet.start) * 16_000).rounded()))) } ?? 0
        guard skipped < packet.samples.count else { return [] }
        let span = CommittedSpan(start: packet.start + Double(skipped) / 16_000,
                                 count: packet.samples.count - skipped)
        if let last = committed.last,
           abs(last.end - span.start) <= max(abs(last.end), abs(span.start), 1).ulp * 4 {
            committed[committed.count - 1].count += span.count
        } else {
            committed.append(span)
        }
        committed.removeAll { $0.end < packet.end - Self.maxHistorySeconds }
        cursor = packet.end
        return Array(packet.samples.dropFirst(skipped))
    }
}

private extension Double {
    var clampedToSampleCount: Double { min(Double(Int32.max), max(0, self)) }
}

/// Detect a mislabeled native stream before it can become slow/static speech.
/// Uses capture timestamps, never callback-arrival timing (which includes jitter).
struct CaptureClockGuard {
    private var previous: (time: Double, duration: Double)?
    private var consistent = 0
    static func continuityTolerance(duration: Double) -> Double { max(0.003, duration * 0.15) }
    mutating func accept(start: Double, frames: Int, rate: Double) -> Bool {
        guard start.isFinite, rate.isFinite, rate > 0, frames > 0 else { consistent = 0; return false }
        let duration = Double(frames) / rate
        defer { previous = (start, duration) }
        guard let previous else { return false }
        let elapsed = start - previous.time
        guard elapsed > 0, abs(elapsed - previous.duration) <= Self.continuityTolerance(duration: previous.duration) else {
            consistent = 0
            return false
        }
        consistent += 1
        return consistent >= 2
    }
}
