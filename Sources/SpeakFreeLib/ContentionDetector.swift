// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
// Retuned 2026-07-21: storm signature, not a slow trickle (pocket-cycle false positive).
import Foundation

/// Detects the multi-device AirPods fight (Michael, 2026-07-14: two extra Macs running
/// speakfree + an iPhone all contend for the AirPods mic, and the link degrades in
/// bursts). The app can't see the other devices, but it can see the symptoms: route
/// changes, engine rebuilds, and buffer stalls while the input is Bluetooth. The real
/// fight is a STORM — the 2026-07-16 log shows 44 rebuild cycles in ~100 s. Deliberate
/// use (AirPods in and out of a pocket, 2026-07-21 false positive) produces 2–4 events
/// that go quiet again, so the detector only fires on a chain of rapid events: each
/// within `chainGapSeconds` of the last, `threshold` deep.
///
/// Pure value type — callers feed events and timestamps; no clocks or IO inside.
public struct ContentionDetector {

    /// Events further apart than this break the chain — a fight delivers events every
    /// few seconds; a pocket cycle is a short burst followed by minutes of silence.
    public var chainGapSeconds: TimeInterval = 90
    /// Chain length that means a genuine fight. One physical connect/disconnect emits
    /// ~2 events (default-input change + a pre-record health rebuild), so 8 chained
    /// events is several back-to-back cycles — or ~20 s into a real storm.
    public var threshold = 8
    /// Minimum spacing between notifications — the fight can rage for hours and one
    /// hint is worth more than twenty.
    public var notifyCooldown: TimeInterval = 60 * 60

    private(set) var chainCount = 0
    private(set) var lastEvent: Date?
    private(set) var lastNotified: Date?

    public init() {}

    /// Record a disruption event (route change / engine rebuild / buffer stall) that
    /// happened while the capture device was Bluetooth. Returns true when the caller
    /// should surface the contention notice now.
    public mutating func recordDisruption(at now: Date) -> Bool {
        // A negative interval (wall clock stepped backwards) must reset, not chain.
        if let last = lastEvent, case let dt = now.timeIntervalSince(last),
           dt >= 0, dt <= chainGapSeconds {
            chainCount += 1
        } else {
            chainCount = 1
        }
        lastEvent = now
        guard chainCount >= threshold else { return false }
        if let last = lastNotified, now.timeIntervalSince(last) < notifyCooldown { return false }
        lastNotified = now
        return true
    }

    public static let noticeText = "Your AirPods keep switching away from this Mac — "
        + "another device (iPhone, iPad, or a second Mac) is likely competing for their "
        + "microphone. Dictation quality suffers during these fights. Fix: pick the "
        + "MacBook microphone in the speakfree menu, or disable \"Automatically switch\" "
        + "for your AirPods on the other devices."
}
