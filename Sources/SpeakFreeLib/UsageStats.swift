import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tracks cumulative usage statistics persisted to disk.
class UsageStats {
    static let shared = UsageStats()

    private struct Data: Codable {
        var totalCharacters: Int = 0
        var totalDictations: Int = 0
        var totalAudioSeconds: Double = 0  // how long they spoke
    }

    private var data = Data()
    // Computed per access so Config.configDirOverride (the test-isolation seam) is honored
    // even when the singleton was first touched before the override was set.
    private var statsFile: URL { Config.configDir.appendingPathComponent("stats.json") }
    // Serial queue so the per-dictation disk write no longer runs on main. Also serializes
    // saves against flush() so the last write is never lost on quit.
    private let saveQueue = DispatchQueue(label: "com.speakfree.usagestats.save", qos: .utility)

    private init() {
        load()
        #if canImport(AppKit)
        // App quit can outrun an async save. Drain the queue synchronously on termination so
        // the final dictation is always persisted. (Self-registered rather than wired through
        // AppDelegate so this stays self-contained.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
        #endif
    }

    private func load() {
        guard let fileData = try? Foundation.Data(contentsOf: statsFile) else { return }
        data = (try? JSONDecoder().decode(Data.self, from: fileData)) ?? Data()
    }

    private func save() {
        // Snapshot the value-type struct on the caller thread, then write off-main. The
        // snapshot avoids racing a later in-memory increment.
        let snapshot = data
        let file = statsFile
        saveQueue.async {
            try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: file)
        }
    }

    /// Block until all pending background saves have flushed to disk. Called on app quit.
    func flush() {
        saveQueue.sync {}
    }

    /// Record a completed dictation
    func recordDictation(characters: Int, audioSeconds: Double) {
        // Counter update stays synchronous so totalDictations is immediately correct; only the
        // disk write is deferred off-main.
        data.totalCharacters += characters
        data.totalDictations += 1
        data.totalAudioSeconds += audioSeconds
        save()
    }

    var totalCharacters: Int { data.totalCharacters }
    var totalDictations: Int { data.totalDictations }
    var totalAudioSeconds: Double { data.totalAudioSeconds }

    /// Typing speeds the saved-time estimate brackets, in characters per second (5 chars/word).
    ///
    /// The old estimate hardcoded 40 WPM — 3.3 chars/sec — and reported the result as a single
    /// precise figure. Michael types 110-165 WPM (speech audit, finding 18), so his "time saved"
    /// was inflated roughly 3-4x and "saving 4.9 days" was fiction. A single number cannot be
    /// honest here because the counterfactual depends entirely on who is typing, so the estimate
    /// is a RANGE and is presented as one.
    static let fastTypistCharsPerSecond = 10.0   // 120 WPM
    static let averageTypistCharsPerSecond = 3.3 //  40 WPM

    /// Saved-time bracket: `low` assumes you type fast, `high` assumes average.
    /// Speaking time is subtracted from both — dictating is not free.
    var estimatedTimeSavedRange: (low: TimeInterval, high: TimeInterval) {
        let chars = Double(data.totalCharacters)
        let fast = chars / Self.fastTypistCharsPerSecond
        let average = chars / Self.averageTypistCharsPerSecond
        return (max(0, fast - data.totalAudioSeconds),
                max(0, average - data.totalAudioSeconds))
    }

    /// Kept as the conservative (fast-typist) end so any remaining single-value caller
    /// under-claims rather than over-claims.
    var estimatedTimeSaved: TimeInterval { estimatedTimeSavedRange.low }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds)) seconds"
        } else if seconds < 3600 {
            let mins = Int(seconds / 60)
            return "\(mins) minute\(mins == 1 ? "" : "s")"
        } else if seconds < 86400 {
            return String(format: "%.1f hours", seconds / 3600)
        } else {
            return String(format: "%.1f days", seconds / 86400)
        }
    }

    /// Human-readable saved-time RANGE, e.g. "1.4-4.6 hours". Collapses to a single figure only
    /// when both ends format identically, so the honest uncertainty is never hidden.
    var timeSavedDescription: String {
        let range = estimatedTimeSavedRange
        let low = Self.formatDuration(range.low)
        let high = Self.formatDuration(range.high)
        if low == high { return low }
        // Drop the duplicated unit from the low end when both share it ("1.4-4.6 hours").
        let lowParts = low.split(separator: " ")
        let highParts = high.split(separator: " ")
        if lowParts.count == 2, highParts.count == 2, lowParts[1] == highParts[1] {
            return "\(lowParts[0])-\(highParts[0]) \(highParts[1])"
        }
        return "\(low)-\(high)"
    }

    // MARK: - Two-line stats display (Michael 2026-08-20)

    /// Words ≈ characters / 5 (the standard WPM convention; the corpus does not store
    /// per-dictation word counts).
    var totalWords: Int { data.totalCharacters / 5 }

    /// "2 days 3 hours 12 minutes" — leading zero units dropped, minutes floor.
    static func formatDaysHoursMinutes(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        return parts.joined(separator: " ")
    }

    /// Hand travel avoided: metres a typist's fingers would have moved to type the
    /// dictated characters. 2 cm per keystroke — the ~19 mm key pitch plus per-stroke
    /// vertical travel; deliberately a round, stated assumption rather than a modelled
    /// one (same honesty rule as the typing-speed bracket above).
    static let handTravelMetresPerKeystroke = 0.02
    var handTravelMetres: Double { Double(data.totalCharacters) * Self.handTravelMetresPerKeystroke }

    /// Imperial: feet under a mile, then miles ("0.6 miles", "12 miles").
    var handTravelImperialDescription: String {
        let feet = handTravelMetres * 3.28084
        if feet < 5280 { return "\(Int(feet)) feet" }
        let miles = feet / 5280
        return String(format: miles < 10 ? "%.1f miles" : "%.0f miles", miles)
    }

    /// Metric: metres under a kilometre, then kilometres.
    var handTravelMetricDescription: String {
        if handTravelMetres < 1000 { return "\(Int(handTravelMetres)) meters" }
        let km = handTravelMetres / 1000
        return String(format: km < 10 ? "%.1f kilometers" : "%.0f kilometers", km)
    }

    /// Formatted keystroke count
    var keystrokesDescription: String {
        let chars = data.totalCharacters
        if chars < 1000 {
            return "\(chars)"
        } else if chars < 1_000_000 {
            return String(format: "%.1fK", Double(chars) / 1000)
        } else {
            return String(format: "%.1fM", Double(chars) / 1_000_000)
        }
    }
}
