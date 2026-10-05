// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-25
import Foundation

/// Tells a microphone that hears the person from one that only delivers static.
///
/// In one observed session, Stay on held AirPods open for 36 minutes while they
/// delivered a noise-like stream (no energy below about 500 Hz, about 5,000 zero crossings a
/// second, level flat between 0.013 and 0.035 RMS). Parakeet returned nothing, and the Whisper
/// rescue invented fluent sentences that were never spoken. Good dictation, on any
/// microphone, is the opposite: most energy under 1 kHz, about 500 to 1,500 crossings a second,
/// and a level that rises and falls with words.
///
/// Thresholds were set on the recordings folder (2026-09-25): over whole takes they flag all
/// four bad AirPods takes of that evening and none of 5,759 other takes (1,760 of them AirPods).
/// A short stretch is not enough on its own: AirPods can hiss for a few seconds when they start
/// or between sentences. So inside a take, a headset is only judged broken when the Mac's own
/// microphone heard speech over the same seconds (`isSpeech`).
struct CaptureWindowStats: Equatable {
    /// Seconds on the shared host clock at the window's start.
    var start: Double
    var rms: Float
    /// Share of the window's energy below 1 kHz (0...1).
    var lowFraction: Float
    var crossingsPerSecond: Float
}

enum CaptureStaticJudge {
    static let windowSamples = 1_600 // 100 ms at 16 kHz
    /// Windows below this level are treated as quiet (no judgment on their shape).
    static let loudRMS: Float = 0.008
    /// Static fills the stretch: at least this share of windows are loud.
    static let staticLoudShare: Float = 0.8
    /// Static keeps little energy under 1 kHz; speech keeps most of it there.
    static let staticMaxLowFraction: Float = 0.4
    static let staticMinCrossings: Float = 4_000
    /// Static is flat: the 90th-percentile level is under this multiple of the 10th.
    static let staticMaxDynamicRange: Float = 4
    /// Inside a take, the stretch judged: two seconds.
    static let minimumWindows = 20
    /// A whole take can be judged from one second (a 2.2 s static take was typed on
    /// 2026-09-25). On the recordings folder this flags one of 7,769 other takes: a 1.1 s
    /// AirPods take that transcribed to nothing.
    static let wholeTakeMinimumWindows = 10

    /// True when the windows look like static rather than a voice.
    static func isStatic(_ windows: [CaptureWindowStats], minimumWindows: Int = minimumWindows) -> Bool {
        guard windows.count >= max(1, minimumWindows) else { return false }
        let loud = windows.filter { $0.rms >= loudRMS }
        guard Float(loud.count) >= staticLoudShare * Float(windows.count) else { return false }
        let energy = loud.reduce(Float(0)) { $0 + $1.rms * $1.rms }
        guard energy > 0 else { return false }
        let low = loud.reduce(Float(0)) { $0 + $1.rms * $1.rms * $1.lowFraction } / energy
        guard low < staticMaxLowFraction else { return false }
        guard median(loud.map(\.crossingsPerSecond)) > staticMinCrossings else { return false }
        let levels = windows.map(\.rms).sorted()
        let p10 = max(levels[Int(Double(levels.count - 1) * 0.1)], 1e-6)
        let p90 = levels[Int(Double(levels.count - 1) * 0.9)]
        return p90 / p10 < staticMaxDynamicRange
    }

    /// Voice on the fallback microphone: enough windows that stand well above its own quiet
    /// level and carry the low-frequency, low-crossing shape of speech. `floorRMS` is that
    /// microphone's quiet level (see `quietLevel`).
    static let speechMinWindows = 4
    static let speechOverFloor: Float = 2.5
    static let speechMinRMS: Float = 0.004
    static let speechMinLowFraction: Float = 0.6
    static let speechMaxCrossings: Float = 2_500

