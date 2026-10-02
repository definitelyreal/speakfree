// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22

import Foundation

/// What the adaptive post-release wait decided for one take (2026-09-22 speed loop).
/// Recorded so field logs show how long each dictation waited after key release and why,
/// which the 1.2 s speech extension made the dominant latency cost.
public struct PostBufferOutcome: Equatable, Sendable {
    /// Wall time the post-release wait actually took, in milliseconds.
    public var waitedMs: Double
    /// True when a trailing window reached the speech threshold, raising the cap to the
    /// extended value.
    public var extended: Bool
    /// Loudest trailing window seen after key release (RMS).
    public var maxTrailingRMS: Float
    /// Index into the take's samples at key release, so the tail can be replayed offline.
    public var releaseSample: Int

    public init(waitedMs: Double, extended: Bool, maxTrailingRMS: Float, releaseSample: Int) {
        self.waitedMs = waitedMs
        self.extended = extended
        self.maxTrailingRMS = maxTrailingRMS
        self.releaseSample = releaseSample
    }

    /// Summarize the trailing audio the live loop saw when it stopped waiting.
    public static func summarize(
        trailingSamples: [Float], waitedMs: Double, releaseSample: Int,
        windowMs: Double = PostBufferPolicy.defaultWindowMs,
        speechThreshold: Float = PostBufferPolicy.defaultSpeechThreshold
    ) -> PostBufferOutcome {
        let windowSamples = max(1, Int((windowMs / 1000.0 * 16_000.0).rounded()))
        let rms = PostBufferPolicy.windowRMSValues(samples: trailingSamples, windowSamples: windowSamples)
        let maxRMS = rms.max() ?? 0
        return PostBufferOutcome(
            waitedMs: waitedMs, extended: rms.contains(where: { $0 >= speechThreshold }),
            maxTrailingRMS: maxRMS, releaseSample: releaseSample)
    }
}

/// Stage timestamps for one dictation, from key release to insertion submission.
/// Submission does not prove that an inaccessible destination displayed the text. All marks are
/// `CFAbsoluteTimeGetCurrent()` values; a missing mark means that stage never ran. Pure value
/// type so the formatting is unit-tested and the app only has to stamp times.
public struct TakeLatency: Equatable, Sendable {
    public let keyRelease: Double
    public var postBuffer: PostBufferOutcome?
    /// Post-release wait finished and finalize began.
    public var finalizeStart: Double?
    /// Recording closed and the too-short/silent gate passed.
    public var gateEnd: Double?
    /// Engine call started / returned (includes any cold load, retries and rescue).
    public var inferStart: Double?
    public var inferEnd: Double?
    /// True when the model was not in memory when inference was requested.
    public var coldLoad: Bool = false
    /// True when a background preload was already running from key press.
    public var preloadStartedAtPress: Bool = false
    /// Model instance that ran the take (Parakeet "ane" or "cpu-standin" during a first-start
    /// compile; otherwise the engine ID). Nil when no engine pass ran.
    public var path: String?
    /// Seconds of `infer` spent waiting for a model load rather than inferring.
    public var modelWait: Double?
    /// QoS class the key-release path ran at.
    public var qos: String?
    /// Text pipeline done / sidecars written (only when that precedes insertion) / insertion submitted.
    public var pipelineEnd: Double?
    public var persistEnd: Double?
    public var insertEnd: Double?

    public init(keyRelease: Double) {
        self.keyRelease = keyRelease
    }

    private static func span(_ a: Double?, _ b: Double?) -> String {
        guard let a, let b else { return "na" }
        return String(format: "%.3f", max(0, b - a))
    }

    /// One greppable line. Field names are stable; `scripts/latency-report.py` parses them.
    /// Durations are seconds. Contains no transcript content.
    public func logLine(chars: Int, audioSeconds: Double, engine: String) -> String {
        let end = insertEnd ?? persistEnd ?? pipelineEnd
        var parts: [String] = []
        parts.append("total=" + Self.span(keyRelease, end))
        parts.append("wait=" + Self.span(keyRelease, finalizeStart))
        parts.append("stop=" + Self.span(finalizeStart, gateEnd))
        parts.append("queue=" + Self.span(gateEnd, inferStart))
        parts.append("infer=" + Self.span(inferStart, inferEnd))
        parts.append("text=" + Self.span(inferEnd, pipelineEnd))
        parts.append("save=" + Self.span(pipelineEnd, persistEnd))
        // Sidecars are written after insertion for normal takes (persistEnd nil): insertion
        // then starts when the text pipeline finishes.
        parts.append("insert=" + Self.span(persistEnd ?? pipelineEnd, insertEnd))
        parts.append("ext=" + ((postBuffer?.extended ?? false) ? "yes" : "no"))
        parts.append(String(format: "tailRMS=%.4f", postBuffer?.maxTrailingRMS ?? 0))
        parts.append("cold=" + (coldLoad ? "yes" : "no"))
        parts.append("preload=" + (preloadStartedAtPress ? "yes" : "no"))
        parts.append(String(format: "audio=%.2f", audioSeconds))
        parts.append("chars=\(chars)")
        parts.append("engine=\(engine)")
        // First-start fields (2026-09-24), appended only when known so older consumers and
        // lines keep their shape.
        if let path { parts.append("path=\(path)") }
        if let modelWait { parts.append(String(format: "modelWait=%.3f", modelWait)) }
        if let qos { parts.append("qos=\(qos)") }
        return "Latency: " + parts.joined(separator: " ")
    }
}
