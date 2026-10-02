// Claude · 2026-09-24 · Edit Mode V1
import Foundation

/// Edit Mode timing log: numbers and model names only, never text (design). One JSON
/// object per line in `<configDir>/edit-latency.jsonl`, 0600, capped at 2,000 lines. It exists so
/// "it feels slow" becomes a number, and so the V1.1 decision on a persistent Claude process
/// (build it only if the median settle stays above 5 s) is made on in-app measurements.
public final class EditLatencyLog {

    public struct Entry: Codable, Equatable {
        public let event: String      // provisional | cleanup | compare | compare-choice | commit
        public let model: String?     // sonnet | opus | haiku
        public let ms: Int?
        public let chars: Int?        // a character COUNT, never characters
        public let applied: Int?
        public let rejected: Int?
        public let outcome: String    // ok | dropped | cancelled | failed:<code> | inserted | retained:<reason>
        public var at: String?

        public init(event: String, model: String?, ms: Int?, chars: Int?, applied: Int?,
                    rejected: Int?, outcome: String) {
            self.event = event
            self.model = model
            self.ms = ms
            self.chars = chars
            self.applied = applied
            self.rejected = rejected
            self.outcome = outcome
        }
    }

    public static let maxLines = 2_000
    private let queue = DispatchQueue(label: "com.speakfree.edit-latency")
    private let url: URL

    /// Computed from `Config.configDir` at init, so tests with `configDirOverride` write there.
    public init(url: URL? = nil) {
        self.url = url ?? Config.configDir.appendingPathComponent("edit-latency.jsonl")
    }

    public var fileURL: URL { url }

    public func record(_ entry: Entry) {
        var e = entry
        e.at = ISO8601DateFormatter().string(from: Date())
        let url = self.url
        queue.async { Self.append(e, to: url) }
    }

    /// Block until queued writes land (tests).
    public func flush() { queue.sync {} }

    private static func append(_ entry: Entry, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        var lines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing.split(separator: "\n").map(String.init)
        }
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
