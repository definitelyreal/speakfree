// ai-suggestion:unverified · session:feat-agent-skills · 2026-09-24
import Foundation
import AVFoundation
import Darwin

/// Agent-facing command-line commands: `speakfree transcribe <file>`,
/// `speakfree history`, and `speakfree vocab`. Each prints exactly one JSON object on stdout and exit with a
/// documented code, so an AI assistant (a Claude Code or Codex skill, a script) can call
/// them without parsing prose. Contract documented in docs/AGENT-CLI.md; keep the two
/// in sync, and bump the schema string on any breaking change.
///
/// Guarantees:
/// - None of them uses the network. `transcribe` sets
///   `ParakeetModelManager.forbidNetwork()` before loading any engine, so even optional
///   model fetches fail instead of downloading.
/// - None of them writes the config file (read via `Config.loadWithoutCreating`). The only
///   file any of them writes is vocabulary.txt, and only for `vocab add` / `vocab remove`.
/// - `history` reads only the local recordings archive, only when the user has turned on
///   saving, and never follows a symlink out of it.
public enum AgentCLI {

    public static let transcribeSchema = "speakfree.transcribe.v1"
    public static let historySchema = "speakfree.history.v1"
    public static let vocabularySchema = "speakfree.vocabulary.v1"

    /// Documented exit codes. Stable: agents branch on these.
    public enum ExitCode: Int32 {
        case ok = 0
        case transcriptionFailed = 1
        case usage = 2
        case fileNotFound = 3
        case unreadableAudio = 4
        case modelNotReady = 5
        case historyDisabled = 6
        case historyUnreadable = 7
        case vocabularyWriteFailed = 8
    }

    /// What a command produced: the JSON text for stdout and the process exit code.
    public struct Output {
        public let json: String
        public let exitCode: Int32
    }

    // MARK: - JSON shapes

    struct ErrorBody: Encodable {
        let code: String
        let message: String
        let hint: String?
    }

    struct TranscribeSuccess: Encodable {
        let schema: String
        let ok: Bool
        let text: String
        let raw: String
        let engine: String
        let model: String
        let durationSeconds: Double
        let file: String
        let speakfreeVersion: String
        enum CodingKeys: String, CodingKey {
            case schema, ok, text, raw, engine, model, file
            case durationSeconds = "duration_seconds"
            case speakfreeVersion = "speakfree_version"
        }
    }

    struct Failure: Encodable {
        let schema: String
        let ok: Bool
        let error: ErrorBody
        let savingEnabled: Bool?
        enum CodingKeys: String, CodingKey {
            case schema, ok, error
            case savingEnabled = "saving_enabled"
        }
    }

