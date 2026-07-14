import Foundation

public struct Recording {
    public let url: URL
    public let date: Date
    public let text: String?
}

public class RecordingStore {
    // Computed on every access, NOT stored: a stored static snapshots Config.configDir at
    // first touch, so a test setting Config.configDirOverride afterwards would silently
    // read/write the REAL ~/.config path (the exact hole behind the 2026-06-11 live-config
    // clobber). Tests redirect via Config.configDirOverride, same as everything else.
    public static var recordingsDir: URL {
        Config.configDir.appendingPathComponent("recordings")
    }

    static let filePrefix = "recording-"
    static let fileExtension = "wav"
    static var sentinelFile: URL {
        Config.configDir.appendingPathComponent(".recording-in-progress.json")
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func ensureDirectory() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            fputs("Warning: could not create recordings directory: \(error.localizedDescription)\n", stderr)
            return
        }
        // Each attribute operation is independent — a failure in one must not silently
        // skip the others (they share no invariant and the do/catch would hide the gap).
        do {
            // 0700: owner rwx, group/other none — recordings are private to this user
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordingsDir.path)
        } catch {
            fputs("Warning: could not set recordings directory permissions: \(error.localizedDescription)\n", stderr)
        }
        do {
            // Exclude from iCloud/Time Machine backup — recordings can be large and are
            // regenerable from the original audio (or simply re-dictated).
            var mutableURL = recordingsDir
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try mutableURL.setResourceValues(rv)
        } catch {
            fputs("Warning: could not exclude recordings directory from backup: \(error.localizedDescription)\n", stderr)
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

    private static func metaSidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    // MARK: - Provenance sidecar

    /// Provenance for a recording: which app version, engine, model, and input device
    /// produced it. Written as `<audio>.meta.json` next to the wav so quality
    /// regressions can be attributed to a specific build or capture device later.
    public struct RecordingMeta: Codable {
        public let appVersion: String
        public let engine: String
        public let model: String
        public let inputDevice: String?
        public let date: String  // ISO 8601
        public let durationSeconds: Double
        public let transcriptChars: Int

        public init(appVersion: String, engine: String, model: String,
                    inputDevice: String?, date: String,
                    durationSeconds: Double, transcriptChars: Int) {
            self.appVersion = appVersion
            self.engine = engine
            self.model = model
            self.inputDevice = inputDevice
            self.date = date
            self.durationSeconds = durationSeconds
            self.transcriptChars = transcriptChars
        }
    }

    public static func saveMeta(_ meta: RecordingMeta, for audioURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return }
        let sidecar = metaSidecarURL(for: audioURL)
        try? data.write(to: sidecar)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    }

    public static func loadMeta(for audioURL: URL) -> RecordingMeta? {
        guard let data = try? Data(contentsOf: metaSidecarURL(for: audioURL)) else { return nil }
        return try? JSONDecoder().decode(RecordingMeta.self, from: data)
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
                try? FileManager.default.removeItem(at: metaSidecarURL(for: recording.url))
            } catch {
                fputs("Warning: could not remove old recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    /// True when the recordings folder currently holds at least one audio file.
    /// Gates the Settings "Open Recordings / Transcripts Folder" button and the notice.
    public static func hasAudioFiles() -> Bool {
        recordingCount() > 0
    }

    /// Number of recordings (wav files) on disk.
    public static func recordingCount() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return 0 }
        return files.filter { $0.hasSuffix(".\(fileExtension)") && $0.hasPrefix(filePrefix) }.count
    }

    /// Total number of recording artifacts on disk (wavs + transcript/meta sidecars) —
    /// the "# files" shown by the delete-confirmation dialog.
    public static func recordingFileCount() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return 0 }
        return files.filter { $0.hasPrefix(filePrefix) }.count
    }

    /// Persist or dispose a finished dictation's artifacts per the user's opt-in.
    /// `keep: false` deletes the wav and writes no sidecars — nothing persists.
    public static func finishRecording(audioURL: URL, keep: Bool,
                                       raw: String, text: String, meta: RecordingMeta) {
        if keep {
            saveRaw(text: raw, for: audioURL)
            saveTranscription(text: text, for: audioURL)
            saveMeta(meta, for: audioURL)
        } else {
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    public static func deleteAllRecordings() {
        for recording in listRecordings() {
            do {
                try FileManager.default.removeItem(at: recording.url)
                try? FileManager.default.removeItem(at: sidecarURL(for: recording.url))
                try? FileManager.default.removeItem(at: rawSidecarURL(for: recording.url))
                try? FileManager.default.removeItem(at: metaSidecarURL(for: recording.url))
            } catch {
                fputs("Warning: could not remove recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
