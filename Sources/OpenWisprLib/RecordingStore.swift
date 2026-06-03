import Foundation

public struct Recording {
    public let url: URL
    public let date: Date
    public let text: String?
}

public class RecordingStore {
    public static var recordingsDir = Config.configDir.appendingPathComponent("recordings")

    static let filePrefix = "recording-"
    static let fileExtension = "wav"
    static let sentinelFile = Config.configDir.appendingPathComponent(".recording-in-progress.json")

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func ensureDirectory() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            // 0700: owner rwx, group/other none — recordings are private to this user
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordingsDir.path)
            // Exclude from iCloud/Time Machine backup — recordings can be large and are
            // regenerable from the original audio (or simply re-dictated).
            var mutableURL = recordingsDir
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try mutableURL.setResourceValues(rv)
        } catch {
            fputs("Warning: could not configure recordings directory: \(error.localizedDescription)\n", stderr)
        }
    }

    // Always write to recordings dir, never temp — enables crash recovery regardless of maxRecordings setting
    public static func newRecordingURL() -> URL {
        ensureDirectory()
        let timestamp = dateFormatter.string(from: Date())
        let unique = String(UUID().uuidString.prefix(8))
        let filename = "\(filePrefix)\(timestamp)-\(unique).\(fileExtension)"
        return recordingsDir.appendingPathComponent(filename)
    }

    // MARK: - Crash sentinel

    private struct SentinelData: Codable {
        let recordingPath: String
        let startedAt: Date
    }

    public static func writeSentinel(recordingURL: URL) {
        let data = SentinelData(recordingPath: recordingURL.path, startedAt: Date())
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: sentinelFile)
        }
    }

    public static func clearSentinel() {
        try? FileManager.default.removeItem(at: sentinelFile)
    }

    // Returns an orphaned recording URL if the app crashed during a previous recording session.
    // The file must exist and have content to be considered recoverable.
    public static func checkCrashRecovery() -> URL? {
        guard let data = try? Data(contentsOf: sentinelFile),
              let sentinel = try? JSONDecoder().decode(SentinelData.self, from: data) else {
            return nil
        }
        let url = URL(fileURLWithPath: sentinel.recordingPath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int ?? 0
        guard FileManager.default.fileExists(atPath: url.path), size > 1024 else {
            clearSentinel()
            return nil
        }
        return url
    }

    // MARK: - Transcription sidecar

    public static func saveTranscription(text: String, for audioURL: URL) {
        let sidecar = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try? text.write(to: sidecar, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    }

    /// Save raw whisper output before any post-processing, as `<audio>.raw.txt`.
    /// Pairs with `.txt` (post-processed) to form a regression corpus for the post-processor.
    public static func saveRaw(text: String, for audioURL: URL) {
        let sidecar = audioURL.deletingPathExtension().appendingPathExtension("raw.txt")
        try? text.write(to: sidecar, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    }

    private static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("txt")
    }

    private static func rawSidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("raw.txt")
    }

    // MARK: - Listing and pruning

    public static func listRecordings() -> [Recording] {
        ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == fileExtension && $0.lastPathComponent.hasPrefix(filePrefix) }
            .compactMap { url -> Recording? in
                let name = url.deletingPathExtension().lastPathComponent
                let dateString = String(name.dropFirst(filePrefix.count))
                let datePart = String(dateString.prefix(17))
                guard let date = dateFormatter.date(from: datePart) else { return nil }
                let text = try? String(contentsOf: sidecarURL(for: url), encoding: .utf8)
                return Recording(url: url, date: date, text: text)
            }
            .sorted { $0.date > $1.date }
    }

    public static func prune(maxCount: Int) {
        guard maxCount > 0 else { return }
        let recordings = listRecordings()
        guard recordings.count > maxCount else { return }

        let toRemove = recordings.suffix(from: maxCount)
        for recording in toRemove {
            do {
                try FileManager.default.removeItem(at: recording.url)
                try? FileManager.default.removeItem(at: sidecarURL(for: recording.url))
                try? FileManager.default.removeItem(at: rawSidecarURL(for: recording.url))
            } catch {
                fputs("Warning: could not remove old recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    public static func deleteAllRecordings() {
        for recording in listRecordings() {
            do {
                try FileManager.default.removeItem(at: recording.url)
                try? FileManager.default.removeItem(at: sidecarURL(for: recording.url))
                try? FileManager.default.removeItem(at: rawSidecarURL(for: recording.url))
            } catch {
                fputs("Warning: could not remove recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
