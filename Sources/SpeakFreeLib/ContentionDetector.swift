// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import Foundation

/// Detects the multi-device AirPods fight (Michael, 2026-07-14: two extra Macs running
/// speakfree + an iPhone all contend for the AirPods mic, and the link degrades in
/// bursts). The app can't see the other devices, but it can see the symptoms: route
/// changes, engine rebuilds, and buffer stalls while the input is Bluetooth. Enough of
/// those in a short window → tell the user what's likely happening, once.
///
/// Pure value type — callers feed events and timestamps; no clocks or IO inside.
public struct ContentionDetector {

    public var windowSeconds: TimeInterval = 30 * 60
    public var threshold = 3
    /// Minimum spacing between notifications — the fight can rage for hours and one
    /// hint is worth more than twenty.
    public var notifyCooldown: TimeInterval = 60 * 60

    private(set) var events: [Date] = []
    private(set) var lastNotified: Date?

    public init() {}

    /// Record a disruption event (route change / engine rebuild / buffer stall) that
    /// happened while the capture device was Bluetooth. Returns true when the caller
    /// should surface the contention notice now.
    public mutating func recordDisruption(at now: Date) -> Bool {
        events.append(now)
        events.removeAll { now.timeIntervalSince($0) > windowSeconds }
        guard events.count >= threshold else { return false }
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
