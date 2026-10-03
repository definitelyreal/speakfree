// ai-suggestion:unverified · session:6a1b0646-1bc6-4f76-9662-5e5a8f92c97c · 2026-08-11
// ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
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

    /// Serializes final/edit publication and legacy pruning/deletion. Trash uses
    /// RecordingActivity group claims, so long filesystem work never blocks a new
    /// take's finalization on this mutex. Reader/writer admission is a separate short lock.
    private static let mutationLock = NSLock()
    private static let sentinelLock = NSLock()
    static var sentinelFile: URL {
        Config.configDir.appendingPathComponent(".recording-in-progress.json")
    }

    // M5: once-per-launch `ensureDirectory()` guard. Keyed on the recordings-dir PATH (not a plain
    // Bool) so a `Config.configDirOverride` switch in tests re-ensures the new dir, while production
    // — where the path is stable — pays the 3 create/perms/backup-exclude syscalls exactly once
    // instead of on every `newRecordingURL()`/`listRecordings()` call.
    private static let ensureLock = NSLock()
    private static var ensuredDir: String?

    // M2: cached retained-audio count for the Settings-open hot path (finding 9 — a 22k-file scan on main took
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
        sentinelLock.lock()
        defer { sentinelLock.unlock() }
        let data = SentinelData(recordingPath: recordingURL.path, startedAt: Date())
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: sentinelFile)
        }
    }

    public static func clearSentinel(recordingURL: URL? = nil) {
        sentinelLock.lock()
        defer { sentinelLock.unlock() }
        if let recordingURL {
            guard let data = try? Data(contentsOf: sentinelFile),
                  let sentinel = try? JSONDecoder().decode(SentinelData.self, from: data),
                  URL(fileURLWithPath: sentinel.recordingPath).standardizedFileURL == recordingURL.standardizedFileURL else { return }
        }
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
            clearSentinel(recordingURL: url)
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
            guard !AudioArchiveIntegrity.isInvalid(url) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date, mtime > cutoff,
                  (attrs[.size] as? Int ?? 0) > 44 else { continue }
            // Skip files still being WRITTEN (codex review #1): another instance
            // (prod + the STREAMING variant share configDir; only beta is isolated),
            // or this launch racing its own first recording, must never
            // repair/transcribe a live capture. 120s of quiet is far beyond
            // WavWriter's 5s patch cadence.
            guard mtime.timeIntervalSinceNow < -120 else { continue }
            guard let activityLease = try? RecordingActivity.shared.acquireReading(url) else { continue }
            defer { activityLease.release() }
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
        saveTextSidecar(text: text, extension: "txt", for: audioURL)
    }

    enum AuxiliaryTranscript: String { case parakeet, whisper }

    static func saveAuxiliaryTranscription(text: String, kind: AuxiliaryTranscript, for audioURL: URL) {
        saveTextSidecar(text: text, extension: "\(kind.rawValue).txt", for: audioURL)
    }

    /// Also protects standalone recovery/shadow publications after their caller returns.
    /// Missing or already-claimed audio must not resurrect an orphaned transcript.
    private static func saveTextSidecar(text: String, extension suffix: String, for audioURL: URL) {
        guard let activityLease = try? RecordingActivity.shared.acquireReading(audioURL) else { return }
        defer { activityLease.release() }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        let sidecar = audioURL.deletingPathExtension().appendingPathExtension(suffix)
        try? text.write(to: sidecar, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    }

    @discardableResult
    public static func updateFinalTranscription(text: String, for audioURL: URL) -> Bool {
        guard let activityLease = try? RecordingActivity.shared.acquireReading(audioURL) else { return false }
        defer { activityLease.release() }
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
        saveTextSidecar(text: text, extension: "raw.txt", for: audioURL)
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
        /// Post-release wait for this take (2026-09-22). Optional: absent in older sidecars.
        /// `keyReleaseSample` indexes the saved audio at key release so the post-release
        /// decision can be replayed offline against the real tail.
        public let keyReleaseSample: Int?
        public let postBufferWaitMs: Double?
        public let postBufferExtended: Bool?

        public init(appVersion: String, engine: String, model: String,
                    inputDevice: String?, date: String,
                    durationSeconds: Double, transcriptChars: Int,
                    targetApp: String? = nil,
                    transcriptionDiagnostics: TranscriptionDiagnostics? = nil,
                    postBuffer: PostBufferOutcome? = nil) {
            self.keyReleaseSample = postBuffer?.releaseSample
            self.postBufferWaitMs = postBuffer.map { ($0.waitedMs * 10).rounded() / 10 }
            self.postBufferExtended = postBuffer?.extended
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
        guard let activityLease = try? RecordingActivity.shared.acquireReading(audioURL) else { return }
        defer { activityLease.release() }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
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

    static func directoryEntryNames(atPath path: String) -> [String]? {
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
        let removal = RecordingActivity.shared.beginRemoval(in: recordingsDir)
        defer { removal.finish() }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard let names = directoryEntryNames(atPath: recordingsDir.path) else { return }
        let groups = Dictionary(grouping: names.filter { isRecordingArtifact($0) }) {
            RecordingActivity.stem(for: recordingsDir.appendingPathComponent($0))
        }
        // One Keep N budget: primary WAVs and recovery audio count as retained takes.
        // Marker-only and transcript-only groups do not evict captured audio.
        // Fixed-width timestamps keep the normal healthy-WAV chronology unchanged.
        let retainedTakes = groups.keys.filter { stem in
            let files = groups[stem] ?? []
            return files.contains(stem + ".wav") || files.contains(where: { name in
                name.hasSuffix(".archive-damaged") || name.hasSuffix(".archive-repair")
            })
        }.sorted(by: >)
        let audioStems = Set(retainedTakes)
        // Clean marker-only leftovers through the same lease/type guards below.
        // Unrelated transcript-only strays remain outside this cleanup inventory.
        let markerOnly = groups.keys.filter { stem in
            !audioStems.contains(stem) && (groups[stem] ?? []).contains(stem + ".archive-invalid")
        }.sorted(by: >)
        let expired = Array(retainedTakes.dropFirst(maxCount)) + markerOnly
        guard !expired.isEmpty else { return }
        var withdrawn = Set<String>()
        let fm = FileManager.default
        for stem in expired {
            let audio = recordingsDir.appendingPathComponent(stem + ".wav")
            guard removal.claim(audio) else { continue }
            let files = (groups[stem] ?? []).map { recordingsDir.appendingPathComponent($0) }
            do {
                // Never recurse through a matching directory or traverse an alias.
                guard try files.allSatisfy({
                    try fm.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType == .typeRegular
                }) else { continue }
                // Remove the canonical audio first. A failure leaves every companion,
                // especially the durable invalid marker, at its original location.
                if fm.fileExists(atPath: audio.path) {
                    guard files.contains(audio) else { continue }
                    try fm.removeItem(at: audio)
                }
                withdrawn.insert(stem)
                let recovery = AudioRecorder.recoveryArtifactURLs(for: audio)
                // Recovery artifacts remain as a retryable group if sidecar deletion fails.
                for file in files where file != audio && !recovery.contains(file) {
                    try fm.removeItem(at: file)
                }
                // The invalid marker is last, after audio and all other companions.
                for file in recovery where files.contains(file) { try fm.removeItem(at: file) }
                AudioArchiveIntegrity.forget(audio)
            } catch {
                DiagnosticLogger.shared.log("RecordingStore: could not prune recording group \(stem): \(error.localizedDescription)")
            }
        }
        EditRecents.prune(maxCount: maxCount)
        invalidateCachedCount()
        // Protected or failed-to-withdraw takes remain indexed. A removed WAV must
        // not leave its timestamp behind merely because it had recovery companions.
        if !withdrawn.isEmpty { filterRecentIndexLocked(removing: withdrawn) }
    }

    // MARK: - Cached recording count (M2)

    /// Fast retained-audio count for the Settings-open hot path. Lazily computed once per dir via a live scan,
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

    static func invalidateCachedCount() {
        countLock.lock()
        defer { countLock.unlock() }
        cachedCountDir = nil
    }

    /// True when retained audio exists, including nonplayable recovery evidence.
    /// Gates the recordings-folder/removal affordances and the launch notice.
    public static func hasAudioFiles() -> Bool {
        recordingCount() > 0
    }

    /// Number of retained audio stems, distinct from the playable WAV listing.
    /// Multiple recovery copies count once; markers/transcripts alone contain no audio.
    public static func recordingCount() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return 0 }
        let audioSuffixes = [".\(fileExtension)", ".archive-damaged", ".archive-repair"]
        return Set(files.compactMap { name -> String? in
            guard name.hasPrefix(filePrefix), !name.hasSuffix(".bt.wav"),
                  let suffix = audioSuffixes.first(where: { name.hasSuffix($0) }) else { return nil }
            return String(name.dropLast(suffix.count))
        }).count
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
        guard let activityLease = try? RecordingActivity.shared.acquireReading(audioURL) else {
            DiagnosticLogger.shared.log("RecordingStore: finalization skipped for a recording claimed by maintenance")
            return
        }
        defer { activityLease.release() }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if keep {
            guard !AudioArchiveIntegrity.isInvalid(audioURL) else {
                DiagnosticLogger.shared.log("RecordingStore: invalid archive; not attaching a transcript to damaged audio")
                return
            }
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
            appendRecentIndexLocked(audioURL: audioURL)
            // M2: a kept recording adds one wav — bump the cached count (past the wav-exists guard
            // so a recording that vanished mid-finalize is never counted).
            bumpCachedCount(by: 1)
        } else {
            try? FileManager.default.removeItem(at: audioURL)
            AudioRecorder.discardRecoveryArtifacts(for: audioURL)
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
        ".archive-damaged", ".archive-repair", ".archive-invalid",
        ".builtin.raw.txt", ".bt.raw.txt", ".parakeet.txt", ".whisper.txt", ".raw.txt", ".edit.json", ".meta.json", ".bt.wav", ".wav", ".txt",
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

    /// Recoverable removal used by Settings and the corpus notice. Permanent deletion
    /// remains an internal compatibility API; no user-facing control invokes it.
    static func trashAllRecordings(
        progress: @escaping @Sendable (RecordingRemoval.Progress) -> Void = { _ in },
        trash: (URL) throws -> URL? = RecordingRemoval.systemTrash
    ) -> RecordingRemoval.Result {
        let removal = RecordingActivity.shared.beginRemoval(in: recordingsDir)
        defer { removal.finish() }
        let result = RecordingRemoval.run(directory: recordingsDir, activity: removal, progress: progress, trash: trash)
        AudioArchiveIntegrity.forgetMissingArchives(in: recordingsDir)
        invalidateCachedCount()
        // Drop the names of trashed takes from the recent-takes index.
        mutationLock.lock()
        filterRecentIndexLocked()
        mutationLock.unlock()
        return result
    }

    public struct DeletionResult: Sendable, Equatable {
        public let removedFiles: Int
        public let failedFiles: Int
        public let enumerationFailed: Bool
        public var succeeded: Bool { failedFiles == 0 && !enumerationFailed }

        public init(removedFiles: Int = 0, failedFiles: Int = 0, enumerationFailed: Bool = false) {
            self.removedFiles = removedFiles
            self.failedFiles = failedFiles
            self.enumerationFailed = enumerationFailed
        }
    }

    @discardableResult
    public static func deleteAllRecordings() -> DeletionResult {
        let removal = RecordingActivity.shared.beginRemoval(in: recordingsDir)
        defer { removal.finish() }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // M3 + orphan-sweep safety: enumerate names directly (no per-file sidecar opens) and remove
        // ONLY regular files that are EXACT recording artifacts — `recording-<timestamp>` plus a
        // known extension. Never recurse into directories and never match a foreign extension, so a
        // human-managed `recording-archive/` folder or a `recording-notes.pdf` survives. Never
        // touches the crash sentinel (it lives in configDir, not recordingsDir).
        let fm = FileManager.default
        var removed = 0
        var failed = 0
        do {
            let names = try fm.contentsOfDirectory(atPath: recordingsDir.path)
            for name in names where isRecordingArtifact(name) {
                let url = recordingsDir.appendingPathComponent(name)
                guard removal.claim(url) else { continue }
                // Regular files only — a directory whose name happens to match is never removed
                // (and never recursed into).
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                do {
                    if url.pathExtension == "archive-invalid" {
                        let audio = recordingsDir.appendingPathComponent(RecordingActivity.stem(for: url) + ".wav")
                        if fm.fileExists(atPath: audio.path) {
                            try fm.removeItem(at: audio)
                            removed += 1
                        }
                    }
                    try fm.removeItem(at: url)
                    let audio = recordingsDir.appendingPathComponent(RecordingActivity.stem(for: url) + ".wav")
                    if !fm.fileExists(atPath: audio.path) { AudioArchiveIntegrity.forget(audio) }
                    removed += 1
                } catch {
                    failed += 1
                    fputs("Warning: could not remove recording \(url.path): \(error.localizedDescription)\n", stderr)
                }
            }
        } catch {
            let failure = error as NSError
            // A missing directory is already empty. Permission and other read
            // failures are not evidence of absence and must never report success.
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                setCachedCount(0)
                return DeletionResult()
            }
            invalidateCachedCount()
            return DeletionResult(enumerationFailed: true)
        }
        // M2 / privacy: only zero the cached count when EVERY removal succeeded. A failed removal
        // leaves sensitive wavs on disk — invalidate instead so the next read rescans and Settings
        // keeps showing the survivors rather than reporting zero and hiding the folder controls.
        // Active/new groups can remain even when every eligible removal succeeded.
        invalidateCachedCount()
        // The recent-takes index holds only file names, but after Delete All it names nothing.
        try? fm.removeItem(at: recentIndexURL)
        return DeletionResult(removedFiles: removed, failedFiles: failed)
    }

    // MARK: - Recent-takes index (for `speakfree match`)

    /// Base names (`recording-<stamp>-<id>`, no extension) of kept takes, one per line, newest
    /// last. `speakfree match` runs on every prompt from a hook, and listing a real archive
    /// (80,000+ files) takes about half a second, so it reads this list instead. It holds file
    /// NAMES only, never transcript text. A deleted take fails to read and is skipped, and
    /// Delete All, trashing all recordings, and pruning also drop the removed names, so the
    /// list does not keep timestamps of takes that are gone. Lives inside the 0700 recordings
    /// folder. `match` uses it for look-backs up to `recentIndexDays`.
    public static var recentIndexURL: URL {
        recordingsDir.appendingPathComponent(recentIndexName)
    }
    public static let recentIndexName = "recent-takes.index"
    /// Compaction keeps this many newest names once the file grows past twice that.
    static let recentIndexKeepLines = 10_000
    /// The launch rebuild covers this many days; longer look-backs list the folder instead.
    public static let recentIndexDays = 30

    /// Add a take published outside `finishRecording` (crash recovery) to the index.
    public static func noteRecentTake(audioURL: URL) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        appendRecentIndexLocked(audioURL: audioURL)
    }

    /// Drop names from the index: the given ones (after pruning, cheap), or, with nil, every
    /// name whose recording no longer exists (after trashing all).
    static func filterRecentIndexLocked(removing removed: Set<String>? = nil) {
        guard let text = try? String(contentsOf: recentIndexURL, encoding: .utf8) else { return }
        let fm = FileManager.default
        let kept = text.split(separator: "\n").map(String.init).filter { base in
            if let removed { return !removed.contains(base) }
            return !base.contains("/") && fm.fileExists(atPath: recordingsDir.appendingPathComponent(base + ".wav").path)
        }
        if kept.isEmpty {
            try? fm.removeItem(at: recentIndexURL)
        } else {
            writeRecentIndex(kept)
        }
    }

    /// Append one kept take (called under `mutationLock` from `finishRecording`).
    static func appendRecentIndexLocked(audioURL: URL) {
        let base = audioURL.deletingPathExtension().lastPathComponent
        guard base.hasPrefix(filePrefix), !base.contains("\n") else { return }
        let path = recentIndexURL.path
        // Earlier takes reach the index through `rebuildRecentIndexIfMissing`, which the app runs
        // at launch and whenever settings are reloaded with saving on, off this lock.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let line = Array((base + "\n").utf8)
        _ = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var st = stat()
        let size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        close(fd)
        // ~40 bytes a line: compact once the file holds about twice the kept count.
        if size > recentIndexKeepLines * 2 * 40 {
            compactRecentIndexLocked()
        }
    }

    private static func compactRecentIndexLocked() {
        guard let text = try? String(contentsOf: recentIndexURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(recentIndexKeepLines)
        writeRecentIndex(lines.map(String.init))
    }

    private static func writeRecentIndex(_ bases: [String], in dir: URL? = nil) {
        let url = (dir ?? recordingsDir).appendingPathComponent(recentIndexName)
        let data = Data((bases.joined(separator: "\n") + (bases.isEmpty ? "" : "\n")).utf8)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Launch step: merge the folder's recent takes into the index (creating it on the first launch of a
    /// build that has it, or after Delete All), so takes from before still match. Runs off main.
    public static func rebuildRecentIndexIfMissing(days: Int = recentIndexDays, in folder: URL? = nil) {
        // Runs every launch (not only when the file is missing): merging the folder listing
        // back in also restores takes the user put back from the Trash after a trash-all.
        let dir = folder ?? recordingsDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        // List the folder (slow on a large archive) OUTSIDE the lock, so a dictation finishing
        // meanwhile is never held up; merge under it.
        let f = makeDateFormatter()
        let cutoff = f.string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        guard let bases = AgentCLI.recentRecordingBases(atPath: dir.path, cutoffStamp: cutoff) else { return }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let url = dir.appendingPathComponent(recentIndexName)
        let existing = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let merged = Set(bases).union(existing).sorted()
        writeRecentIndex(Array(merged.suffix(recentIndexKeepLines)), in: dir)
    }
}
