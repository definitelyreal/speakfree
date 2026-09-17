// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
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

    mutating func receiveBase(_ packet: CapturePacket) -> [Float] {
        fallback.append(packet)
        fallback.removeAll { $0.end < packet.end - 3 }
        return prefersSecondary ? [] : commit(packet)
    }

    mutating func receiveSecondary(_ packet: CapturePacket) -> [Float] {
        prefersSecondary = true
        var result: [Float] = []
        if let cursor, packet.start > cursor + 1.0 / 16_000 {
            result += drainFallback(until: packet.start)
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

    mutating func reset() { cursor = nil; fallback = []; prefersSecondary = false }

    private mutating func drainFallback(until end: Double) -> [Float] {
        var result: [Float] = []
        for packet in fallback {
            guard packet.start < end else { break }
            let count = min(packet.samples.count, max(0, Int(((end - packet.start) * 16_000).rounded(.down).clampedToSampleCount)))
            result += commit(CapturePacket(start: packet.start, samples: Array(packet.samples.prefix(count))))
        }
        return result
    }

    private mutating func commit(_ packet: CapturePacket) -> [Float] {
        guard !packet.samples.isEmpty else { return [] }
        let skipped = cursor.map { min(packet.samples.count, max(0, Int((($0 - packet.start) * 16_000).rounded()))) } ?? 0
        guard skipped < packet.samples.count else { return [] }
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
    mutating func accept(start: Double, frames: Int, rate: Double) -> Bool {
        guard start.isFinite, rate.isFinite, rate > 0, frames > 0 else { consistent = 0; return false }
        let duration = Double(frames) / rate
        defer { previous = (start, duration) }
        guard let previous else { return false }
        let elapsed = start - previous.time
        guard elapsed > 0, abs(elapsed - previous.duration) <= max(0.003, previous.duration * 0.15) else {
            consistent = 0
            return false
        }
        consistent += 1
        return consistent >= 2
    }
}
