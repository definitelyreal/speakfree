// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
import Foundation
import Darwin
import AVFoundation

public struct Recording: Sendable {
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

    /// P8: serializes the three mutating operations that otherwise race each other —
    /// `finishRecording` (writes wav + sidecars), `deleteAllRecordings`, and `prune`. Without it
    /// a "Delete All" from Settings can interleave with a dictation's finalize (TOCTOU: the
    /// fileExists guard passes, another thread deletes the wav, then the sidecar writes resurrect
    /// an orphan) and two concurrent prunes can double-remove the same file. Static because all
    /// three operations are static. The read-only listing/count helpers stay un-locked.
    private static let mutationLock = NSLock()
    static var sentinelFile: URL {
        Config.configDir.appendingPathComponent(".recording-in-progress.json")
    }

    // M5: once-per-launch `ensureDirectory()` guard. Keyed on the recordings-dir PATH (not a plain
    // Bool) so a `Config.configDirOverride` switch in tests re-ensures the new dir, while production
    // — where the path is stable — pays the 3 create/perms/backup-exclude syscalls exactly once
    // instead of on every `newRecordingURL()`/`listRecordings()` call.
    private static let ensureLock = NSLock()
    private static var ensuredDir: String?

    // M2: cached wav count for the Settings-open hot path (finding 9 — a 22k-file scan on main took
    // ~1.9s). Keyed on the recordings-dir path so a `configDirOverride` switch auto-invalidates it
    // (tests) and production stays warm. Kept live by finishRecording/deleteAllRecordings/prune.
    // `recordingCount()` stays a live scan (callers/tests rely on it reflecting disk immediately);
    // only `cachedRecordingCount()` is the fast path.
    private static let countLock = NSLock()
    private static var cachedCountDir: String?
    private static var cachedCount = 0

    // M1 test seam: number of transcript sidecars actually opened by `listRecordings(limit:)`.
    // Proves the newest-N selection reads at most N sidecars, not one per corpus file.
    // Production never reads these values; tests reset/read them around synchronous calls.
    internal static var sidecarReadsForTesting = 0
    /// M1 test seam: timestamp parses performed by the capped newest-N path.
    internal static var dateParsesForTesting = 0

    private static func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static let dateFormatter = makeDateFormatter()

    /// DateFormatter is not thread-safe, and the shared instance is reached from main
    /// (`newRecordingURL` at record-start) and background finalize paths concurrently.
    /// A race doesn't crash — it silently CORRUPTS the formatter's internal state for
    /// the process lifetime, after which every recording filename is garbage and every
    /// AVAudioFile create throws: the 2026-07-23 "fn does nothing until relaunch"
    /// outage signature. All shared-formatter access now goes through this lock.
    private static let dateFormatterLock = NSLock()
    static func formatTimestamp(_ date: Date) -> String {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return dateFormatter.string(from: date)
    }
    static func parseTimestamp(_ s: String) -> Date? {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return dateFormatter.date(from: s)
    }

    public static func ensureDirectory() {
        ensureLock.lock()
        defer { ensureLock.unlock() }
        // M5: skip the full create/perms/backup-exclude syscalls if this exact dir was already
        // ensured this launch AND still exists. The existence probe is ONE cheap `stat` per call
        // (not a createDirectory syscall) — it catches the user trashing or moving the recordings
        // folder mid-session, where the once-guard alone would skip recreation and the next
        // `AVAudioFile(forWriting:)` would throw. Only a SUCCESSFUL create records the path, so a
        // failed create is retried on the next call (never cached).
        let dirPath = recordingsDir.path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if ensuredDir == dirPath,
           fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
            return
        }
        do {
            // PR-D: pass 0700 straight to createDirectory so a newly-created dir is never
            // briefly world-readable in the create-then-chmod window. The setAttributes below
            // still re-asserts permissions for a pre-existing dir (attributes: is ignored when
            // the directory already exists).
            try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
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
        ensuredDir = dirPath
    }