    public struct HistoryEntry: Encodable, Equatable {
        public let time: String
        public let targetApp: String?
        public let text: String
        public let durationSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case time, text
            case targetApp = "target_app"
            case durationSeconds = "duration_seconds"
        }
    }

    struct HistorySuccess: Encodable {
        let schema: String
        let ok: Bool
        let savingEnabled: Bool
        let count: Int
        let limit: Int
        let app: String?
        let scanLimitReached: Bool
        let dictations: [HistoryEntry]
        enum CodingKeys: String, CodingKey {
            case schema, ok, count, limit, app, dictations
            case savingEnabled = "saving_enabled"
            case scanLimitReached = "scan_limit_reached"
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":{"code":"internal","message":"could not encode output"}}"#
        }
        return s
    }

    static func failure(_ schema: String, _ exit: ExitCode, code: String, message: String,
                        hint: String? = nil, savingEnabled: Bool? = nil) -> Output {
        Output(json: encode(Failure(schema: schema, ok: false,
                                    error: ErrorBody(code: code, message: message, hint: hint),
                                    savingEnabled: savingEnabled)),
               exitCode: exit.rawValue)
    }

    // MARK: - transcribe

    /// Dependencies of `transcribe`, injectable so tests never load a real speech model.
    public struct TranscribeEnvironment {
        public var loadConfig: () -> Config
        /// Engine id after the SPEAKFREE_ENGINE override: "parakeet" or "whisper".
        public var engineID: (Config) -> String
        /// nil when the model is ready; otherwise a user-facing hint for fixing it.
        public var modelProblem: (_ engine: String, _ model: String) -> String?
        public var run: (URL, Config) throws -> ProcessResult

        public static let live = TranscribeEnvironment(
            loadConfig: { Config.loadWithoutCreating().config },
            engineID: { config in
                let id = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"] ?? config.engine ?? "whisper"
                return id == "parakeet" ? "parakeet" : "whisper"
            },
            modelProblem: { engine, model in
                if engine == "parakeet" {
                    guard EngineCatalog.parakeetModels.contains(where: { $0.id == model }) else {
                        return "speakfree is set to an unknown model (\(model)). Pick a model in speakfree Settings."
                    }
                    return ParakeetModelManager.shared.isModelDownloaded(model)
                        ? nil : "Download it once with: speakfree download-parakeet \(model)"
                }
                if Transcriber.findWhisperBinary() == nil {
                    return "The Whisper engine needs whisper-cpp. Install it with: brew install whisper-cpp"
                }
                return Transcriber.modelExists(modelSize: model)
                    ? nil : "Download it once with: speakfree download-model \(model)"
            },
            run: { url, config in
                ParakeetModelManager.forbidNetwork()
                return try ProcessCommand.run(wavURL: url, config: config, useUserVocabulary: true)
            })
    }

    /// Longest input accepted, matching ProcessCommand's decode cap.
    static let maxDurationSeconds: Double = 60 * 60

    public static func transcribe(arguments: [String],
                                  environment env: TranscribeEnvironment = .live) -> Output {
        let schema = transcribeSchema
        guard arguments.count == 1, let rawPath = arguments.first, !rawPath.hasPrefix("-") else {
            return failure(schema, .usage, code: "usage",
                           message: "Usage: speakfree transcribe <audio-file>",
                           hint: "Pass exactly one audio file path (WAV, AIFF, M4A, MP3, or CAF).")
        }
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return failure(schema, .fileNotFound, code: "file_not_found",
                           message: "No audio file at \(url.path)")
        }

        let duration: Double
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            guard rate > 0 else { throw NSError(domain: "AgentCLI", code: 1) }
            duration = Double(file.length) / rate
        } catch {
            return failure(schema, .unreadableAudio, code: "unreadable_audio",
                           message: "Could not read \(url.lastPathComponent) as audio.",
                           hint: "Use WAV, AIFF, M4A, MP3, or CAF. To convert: afconvert -f WAVE -d LEI16@16000 <in> <out.wav>")
        }
        guard duration <= maxDurationSeconds else {
            return failure(schema, .unreadableAudio, code: "audio_too_long",
                           message: "Audio is \(Int(duration)) seconds; the limit is \(Int(maxDurationSeconds)) seconds.",
                           hint: "Split the file into pieces under 60 minutes.")
        }

        let config = env.loadConfig()
        let engine = env.engineID(config)
        let model = engine == "parakeet"
            ? (config.parakeetModel ?? "parakeet-tdt-0.6b-v3")
            : config.modelSize

        if engine == "whisper", url.pathExtension.lowercased() != "wav" {
            return failure(schema, .unreadableAudio, code: "unsupported_format",
                           message: "The Whisper engine reads only WAV files.",
                           hint: "Convert first: afconvert -f WAVE -d LEI16@16000 <in> <out.wav>")
        }
        if let problem = env.modelProblem(engine, model) {
            return failure(schema, .modelNotReady, code: "model_not_downloaded",
                           message: "The \(engine) model \(model) is not on this Mac, and this command never downloads.",
                           hint: problem)
        }

        let result: ProcessResult
        do {
            result = try env.run(url, config)
        } catch {
            if case TranscriptionEngineError.modelAssetsMissing = error {
                return failure(schema, .modelNotReady, code: "model_not_downloaded",
                               message: error.localizedDescription)
            }
            if case ProcessCommand.Error.transcriptionFailed(let inner) = error,
               case TranscriptionEngineError.modelAssetsMissing = inner {
                return failure(schema, .modelNotReady, code: "model_not_downloaded",
                               message: inner.localizedDescription)
            }
            return failure(schema, .transcriptionFailed, code: "transcription_failed",
                           message: error.localizedDescription)
        }

        let success = TranscribeSuccess(
            schema: schema, ok: true, text: result.styled, raw: result.raw,
            engine: engine, model: model,
            durationSeconds: (duration * 100).rounded() / 100,
            file: url.path, speakfreeVersion: SpeakFree.version)
        return Output(json: encode(success), exitCode: ExitCode.ok.rawValue)
    }

    // MARK: - history

    public static let defaultHistoryLimit = 5
    public static let maxHistoryLimit = 50
    /// Upper bound on archive entries examined per call, so a filter that matches nothing
    /// cannot turn one command into a scan of a 20,000-take archive.
    public static let historyScanCap = 2_000
    static let maxTranscriptBytes = 256 * 1024
    static let maxMetaBytes = 64 * 1024

    /// Filenames the app writes: recording-yyyy-MM-dd-HHmmss[-suffix].wav. Anything else in
    /// the folder, including the retired dual-capture `.bt.wav`, is ignored.
    static let recordingNamePattern = try! NSRegularExpression(
        pattern: #"^recording-(\d{4}-\d{2}-\d{2}-\d{6})(-[A-Za-z0-9]{1,36})?\.wav$"#)

    public static func history(arguments: [String],
                               devModeActive: Bool = DevMode.isActive,
                               timeZone: TimeZone = .current) -> Output {
        let schema = historySchema
        var limit = defaultHistoryLimit
        var app: String?
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--limit", "-n":
                guard i + 1 < arguments.count, let n = Int(arguments[i + 1]),
                      (1...maxHistoryLimit).contains(n) else {
                    return failure(schema, .usage, code: "usage",
                                   message: "--limit needs a number from 1 to \(maxHistoryLimit).")
                }
                limit = n
                i += 2
            case "--app":
                guard i + 1 < arguments.count, !arguments[i + 1].isEmpty,
                      !arguments[i + 1].hasPrefix("-") else {
                    return failure(schema, .usage, code: "usage",
                                   message: "--app needs an app bundle id, for example com.apple.mail.")
                }
                app = arguments[i + 1]
                i += 2
            default:
                return failure(schema, .usage, code: "usage",
                               message: "Usage: speakfree history [--limit N] [--app BUNDLE_ID]")
            }
        }

        // Same rule as DevMode.effectiveSaveRecordings, with dev mode injectable so tests
        // are not steered by a marker file in the developer's home folder.
        let config = Config.loadWithoutCreating().config
        guard devModeActive || (config.saveRecordings?.value ?? false) else {
            return failure(schema, .historyDisabled, code: "history_disabled",
                           message: "Saving dictations is turned off in speakfree, so there is no history to read. Nothing was read.",
                           hint: "To start keeping history on this Mac, open speakfree Settings and set Keep Recordings & Transcripts to anything other than Keep None. Only dictations made after that are saved.",
                           savingEnabled: false)
        }

        let dir = RecordingStore.recordingsDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            return Output(json: encode(HistorySuccess(
                schema: schema, ok: true, savingEnabled: true, count: 0, limit: limit, app: app,
                scanLimitReached: false, dictations: [])), exitCode: ExitCode.ok.rawValue)
        }
        guard isDir.boolValue, let names = RecordingStore.directoryEntryNames(atPath: dir.path) else {
            return failure(schema, .historyUnreadable, code: "history_unreadable",
                           message: "Could not read the recordings folder.", savingEnabled: true)
        }

        var candidates: [(name: String, stamp: String)] = []
        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            guard let m = recordingNamePattern.firstMatch(in: name, range: range),
                  let stampRange = Range(m.range(at: 1), in: name) else { continue }
            candidates.append((name, String(name[stampRange])))
        }
        candidates.sort { $0.name > $1.name }

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd-HHmmss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        // The app stamps filenames in the Mac's local time (RecordingStore's formatter), so
        // parse them in that zone; `time` is printed with its UTC offset.
        parser.timeZone = timeZone
        let printer = ISO8601DateFormatter()
        printer.formatOptions = [.withInternetDateTime]
        printer.timeZone = timeZone

        var entries: [HistoryEntry] = []
        var scanned = 0
        for candidate in candidates {
            if entries.count >= limit { break }
            if scanned >= historyScanCap { break }
            scanned += 1
            let base = String(candidate.name.dropLast(".wav".count))
            let meta = readConfined(dir: dir, name: base + ".meta.json", maxBytes: maxMetaBytes)
                .flatMap { try? JSONDecoder().decode(RecordingStore.RecordingMeta.self, from: $0) }
            if let app, meta?.targetApp?.lowercased() != app.lowercased() { continue }
            guard let textData = readConfined(dir: dir, name: base + ".txt", maxBytes: maxTranscriptBytes),
                  let text = String(data: textData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            // Prefer the sidecar's absolute ISO 8601 time; the filename stamp is local
            // wall-clock time and would be off after a time-zone change.
            guard let date = meta.flatMap({ Self.parseISODate($0.date) })
                    ?? parser.date(from: candidate.stamp) else { continue }
            entries.append(HistoryEntry(
                time: printer.string(from: date), targetApp: meta?.targetApp, text: text,
                durationSeconds: meta.map { ($0.durationSeconds * 10).rounded() / 10 }))
        }
        let capped = entries.count < limit && scanned >= historyScanCap
        return Output(json: encode(HistorySuccess(
            schema: schema, ok: true, savingEnabled: true, count: entries.count, limit: limit,
            app: app, scanLimitReached: capped, dictations: entries)),
            exitCode: ExitCode.ok.rawValue)
    }

    static func parseISODate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    /// Read `name` directly inside `dir`, refusing anything that could lead outside the
    /// archive: names with a path separator or dot-dot, symlinks (O_NOFOLLOW), and
    /// non-regular files. Returns nil on any refusal or error; never throws.
    static func readConfined(dir: URL, name: String, maxBytes: Int) -> Data? {
        guard !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else { return nil }
        let path = dir.appendingPathComponent(name).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0, st.st_size <= off_t(maxBytes) else { return nil }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return read(fd, base, buf.count)
        }
        guard n >= 0 else { return nil }
        return data.prefix(n)
    }

    // MARK: - vocab

    struct VocabularyResult: Encodable {
        let schema: String
        let ok: Bool
        let action: String
        let file: String
        let word: String?
        let changed: Bool?
        let existing: String?
        let count: Int
        let words: [String]
    }

    /// Longest word or phrase `vocab add` accepts. Vocabulary entries are names and short
    /// phrases; anything longer is almost certainly a mistake (a pasted sentence).
    static let maxVocabularyTermLength = 80

    /// Header the Settings "Edit Vocabulary File" button writes into a new file. Reused so a
    /// file created here looks the same as one created from Settings.
    static let vocabularyTemplate =
        "# Vocabulary for speakfree\n# One word or phrase per line.\n# Lines starting with # are ignored.\n"

    /// The terms in vocabulary.txt, in file order, parsed the way the app parses them
    /// (`Config.loadVocabulary`): inline ` # tag` comments stripped, blank and `#` lines skipped.
    static func vocabularyTerms(in content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { Config.stripInlineComment($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Why `term` cannot be added, or nil if it is acceptable.
    static func vocabularyTermProblem(_ term: String) -> String? {
        if term.isEmpty { return "The word is empty." }
        if term.count > maxVocabularyTermLength {
            return "The word is longer than \(maxVocabularyTermLength) characters. Add names and short phrases, one at a time."
        }
        if term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "The word contains a line break or control character."
        }
        if term.contains("#") {
            return "The word cannot contain #; vocabulary.txt uses it for comments."
        }
        if term.hasPrefix("-") {
            return "The word cannot start with -. To add a term that is not an option, leave off the dash."
        }
        return nil
    }

    public static func vocab(arguments: [String]) -> Output {
        let schema = vocabularySchema
        let usage = "Usage: speakfree vocab list | speakfree vocab add <word or phrase> | speakfree vocab remove <word or phrase>"
        guard let action = arguments.first else {
            return failure(schema, .usage, code: "usage", message: usage)
        }
        var rest = Array(arguments.dropFirst())
        if rest.first == "--" { rest.removeFirst() }  // conventional end of options
        switch action {
        case "list":
            guard rest.isEmpty else { return failure(schema, .usage, code: "usage", message: usage) }
            let file = Config.vocabularyFile
            let content = readVocabulary(file) ?? ""
            let words = vocabularyTerms(in: content)
            return Output(json: encode(VocabularyResult(
                schema: schema, ok: true, action: "list", file: file.path, word: nil, changed: nil,
                existing: nil, count: words.count, words: words)), exitCode: ExitCode.ok.rawValue)
        case "add", "remove":
            // Accept the phrase as one quoted argument or as several words ("vocab add Anya Taylor").
            let term = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return failure(schema, .usage, code: "usage", message: usage) }
            if action == "add", let problem = vocabularyTermProblem(term) {
                return failure(schema, .usage, code: "invalid_word", message: problem)
            }
            if term.isEmpty { return failure(schema, .usage, code: "invalid_word", message: "The word is empty.") }
            return editVocabulary(adding: action == "add", term: term)
        default:
            return failure(schema, .usage, code: "usage", message: usage)
        }
    }

    static func readVocabulary(_ file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    /// Add or remove one term, holding an exclusive lock so two agents editing at once cannot
    /// lose each other's change, and replacing the file atomically so the app never reads a
    /// half-written file. Other lines, comments, and tags are kept exactly as they were.
    static func editVocabulary(adding: Bool, term: String) -> Output {
        let schema = vocabularySchema
        let fm = FileManager.default
        let dir = Config.configDir
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return failure(schema, .vocabularyWriteFailed, code: "vocabulary_write_failed",
                           message: "Could not create \(dir.path): \(error.localizedDescription)")
        }
        guard let result = withVocabularyLock({ editVocabularyLocked(adding: adding, term: term) }) else {
            return failure(schema, .vocabularyWriteFailed, code: "vocabulary_write_failed",
                           message: "Could not lock the vocabulary file in \(dir.path).")
        }
        return result
    }

    /// Run `body` holding an exclusive lock on `.vocabulary.lock` in the config folder, so
    /// every writer of vocabulary.txt (this command, the app's vocabulary cleanup dialog via
    /// WordMemory) is serialized. With `timeout`, gives up after that many seconds instead of
    /// waiting forever (the app passes one so a stuck `vocab` process can never freeze its UI).
    /// Returns nil, without running `body`, if the lock cannot be taken.
    static func withVocabularyLock<T>(timeout: TimeInterval? = nil, _ body: () -> T) -> T? {
        let lockPath = Config.configDir.appendingPathComponent(".vocabulary.lock").path
        let lockFD = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { return nil }
        defer { close(lockFD) }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else { return nil }
                usleep(20_000)
            }
        } else {
            guard flock(lockFD, LOCK_EX) == 0 else { return nil }
        }
        defer { flock(lockFD, LOCK_UN) }
        return body()
    }

    private static func editVocabularyLocked(adding: Bool, term: String) -> Output {
        let schema = vocabularySchema
        let action = adding ? "add" : "remove"
        let fm = FileManager.default

        // Write through a symlink (a dotfiles-managed vocabulary.txt) instead of replacing it.
        let file = Config.vocabularyFile.resolvingSymlinksInPath()
        let exists = fm.fileExists(atPath: file.path)
        let original: String
        if exists {
            guard let text = readVocabulary(file) else {
                return failure(schema, .vocabularyWriteFailed, code: "vocabulary_unreadable",
                               message: "Could not read \(file.path) as UTF-8 text, so it was left unchanged.")
            }
            original = text
        } else {
            original = ""
        }
        let key = term.lowercased()
        // Keep the file's own line endings (a file edited on another system may use CRLF).
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        var lines = original.isEmpty ? [] : original.components(separatedBy: newline)
        // components(separatedBy:) yields a trailing "" for a file ending in a newline.
        if lines.last == "" { lines.removeLast() }
        func termOf(_ line: String) -> String? {
            let t = Config.stripInlineComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || t.hasPrefix("#")) ? nil : t
        }

        var changed = false
        var existing: String?
        if adding {
            if let match = lines.compactMap(termOf).first(where: { $0.lowercased() == key }) {
                existing = match
            } else {
                if !exists { lines = vocabularyTemplate.components(separatedBy: "\n").filter { !$0.isEmpty } }
                lines.append(term)
                changed = true
            }
        } else {
            let before = lines.count
            lines.removeAll { termOf($0)?.lowercased() == key }
            changed = lines.count != before
        }

        if changed {
            let updated = lines.joined(separator: newline) + newline
            // The atomic replace creates a new file; carry over the old file's permissions.
            let permissions = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions]
            do {
                try Data(updated.utf8).write(to: file, options: .atomic)
                if let permissions {
                    try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
                }
            } catch {
                return failure(schema, .vocabularyWriteFailed, code: "vocabulary_write_failed",
                               message: "Could not write \(file.path): \(error.localizedDescription)")
            }
        }
        let words = vocabularyTerms(in: changed ? lines.joined(separator: newline) : original)
        return Output(json: encode(VocabularyResult(
            schema: schema, ok: true, action: action, file: Config.vocabularyFile.path, word: term,
            changed: changed, existing: existing, count: words.count, words: words)),
            exitCode: ExitCode.ok.rawValue)
    }
}