    static func isSpeech(_ windows: [CaptureWindowStats], floorRMS: Float) -> Bool {
        let threshold = max(speechMinRMS, floorRMS * speechOverFloor)
        return windows.filter {
            $0.rms >= threshold && $0.lowFraction >= speechMinLowFraction && $0.crossingsPerSecond < speechMaxCrossings
        }.count >= speechMinWindows
    }

    /// The 10th-percentile window level: the room between words.
    static func quietLevel(_ windows: [CaptureWindowStats]) -> Float {
        guard !windows.isEmpty else { return 0 }
        let levels = windows.map(\.rms).sorted()
        return levels[Int(Double(levels.count - 1) * 0.1)]
    }

    /// Whole-take judgment from 16 kHz samples.
    static func isStatic(samples: [Float]) -> Bool {
        isStatic(windows(of: samples), minimumWindows: wholeTakeMinimumWindows)
    }

    static func windows(of samples: [Float]) -> [CaptureWindowStats] {
        var meter = CaptureWindowMeter()
        return meter.add(samples, start: 0)
    }

    /// Short description for the log: "low-band 0.18, 5800 crossings/s, 5.1 s".
    static func describe(_ windows: [CaptureWindowStats]) -> String {
        let loud = windows.filter { $0.rms >= loudRMS }
        let energy = loud.reduce(Float(0)) { $0 + $1.rms * $1.rms }
        let low = energy > 0 ? loud.reduce(Float(0)) { $0 + $1.rms * $1.rms * $1.lowFraction } / energy : 0
        return String(format: "low-band %.2f, %.0f crossings/s, %.1f s", low,
                      loud.isEmpty ? 0 : median(loud.map(\.crossingsPerSecond)),
                      Double(windows.count * windowSamples) / 16_000)
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Cuts a 16 kHz stream into 100 ms windows. The 1 kHz low-pass (2nd-order Butterworth) keeps
/// its state across packets, so window shape does not depend on packet size.
struct CaptureWindowMeter {
    private var pending: [Float] = []
    private var pendingLow: [Float] = []
    private var pendingStart: Double?
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private static let b0: Float = 0.029954582, b1: Float = 0.059909164, b2: Float = 0.029954582
    private static let a1: Float = -1.454243586, a2: Float = 0.574061915

    /// Adds samples that start at host time `start`; returns the windows completed.
    mutating func add(_ samples: [Float], start: Double) -> [CaptureWindowStats] {
        if pending.isEmpty { pendingStart = start }
        var out: [CaptureWindowStats] = []
        for (index, raw) in samples.enumerated() {
            let x = raw.isFinite ? raw : 0
            let y = Self.b0 * x + Self.b1 * x1 + Self.b2 * x2 - Self.a1 * y1 - Self.a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            if pending.isEmpty { pendingStart = start + Double(index) / 16_000 }
            pending.append(x); pendingLow.append(y)
            if pending.count == CaptureStaticJudge.windowSamples {
                out.append(Self.stats(pending, low: pendingLow, start: pendingStart ?? start))
                pending.removeAll(keepingCapacity: true); pendingLow.removeAll(keepingCapacity: true)
            }
        }
        return out
    }

    mutating func reset() { self = CaptureWindowMeter() }

    private static func stats(_ x: [Float], low: [Float], start: Double) -> CaptureWindowStats {
        var energy: Float = 0, lowEnergy: Float = 0, crossings = 0
        for i in 0..<x.count {
            energy += x[i] * x[i]; lowEnergy += low[i] * low[i]
            if i > 0, x[i].sign != x[i - 1].sign || (x[i] == 0) != (x[i - 1] == 0) { crossings += 1 }
        }
        let n = Float(x.count)
        let meanEnergy = energy / n
        return CaptureWindowStats(
            start: start, rms: meanEnergy.squareRoot(),
            lowFraction: energy > 0 ? min(1, lowEnergy / energy) : 1,
            crossingsPerSecond: Float(crossings) / Float(x.count - 1) * 16_000)
    }
}
