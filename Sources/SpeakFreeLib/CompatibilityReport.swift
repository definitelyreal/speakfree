// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-24
//
// Opt-in, local-only compatibility report. When the user turns it on in Settings → Advanced,
// each insertion records WHICH app it went to, how that app was classified, which route ran,
// and whether the text was verified. It never records dictated text, its length, or anything
// read from the target field. It lives only in memory and leaves the Mac only if the user
// presses "Copy Report" and pastes it somewhere themselves.

import Foundation

/// How one insertion ended, as far as speakfree can tell.
public enum InsertionOutcome: String, Equatable {
    /// AX write, and the field's character count grew.
    case axVerified = "accessibility, verified"
    /// AX write reported success; the field could not be read back.
    case axUnverifiable = "accessibility, not verifiable"
    /// AX write reported success but the field did not grow, so speakfree pasted instead.
    case axDroppedThenPasted = "accessibility dropped, pasted instead"
    /// AX write timed out and may have landed; text left on the clipboard.
    case axTimeoutCopied = "accessibility timed out, copied"
    /// Synthetic Unicode key events.
    case typed = "typed"
    /// Clipboard paste with restore.
    case pasted = "pasted"
    /// System Events keystrokes to a remote viewer.
    case remoteTyped = "remote keystrokes sent"
    /// Clipboard plus System Events ⌘V to a remote viewer.
    case remotePasted = "remote paste sent"
    /// Refocus failed or focus moved; text left on the clipboard.
    case copiedFocusLost = "focus lost, copied"
    /// A remote or guarded delivery could not be confirmed; the user was shown the text.
    case deliveryFailed = "delivery failed, shown to user"
    /// Secure Input was on; text left on the concealed clipboard.
    case secureInput = "secure input, copied"
}

/// One insertion, with no text content.
public struct CompatibilityEvent: Equatable {
    public let date: Date
    public let bundleID: String
    public let appName: String?
    public let appVersion: String?
    public let appClass: AppClass
    public let reason: String
    public let override: InsertionMethod
    public let outcome: InsertionOutcome
    public let multiLine: Bool
}

public final class CompatibilityReport {
    public static let shared = CompatibilityReport()

    /// Most recent events kept. Old ones fall off; nothing is written to disk.
    public static let capacity = 200

    private let lock = NSLock()
    private var events: [CompatibilityEvent] = []
    private var enabled = false

    public init() {}

    /// Turning the report off discards everything recorded so far.
    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set {
            lock.lock()
            enabled = newValue
            if !newValue { events.removeAll() }
            lock.unlock()
        }
    }

    /// Called with every event while set, even when the stored report is off. Only the Report
    /// a Problem window sets it, for as long as it is open, to show "last result in this app".
    /// Events carry no text, and the listener keeps nothing beyond the newest one.
    private var _listener: ((CompatibilityEvent) -> Void)?
    public var listener: ((CompatibilityEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _listener }
        set { lock.lock(); _listener = newValue; lock.unlock() }
    }

    /// Is anyone going to look at an event? Lets the inserter skip building one.
    public var wantsEvents: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled || _listener != nil
    }

    public func record(_ event: CompatibilityEvent) {
        lock.lock()
        let listener = _listener
        if enabled {
            events.append(event)
            if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
        }
        lock.unlock()
        listener?(event)
    }

    public var snapshot: [CompatibilityEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func clear() {
        lock.lock(); events.removeAll(); lock.unlock()
    }

    /// The copyable report. Pure over its inputs so the privacy contract (no text content)
    /// is testable.
    public static func render(events: [CompatibilityEvent],
                              speakfreeVersion: String,
                              macOSVersion: String,
                              now: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        var lines: [String] = []
        lines.append("speakfree compatibility report")
        lines.append("speakfree \(speakfreeVersion), macOS \(macOSVersion)")
        lines.append("Generated \(time.string(from: now))")
        lines.append("Contains app names and insertion methods only. No dictated text.")
        lines.append("")

        guard !events.isEmpty else {
            lines.append("No insertions recorded yet. Dictate into the app that has trouble, then copy again.")
            return lines.joined(separator: "\n")
        }

        // Per-app summary, in order of first appearance.
        var order: [String] = []
        var byApp: [String: [CompatibilityEvent]] = [:]
        for event in events {
            if byApp[event.bundleID] == nil { order.append(event.bundleID) }
            byApp[event.bundleID, default: []].append(event)
        }
        lines.append("Apps")
        for id in order {
            let appEvents = byApp[id] ?? []
            guard let last = appEvents.last else { continue }
            let name = [last.appName, last.appVersion.map { "v\($0)" }]
                .compactMap { $0 }.joined(separator: " ")
            var counts: [InsertionOutcome: Int] = [:]
            for event in appEvents { counts[event.outcome, default: 0] += 1 }
            let tally = counts.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                .map { "\($0.key.rawValue) ×\($0.value)" }
                .joined(separator: ", ")
            lines.append("- \(id)\(name.isEmpty ? "" : " (\(name))")")
            lines.append("  detected: \(last.appClass.label) (\(last.reason)); setting: \(last.override.label)")
            lines.append("  results: \(tally)")
        }

        lines.append("")
        lines.append("Recent insertions (newest last)")
        for event in events.suffix(30) {
            lines.append("- \(time.string(from: event.date)) \(event.bundleID): \(event.outcome.rawValue)"
                + (event.multiLine ? ", multi-line" : ""))
        }
        return lines.joined(separator: "\n")
    }
}