    // Always write to recordings dir, never temp — enables crash recovery regardless of maxRecordings setting
    public static func newRecordingURL() -> URL {
        ensureDirectory()
        let timestamp = formatTimestamp(Date())
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

    /// Launch sweep for RECOVERABLE ORPHANS: primary wavs with no transcript sidecar,
    /// recent enough to matter. Repairs stale/zero RIFF headers in place (the AVAudioFile
    /// crash signature — 94 such orphans existed in the live corpus on 2026-07-25, one
    /// holding 37 minutes of audio) and probes real duration. Returns newest-first.
    /// Cheap: one directory scan + per-candidate header reads; only orphans pay more.
    public static func sweepRecoverableOrphans(
        maxAgeDays: Int = 14, minSeconds: Double = 3.0, limit: Int = 5
    ) -> [(url: URL, seconds: Double)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let wavs = names.filter {
            $0.hasPrefix(filePrefix) && $0.hasSuffix(".wav") && !$0.hasSuffix(".bt.wav")
        }
        let txts = Set(names.filter { $0.hasSuffix(".txt") })
        var found: [(URL, Double, Date)] = []
        for name in wavs {
            let stem = String(name.dropLast(4))
            guard !txts.contains(stem + ".txt") else { continue }
            let url = recordingsDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date, mtime > cutoff,
                  (attrs[.size] as? Int ?? 0) > 44 else { continue }
            // Skip files still being WRITTEN (codex review #1): another instance
            // (prod + the STREAMING variant share configDir; only beta is isolated),
            // or this launch racing its own first recording, must never
            // repair/transcribe a live capture. 120s of quiet is far beyond
            // WavWriter's 5s patch cadence.
            guard mtime.timeIntervalSinceNow < -120 else { continue }
            // Repair a truncated header if needed (no-op returns nil when already valid),
            // then trust the (possibly just-fixed) header for duration.
            WavWriter.repairHeader(at: url)
            guard let f = try? AVAudioFile(forReading: url) else { continue }
            let seconds = Double(f.length) / f.processingFormat.sampleRate
            guard seconds >= minSeconds else { continue }
            found.append((url, seconds, mtime))
        }
        return found.sorted { $0.2 > $1.2 }.prefix(limit).map { ($0.0, $0.1) }
    }

    // MARK: - Transcription sidecar

    public static func saveTranscription(text: String, for audioURL: URL) {
        let sidecar = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try? text.write(to: sidecar, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    }

    @discardableResult
    public static func updateFinalTranscription(text: String, for audioURL: URL) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let sidecar = sidecarURL(for: audioURL)
        guard FileManager.default.fileExists(atPath: audioURL.path),
              FileManager.default.fileExists(atPath: sidecar.path) else { return false }
        do {
            try text.write(to: sidecar, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            return true
        } catch {
            DiagnosticLogger.shared.log(
                "RecordingStore: failed to update final transcript for \(audioURL.lastPathComponent): "
                    + error.localizedDescription)
            return false
        }
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
        /// Bundle id of the app the dictation was inserted into (2026-07-22).
        /// Optional: absent in pre-existing sidecars and file-transcription metas.
        /// The edit-feedback batch (tune-corpus) uses it to find the final artifact
        /// (sent message, saved doc) to diff against what was inserted.
        public let targetApp: String?
        /// Optional engine quality signals (present for Parakeet takes recorded after P2/P3).
        public let transcriptionDiagnostics: TranscriptionDiagnostics?

        public init(appVersion: String, engine: String, model: String,
                    inputDevice: String?, date: String,
                    durationSeconds: Double, transcriptChars: Int,
                    targetApp: String? = nil,
                    transcriptionDiagnostics: TranscriptionDiagnostics? = nil) {
            self.appVersion = appVersion
            self.engine = engine
            self.model = model
            self.inputDevice = inputDevice
            self.date = date
            self.durationSeconds = durationSeconds
            self.transcriptChars = transcriptChars
            self.targetApp = targetApp
            self.transcriptionDiagnostics = transcriptionDiagnostics
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
            .filter {
                $0.pathExtension.lowercased() == fileExtension
                    && !$0.lastPathComponent.hasSuffix(".bt.wav")
                    && $0.lastPathComponent.hasPrefix(filePrefix)
            }
            .compactMap { url -> Recording? in
                let name = url.deletingPathExtension().lastPathComponent
                let dateString = String(name.dropFirst(filePrefix.count))
                let datePart = String(dateString.prefix(17))
                guard let date = parseTimestamp(datePart) else { return nil }
                let text = try? String(contentsOf: sidecarURL(for: url), encoding: .utf8)
                return Recording(url: url, date: date, text: text)
            }
            .sorted { $0.date > $1.date }
    }

    /// M1: newest-N listing that does NOT open a transcript sidecar for every recording. The
    /// recording timestamp is embedded in the filename (`recording-yyyy-MM-dd-HHmmss-uuid.wav`), so
    /// the newest N are selected by filename alone; only that ≤N slice reads its `.txt`. This is what
    /// the menu-bar "Recent Dictations" submenu calls so a 5,565-file corpus stops causing thousands
    /// of file-opens on every menu build.
    public static func listRecordings(limit: Int) -> [Recording] {
        guard limit > 0 else { return [] }
        ensureDirectory()
        // Foundation's `contentsOfDirectory(atPath:)` unexpectedly performs per-entry
        // metadata work on this 23k-artifact directory (tens of seconds on the real
        // corpus). POSIX readdir is genuinely names-only and needs no file attributes.
        guard let names = directoryEntryNames(atPath: recordingsDir.path) else {
            return []
        }
        // The fixed-width embedded timestamp sorts chronologically as text. Filter and
        // select the newest N names FIRST, then parse only those N dates. Parsing all
        // ~6k primary timestamps on main was still a visible submenu-hover stall.
        let newestNames = names.filter { name in
            name.hasPrefix(filePrefix) && name.hasSuffix(".\(fileExtension)")
                && !name.hasSuffix(".bt.wav")
        }.sorted(by: >).prefix(limit)
        // DateFormatter is not thread-safe. This path now runs on the Recent Dictations
        // utility queue, potentially while the recorder creates a filename on main.
        let filenameDateFormatter = makeDateFormatter()
        let dated: [(url: URL, date: Date)] = newestNames.compactMap { name in
            let base = (name as NSString).deletingPathExtension
            let dateString = String(base.dropFirst(filePrefix.count))
            let datePart = String(dateString.prefix(17))
            dateParsesForTesting += 1
            guard let date = filenameDateFormatter.date(from: datePart) else { return nil }
            return (recordingsDir.appendingPathComponent(name), date)
        }
        // Sidecar read ONLY for the ≤N newest slice.
        return dated.map { entry in
            sidecarReadsForTesting += 1
            let text = try? String(contentsOf: sidecarURL(for: entry.url), encoding: .utf8)
            return Recording(url: entry.url, date: entry.date, text: text)
        }
    }

    private static func directoryEntryNames(atPath path: String) -> [String]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    public static func prune(maxCount: Int) {
        guard maxCount > 0 else { return }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let recordings = listRecordings()
        guard recordings.count > maxCount else { return }

        let toRemove = recordings.suffix(from: maxCount)
        for recording in toRemove {
            do {
                try FileManager.default.removeItem(at: recording.url)
                try? FileManager.default.removeItem(at: sidecarURL(for: recording.url))
                try? FileManager.default.removeItem(at: rawSidecarURL(for: recording.url))
                try? FileManager.default.removeItem(at: metaSidecarURL(for: recording.url))
                let base = recording.url.deletingPathExtension()
                try? FileManager.default.removeItem(
                    at: base.appendingPathExtension("builtin.raw.txt"))
                try? FileManager.default.removeItem(at: base.appendingPathExtension("bt.wav"))
                try? FileManager.default.removeItem(at: base.appendingPathExtension("bt.raw.txt"))
            } catch {
                fputs("Warning: could not remove old recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
        // M2: the cached count no longer reflects disk — recompute lazily on the next read.
        invalidateCachedCount()
    }

    // MARK: - Cached recording count (M2)

    /// Fast wav count for the Settings-open hot path. Lazily computed once per dir via a live scan,
    /// then kept current by finishRecording/deleteAllRecordings/prune — so Settings-open stops
    /// rescanning the whole corpus on the main thread. Not a replacement for `recordingCount()`,
    /// which stays a live scan for callers that manipulate the folder directly.
    public static func cachedRecordingCount() -> Int {
        countLock.lock()
        defer { countLock.unlock() }
        let path = recordingsDir.path
        if cachedCountDir != path {
            cachedCount = recordingCount()   // one-time live scan for this dir
            cachedCountDir = path
        }
        return cachedCount
    }

    /// Adjust a WARM cache in place (no rescan). A cold cache is left cold so the next
    /// `cachedRecordingCount()` recomputes from disk — which already reflects the mutation.
    private static func bumpCachedCount(by delta: Int) {
        countLock.lock()
        defer { countLock.unlock() }
        if cachedCountDir == recordingsDir.path {
            cachedCount = max(0, cachedCount + delta)
        }
    }

    private static func setCachedCount(_ value: Int) {
        countLock.lock()
        defer { countLock.unlock() }
        cachedCount = value
        cachedCountDir = recordingsDir.path
    }

    private static func invalidateCachedCount() {
        countLock.lock()
        defer { countLock.unlock() }
        cachedCountDir = nil
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
        return files.filter {
            $0.hasSuffix(".\(fileExtension)") && !$0.hasSuffix(".bt.wav")
                && $0.hasPrefix(filePrefix)
        }.count
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
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if keep {
            // PR-C: a concurrent "Delete All" can remove the wav mid-dictation. Writing
            // sidecars now would resurrect orphaned transcripts with no audio behind them —
            // skip the writes if the wav is already gone.
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                DiagnosticLogger.shared.log("RecordingStore: wav vanished before finish — skipping sidecar writes for \(audioURL.lastPathComponent)")
                return
            }
            saveRaw(text: raw, for: audioURL)
            saveTranscription(text: text, for: audioURL)
            saveMeta(meta, for: audioURL)
            // M2: a kept recording adds one wav — bump the cached count (past the wav-exists guard
            // so a recording that vanished mid-finalize is never counted).
            bumpCachedCount(by: 1)
        } else {
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    /// The known recording-artifact extensions, longest-first so a compound suffix
    /// (`.bt.raw.txt`) is matched before its tail (`.raw.txt`, `.txt`).
    ///
    /// `.bt.wav` / `.bt.raw.txt` / `.builtin.raw.txt` are DEAD WRITE FORMATS as of
    /// 2026-08-12 (dual capture removed) but stay in this list forever: the local
    /// archive holds 905 real dual-capture takes, and every one of those files must
    /// still be excluded from recording counts and still be deleted by Delete All.
    private static let artifactSuffixes = [
        ".builtin.raw.txt", ".bt.raw.txt", ".raw.txt", ".meta.json", ".bt.wav", ".wav", ".txt",
    ]

    /// True only for a name that is an EXACT recording artifact: `recording-<timestamp>...` with a
    /// parseable embedded timestamp and one of the known artifact extensions. This is the deletion
    /// allow-list for Delete All — a human-managed `recording-archive/` (no artifact extension) or
    /// `recording-notes.pdf` (foreign extension) both fail this and are left untouched. Type
    /// (regular file vs directory) is checked separately at the call site.
    static func isRecordingArtifact(_ name: String) -> Bool {
        guard name.hasPrefix(filePrefix) else { return false }
        guard let suffix = artifactSuffixes.first(where: { name.hasSuffix($0) }) else { return false }
        let stem = String(name.dropLast(suffix.count))
        let dateString = String(stem.dropFirst(filePrefix.count))
        let datePart = String(dateString.prefix(17))
        return parseTimestamp(datePart) != nil
    }

    public static func deleteAllRecordings() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // M3 + orphan-sweep safety: enumerate names directly (no per-file sidecar opens) and remove
        // ONLY regular files that are EXACT recording artifacts — `recording-<timestamp>` plus a
        // known extension. Never recurse into directories and never match a foreign extension, so a
        // human-managed `recording-archive/` folder or a `recording-notes.pdf` survives. Never
        // touches the crash sentinel (it lives in configDir, not recordingsDir).
        let fm = FileManager.default
        var allRemoved = true
        if let names = try? fm.contentsOfDirectory(atPath: recordingsDir.path) {
            for name in names where isRecordingArtifact(name) {
                let url = recordingsDir.appendingPathComponent(name)
                // Regular files only — a directory whose name happens to match is never removed
                // (and never recursed into).
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                do {
                    try fm.removeItem(at: url)
                } catch {
                    allRemoved = false
                    fputs("Warning: could not remove recording \(url.path): \(error.localizedDescription)\n", stderr)
                }
            }
        }
        // M2 / privacy: only zero the cached count when EVERY removal succeeded. A failed removal
        // leaves sensitive wavs on disk — invalidate instead so the next read rescans and Settings
        // keeps showing the survivors rather than reporting zero and hiding the folder controls.
        if allRemoved {
            setCachedCount(0)
        } else {
            invalidateCachedCount()
        }
    }
}
