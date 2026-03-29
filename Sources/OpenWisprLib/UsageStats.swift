import Foundation

/// Tracks cumulative usage statistics persisted to disk.
class UsageStats {
    static let shared = UsageStats()

    private struct Data: Codable {
        var totalCharacters: Int = 0
        var totalDictations: Int = 0
        var totalAudioSeconds: Double = 0  // how long they spoke
    }

    private var data = Data()
    private let statsFile = Config.configDir.appendingPathComponent("stats.json")

    private init() {
        load()
    }

    private func load() {
        guard let fileData = try? Foundation.Data(contentsOf: statsFile) else { return }
        data = (try? JSONDecoder().decode(Data.self, from: fileData)) ?? Data()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: statsFile)
    }

    /// Record a completed dictation
    func recordDictation(characters: Int, audioSeconds: Double) {
        data.totalCharacters += characters
        data.totalDictations += 1
        data.totalAudioSeconds += audioSeconds
        save()
    }

    var totalCharacters: Int { data.totalCharacters }
    var totalDictations: Int { data.totalDictations }
    var totalAudioSeconds: Double { data.totalAudioSeconds }

    /// Estimate time saved: assume average typing speed of 40 WPM (200 chars/min = 3.3 chars/sec)
    /// Time saved = characters / 3.3 seconds
    var estimatedTimeSaved: TimeInterval {
        Double(data.totalCharacters) / 3.3
    }

    /// Human-readable time saved string
    var timeSavedDescription: String {
        let seconds = estimatedTimeSaved
        if seconds < 60 {
            return "\(Int(seconds)) seconds"
        } else if seconds < 3600 {
            let mins = Int(seconds / 60)
            return "\(mins) minute\(mins == 1 ? "" : "s")"
        } else if seconds < 86400 {
            let hours = seconds / 3600
            return String(format: "%.1f hours", hours)
        } else {
            let days = seconds / 86400
            return String(format: "%.1f days", days)
        }
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
