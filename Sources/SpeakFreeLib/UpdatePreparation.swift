// ai-suggestion:unverified · session:01a09da8-0424-7b71-a705-10868c5f46e4 · 2026-09-13
import AppKit
import Foundation
import Darwin

/// External legacy-app guard: observations are not an atomic capture-admission lease.
/// The caller must act immediately, request graceful exit, and never escalate to SIGKILL.
/// In compatibility mode, an explicit Install now click skips the quiet wait but still
/// requires no active dictation. Strict guarded installs additionally keep fresh
/// observations, a visible warning, a successful tone, and the warning countdown.
enum UpdateInstallNow {
    /// Deliberately ignores `changed` and staleness (an explicit choice); the app's own SIGTERM
    /// handler still waits for an in-flight dictation to finish before it exits.
    static func shouldProceed(requested: Bool, dictationActive: Bool) -> Bool {
        requested && !dictationActive
    }
}

struct UpdateQuietPolicy {
    enum Decision: Equatable {
        case waiting(Int), warning(Int, playTone: Bool), ready, timedOut
    }
    let startedAt: TimeInterval
    let timeout: TimeInterval
    private(set) var quietSince: TimeInterval?
    private(set) var warningSince: TimeInterval?

    mutating func observe(now: TimeInterval, active: Bool, changed: Bool,
                          observedAt: TimeInterval? = nil, skipQuietWait: Bool = false) -> Decision {
        guard now - startedAt < timeout else { return .timedOut }
        let stale = observedAt.map { !$0.isFinite || $0 > now || now - $0 > 2 } ?? false
        if active || changed || stale {
            quietSince = nil
            warningSince = nil
            return .waiting(30)
        }
        if quietSince == nil { quietSince = now }
        let quietRemaining = skipQuietWait ? 0 : 30 - (now - quietSince!)
        if quietRemaining > 0 { return .waiting(Int(ceil(quietRemaining))) }
        if warningSince == nil {
            warningSince = now
            return .warning(5, playTone: true)
        }
        let warningRemaining = 5 - (now - warningSince!)
        if warningRemaining > 0 { return .warning(Int(ceil(warningRemaining)), playTone: false) }
        return .ready
    }
}

/// A strict parser for bounded startup history and newly appended lines. Never returns or prints message bodies.
/// Prefixes come from DiagnosticLogger, AudioRecorder, AppDelegate and HotkeyManager.
enum UpdateLogEvent {
    case sessionStarted, captureStarted, captureStopped, activity, unrelated, unsupported
    static func classify(_ line: String) -> UpdateLogEvent {
        guard line.range(of: #"^\[[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\] "#,
                         options: .regularExpression) != nil else { return .unsupported }
        let message = String(line.dropFirst(11))
        if message.hasPrefix("Session started — ") { return .sessionStarted }
        if message.hasPrefix("AudioRecorder: recording started,") { return .captureStarted }
        if message.hasPrefix("AudioRecorder: recording stopped,") { return .captureStopped }
        let activityPrefixes = [
            "AudioRecorder: recording ", "Recording ", "Finalize:", "Transcription ",
            "Streaming:", "WATCHDOG:", "Gate override:", "Insertion boundary:",
            "SecureInputRetry:", "HotkeyManager:", "SIGTERM:", "Recovery:",
            "Capture: WAV write failed:", "Parakeet model not downloaded", "Transcriber configured:",
            // Added 2026-09-24 after a real install was blocked by "Capture route: ... dictation:"
            // and "Reprocess: ... recent dictation" lines. The prefixes here are activity (they
            // restart the quiet wait); "Capture route:" is classified unrelated below. Capture
            // boundaries still come only from the recorder lines and the in-progress sentinel.
            // UpdateLogCoverageTests keeps this list complete.
            "Reprocess:", "WhisperEngine:", "RecordingStore:", "Recordings removal:",
            "Terminate:", "Capture: restarting streams",
            // The retired AirPods "Dictation Mode" menu toggle (replaced by Stay on, 2026-09-24)
            // can still appear in startup history. A user action, so it counts as activity
            // (restarts the quiet wait); never a capture boundary.
            "Dictation Mode:",
            // Multi-line log calls the coverage test missed until 2026-09-24: the streaming-
            // reuse finalize note and the recording overlay's backdrop fallback. Both happen
            // around a take, so they are activity.
            "T2.3:", "Overlay:",
            // dogfood's armed pre-roll note (right after "recording started") and the per-take
            // "Latency:" record written at insertion: both belong to a take.
            "AudioRecorder: kept ", "Latency: ",
            // Stay on static switch (2026-09-25): capture left the headset for the Mac's mic,
            // mid-take or at its start. It belongs to a take, so it restarts the quiet wait.
            "Capture switch:"
        ]
        if activityPrefixes.contains(where: message.hasPrefix) { return .activity }
        // Periodic health checks describe subsystem health, not a dictation boundary.
        if message.hasPrefix("Health check:") { return .unrelated }
        // Route and notice status lines describe configuration, not a dictation boundary.
        if message.hasPrefix("Capture route:") || message.hasPrefix("RecordingsNotice:") || message.hasPrefix("Stay on notice:")
            || message.hasPrefix("Report a Problem:") || message.hasPrefix("DictationTrace:") { return .unrelated }
        // The user's own Cmd+V put the clipboard back (or was left alone): clipboard
        // bookkeeping after an insertion, not a capture boundary (2026-09-24).
        if message.hasPrefix("Clipboard restore: trigger=user-paste ") { return .unrelated }
        // The clipboard canary and trust checks run only while nothing is being captured
        // (screen locked or idle, never during a take): never a capture boundary (2026-09-25).
        if message.hasPrefix("Clipboard trust: ") { return .unrelated }
        // Legacy 3143a81 StatusBarController emits these menu/cache timing records.
        // They describe a read-only UI refresh, not capture or a recovery attempt.
        // Match the complete known numeric formats; unfamiliar history events stay unknown.
        if message.range(of: #"^Recent Dictations: (?:rendered cached menu in -?[0-9]+\.[0-9]+ ms|refreshed [0-9]+-item cache in -?[0-9]+\.[0-9]+ ms)$"#,
                         options: .regularExpression) != nil { return .unrelated }
        // The legacy config snapshot contains saveRecordings/streaming fields, and
        // pre-recording health is itself a capture-attempt signal. These known control
        // events restart quiet; they never establish an idle capture boundary.
        if message.range(of: #"^Config: engine=.+ model=.+ parakeetModel=.+ input=.+ punctuation=.+ streaming=(?:true|false) preBuffer=(?:true|false) keepLoaded=.+ saveRecordings=(?:true|false) screenContext=(?:true|false) language=.+$"#,
                         options: .regularExpression) != nil
            || message == "Config: reload deferred — dictation or edit session in flight"
            || message == "Config: applying deferred reload — dictation finished"
            || message == "Config: legacy default cap cleared in-memory — recordings will not be auto-pruned (persists on next Settings save)"
            || message == "Health check (pre-recording): permissions and controls OK; audio recovery checked asynchronously"
            || message.hasPrefix("Health check (pre-recording): ISSUES — ") { return .activity }
        let keywords = ["recording", "dictation", "transcription", "finalize", "streaming", "key-down", "key-up"]
        if keywords.contains(where: message.lowercased().contains) { return .unsupported }
        return .unrelated
    }
}

struct UpdateActivitySnapshot {
    let active: Bool
    let changed: Bool
}

/// PID alone is reusable. Match executable, effective owner and kernel start time.
struct LiveUpdateProcess: Hashable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static let installedExecutable = "/Applications/speakfree.app/Contents/MacOS/speakfree"

    static func running(executablePath: String = installedExecutable) throws -> Set<LiveUpdateProcess> {
        let required = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, executablePath, 0, nil, 0)
        guard required >= 0, required <= 16_384 else { throw LegacyUpdateActivityObserver.Failure.unavailable }
        var pids = [Int32](repeating: 0, count: max(64, Int(required) / 4 + 64))
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, executablePath, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes >= 0, bytes < pids.count * 4, bytes % 4 == 0 else {
            throw LegacyUpdateActivityObserver.Failure.unavailable
        }
        var result = Set<LiveUpdateProcess>()
        for pid in pids.prefix(Int(bytes) / 4) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                throw LegacyUpdateActivityObserver.Failure.unavailable
            }
            // Other tools can have the executable open without executing it.
            guard String(cString: path) == executablePath else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == geteuid(), info.pbi_pid == UInt32(pid) else {
                throw LegacyUpdateActivityObserver.Failure.unavailable
            }
            result.insert(LiveUpdateProcess(pid: pid, startedSeconds: info.pbi_start_tvsec,
                                            startedMicroseconds: info.pbi_start_tvusec))
        }
        return result
    }
}

/// Worker-confined observer. No audio/transcript/config bodies are read or printed.
/// Startup replay is limited to live process identities and at most 1 MiB of log text.
final class LegacyUpdateActivityObserver {
    enum Failure: Error { case unavailable, unsupportedLog, logBacklog }
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private struct LogCursor {
        var offset: UInt64
        var pending = Data()
        let inode: UInt64
    }
    private struct Session {
        let primary: String
        let filesNewestFirst: [String]
    }
    private let directory: URL
    private let liveProcesses: () throws -> Set<LiveUpdateProcess>
    private var identities: Set<LiveUpdateProcess>?
    private var recordings: [String: Stamp]?
    private var recordingNames: [String] = []
    private var listingStamp: Stamp?
    static let recentFileLimit = 256
    static let replayByteLimit = 1_048_576
    private(set) var recordingStatCount = 0
    private(set) var recordingListingCount = 0
    private var logCursors: [String: LogCursor] = [:]
    private var activeCaptureLogs = Set<String>()

    init(directory: URL, liveProcesses: @escaping () throws -> Set<LiveUpdateProcess> = {
        try LiveUpdateProcess.running()
    }) {
        self.directory = directory
        self.liveProcesses = liveProcesses
    }

    private func stamp(_ url: URL, directory: Bool = false) throws -> Stamp {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else { throw Failure.unavailable }
        return Stamp(size: size.uint64Value, modified: date, inode: inode.uint64Value)
    }

    private func sentinelExists() throws -> Bool {
        let path = directory.appendingPathComponent(".recording-in-progress.json").path
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.unavailable }
        return false
    }

    /// DiagnosticLogger names include its process PID and session creation time. Excluding
    /// names predating the kernel process start prevents an old PID's crash from poisoning
    /// the new process's state. Ambiguous multiple sessions for one live PID fail closed.
    private func sessions(in names: [String], processes: Set<LiveUpdateProcess>) throws -> [Session] {
        let expression = try NSRegularExpression(pattern:
            #"^speakfree-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)-(\d+)-([A-Fa-f0-9]{8})(?:\.(older|previous))?\.log$"#)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        var primaryByPID: [Int32: [String]] = [:]
        for name in names {
            guard let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let pidRange = Range(match.range(at: 2), in: name),
                  let timeRange = Range(match.range(at: 1), in: name),
                  let pid = Int32(name[pidRange]),
                  let process = processes.first(where: { $0.pid == pid }),
                  let date = dateFormatter.date(from: String(name[timeRange])),
                  date.timeIntervalSince1970 >= Double(process.startedSeconds),
                  match.range(at: 4).location == NSNotFound else { continue }
            primaryByPID[pid, default: []].append(name)
        }
        let available = Set(names)
        return try processes.map { process in
            guard let candidates = primaryByPID[process.pid], candidates.count == 1,
                  let primary = candidates.first else { throw Failure.unavailable }
            let base = String(primary.dropLast(4))
            return Session(primary: primary, filesNewestFirst:
                [primary, base + ".previous.log", base + ".older.log"].filter { available.contains($0) })
        }
    }

    /// Read backwards until a definitive capture boundary or process session-start is found.
    /// If rotation/history truncation hides that boundary, absence is UNKNOWN, not idle.
    private func bootstrap(_ session: Session, in logDir: URL) throws -> (active: Bool, cursor: LogCursor) {
        var remaining = Self.replayByteLimit
        var primaryCursor: LogCursor?
        for (index, name) in session.filesNewestFirst.enumerated() {
            let url = logDir.appendingPathComponent(name)
            let before = try stamp(url)
            guard remaining > 0 else { throw Failure.logBacklog }
            let start = before.size > UInt64(remaining) ? before.size - UInt64(remaining) : 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(before.size - start)) ?? Data()
            guard data.count == Int(before.size - start), try stamp(url) == before else { throw Failure.unavailable }
            remaining -= data.count
            var lines = data.split(separator: 10, omittingEmptySubsequences: false)
            if start > 0, !lines.isEmpty { lines.removeFirst() } // initial fragment is not a complete record
            let partial = lines.popLast().map { Data($0) } ?? Data()
            if index == 0 {
                primaryCursor = LogCursor(offset: before.size, pending: partial, inode: before.inode)
            } else if !partial.isEmpty {
                throw Failure.unsupportedLog // closed rotation must end at a complete line
            }
            for bytes in lines.reversed() {
                guard let line = String(data: Data(bytes), encoding: .utf8) else { throw Failure.unsupportedLog }
                let active: Bool
                switch UpdateLogEvent.classify(line) {
                case .captureStarted: active = true
                case .captureStopped, .sessionStarted: active = false
                case .activity, .unrelated: continue
                case .unsupported: throw Failure.unsupportedLog
                }
                guard let cursor = primaryCursor else { throw Failure.unavailable }
                return (active, cursor)
            }
            if start > 0 { throw Failure.logBacklog }
        }
        throw Failure.unavailable
    }

    func snapshot() throws -> UpdateActivitySnapshot {
        let processes = try liveProcesses()
        guard !processes.isEmpty else { throw Failure.unavailable }
        let identityChanged = identities.map { $0 != processes } ?? false
        if identityChanged { logCursors = [:]; activeCaptureLogs = [] }
        _ = try stamp(directory, directory: true)
        let activeBefore = try sentinelExists()
        let recordingDir = directory.appendingPathComponent("recordings")
        let logDir = directory.appendingPathComponent("logs")
        let directoryBefore = try stamp(recordingDir, directory: true)
        _ = try stamp(logDir, directory: true)
        if listingStamp != directoryBefore {
            // Names only (POSIX readdir). FileManager.contentsOfDirectory does per-entry metadata
            // work that took tens of seconds on an 83,000-file folder and re-ran after every
            // dictation, so the update prompt appeared stuck (2026-09-24).
            guard let names = RecordingStore.directoryEntryNames(atPath: recordingDir.path) else {
                throw Failure.unavailable
            }
            recordingNames = Array(names.filter { $0.hasPrefix("recording-") }.sorted(by: >)
                .prefix(Self.recentFileLimit))
            listingStamp = directoryBefore
            recordingListingCount += 1
        }
        var next: [String: Stamp] = ["directory": directoryBefore]
        recordingStatCount = 0
        for name in recordingNames {
            next[name] = try stamp(recordingDir.appendingPathComponent(name))
            recordingStatCount += 1
        }
        var changed = identityChanged || (recordings.map { $0 != next } ?? false)
        recordings = next
        let selected = try sessions(in: FileManager.default.contentsOfDirectory(atPath: logDir.path), processes: processes)
        let selectedNames = Set(selected.map(\.primary))
        if identities != nil && Set(logCursors.keys) != selectedNames { changed = true }
        logCursors = logCursors.filter { selectedNames.contains($0.key) }
        activeCaptureLogs.formIntersection(selectedNames)
        for session in selected {
            let name = session.primary
            let url = logDir.appendingPathComponent(name)
            let before = try stamp(url)
            var cursor: LogCursor
            if let old = logCursors[name], old.inode == before.inode, old.offset <= before.size {
                cursor = old
            } else {
                let initial = try bootstrap(session, in: logDir)
                cursor = initial.cursor
                if initial.active { activeCaptureLogs.insert(name) } else { activeCaptureLogs.remove(name) }
                if identities != nil { changed = true }
            }
            guard cursor.offset <= before.size,
                  before.size - cursor.offset <= Self.replayByteLimit else { throw Failure.logBacklog }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: cursor.offset)
            let data = try handle.read(upToCount: Self.replayByteLimit + 1) ?? Data()
            guard data.count <= Self.replayByteLimit else { throw Failure.logBacklog }
            cursor.offset += UInt64(data.count)
            cursor.pending.append(data)
            guard cursor.pending.count <= Self.replayByteLimit else { throw Failure.logBacklog }
            while let newline = cursor.pending.firstIndex(of: 10) {
                let bytes = cursor.pending.prefix(upTo: newline)
                guard let line = String(data: bytes, encoding: .utf8) else { throw Failure.unsupportedLog }
                switch UpdateLogEvent.classify(line) {
                case .captureStarted: activeCaptureLogs.insert(name); changed = true
                case .captureStopped: activeCaptureLogs.remove(name); changed = true
                case .sessionStarted: throw Failure.unsupportedLog // unexpected reset of a live session
                case .activity: changed = true
                case .unrelated: break
                case .unsupported: throw Failure.unsupportedLog
                }
                cursor.pending.removeSubrange(...newline)
            }
            if !cursor.pending.isEmpty { changed = true }
            if try stamp(url) != before { changed = true }
            logCursors[name] = cursor
        }
        let activeAfter = try sentinelExists()
        if try stamp(recordingDir, directory: true) != directoryBefore { changed = true }
        guard try liveProcesses() == processes else { throw Failure.unavailable }
        identities = processes
        return UpdateActivitySnapshot(active: activeBefore || activeAfter || !activeCaptureLogs.isEmpty, changed: changed)
    }
}

/// How the update prompt presents itself, decided once at start.
/// Guarded agent installs additionally require a visible warning and successful tone. The
/// compatibility behavior below applies only when --require-visible-warning is absent.
///
/// - `.panel`: someone can see the screen. Show the panel (Cancel, Install now ») and play the
///   tone, exactly as before. If the screen locks or sleeps mid-wait, the wait simply goes on.
/// - `.quiet`: no GUI session is reachable from this process (a locked screen, no console user,
///   or an ssh session, which has no window-server connection: fleet installs on the other Macs
///   are always quiet, even with someone at them). A display that is merely asleep but unlocked
///   still counts as `.panel` (the tone may play to nobody, which is harmless). No panel, no
///   tone, and no AppKit event loop at all: proceed
///   on the quiet rule alone (no active dictation, then 30 s with none, then the 5 s warning
///   interval; new activity restarts both). Uncertain activity, timeout, or a failed stop still
///   abort; nothing ever escalates to SIGKILL.
enum UpdateWarningMode: Equatable {
    case panel, quiet
    static func atStart(consoleAvailable: Bool) -> UpdateWarningMode { consoleAvailable ? .panel : .quiet }
}

enum UpdateConsole {
    /// Strict agent installs must also have an awake display; an unlocked sleeping session
    /// cannot supply the required visible warning. Uncertainty is a refusal, never a bypass.
    static func visible() -> Bool {
        let display = CGMainDisplayID()
        return available() && display != kCGNullDirectDisplay
            && CGDisplayIsActive(display) != 0 && CGDisplayIsAsleep(display) == 0
    }

    /// True when this user's session is on the console, logged in, and the screen is unlocked.
    static func available() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue == true,
              (session[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == geteuid(),
              (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true else { return false }
        return true
    }
}

/// Runs only for the explicit prepare-update command; does not construct AppDelegate,
/// open a microphone, change routes, signal another process, or alter recording files.
public enum UpdatePreparation {
    struct Options: Equatable {
        var timeout: TimeInterval = 600
        var requireVisibleWarning = false

        static func parse(_ arguments: [String]) -> Options? {
            var options = Options()
            var sawTimeout = false
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--require-visible-warning" where !options.requireVisibleWarning:
                    options.requireVisibleWarning = true
                case "--timeout" where !sawTimeout:
                    index += 1
                    guard index < arguments.count, let value = Double(arguments[index]),
                          value.isFinite, (60...3600).contains(value) else { return nil }
                    options.timeout = value
                    sawTimeout = true
                default:
                    return nil
                }
                index += 1
            }
            return options
        }
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let options = Options.parse(arguments) else {
            fputs("Usage: speakfree prepare-update [--timeout 60...3600] [--require-visible-warning]\n", stderr)
            return 64
        }
        guard Thread.isMainThread else { return 4 }
        let consoleAvailable = options.requireVisibleWarning ? UpdateConsole.visible : UpdateConsole.available
        let observer = LegacyUpdateActivityObserver(directory: Config.configDir)
        let controller = UpdatePreparationController(
            timeout: options.timeout,
            mode: .atStart(consoleAvailable: consoleAvailable()),
            requireVisibleWarning: options.requireVisibleWarning,
            observe: { try observer.snapshot() },
            consoleAvailable: consoleAvailable)
        return controller.runToCompletion()
    }
}

final class UpdatePreparationController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let mode: UpdateWarningMode
    private let requireVisibleWarning: Bool
    private let warningVisible: (() -> Bool)?
    private let playWarningTone: (() -> Bool)?
    private var running = false
    private let observe: () throws -> UpdateActivitySnapshot
    private let consoleAvailable: () -> Bool
    private let clock: () -> TimeInterval
    private let tickInterval: TimeInterval
    private let report: (Int32, String) -> Void
    private let worker = DispatchQueue(label: "com.speakfree.prepare-update", qos: .utility)
    private var policy: UpdateQuietPolicy
    private var timer: Timer?
    private var scanning = false
    private var lastScanAt: TimeInterval = -.infinity
    private var panel: NSPanel?
    private var label: NSTextField?
    private var sound: NSSound?
    private var installNowRequested = false
    private var warningToneStarted = false
    private(set) var result: Int32?

    /// Tests run the quiet loop, or drive apply directly with fake visibility and tone
    /// providers. Neither path shows a window or plays a real sound.
    init(timeout: TimeInterval, mode: UpdateWarningMode,
         requireVisibleWarning: Bool = false,
         observe: @escaping () throws -> UpdateActivitySnapshot,
         consoleAvailable: @escaping () -> Bool = UpdateConsole.available,
         warningVisible: (() -> Bool)? = nil,
         playWarningTone: (() -> Bool)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         tickInterval: TimeInterval = 0.25,
         report: @escaping (Int32, String) -> Void = { code, message in
             if code == 0 { print(message) } else { fputs(message + "\n", stderr) }
         }) {
        self.mode = mode
        self.requireVisibleWarning = requireVisibleWarning
        self.warningVisible = warningVisible
        self.playWarningTone = playWarningTone
        self.observe = observe
        self.consoleAvailable = consoleAvailable
        self.clock = clock
        self.tickInterval = tickInterval
        self.report = report
        policy = UpdateQuietPolicy(startedAt: clock(), timeout: timeout)
    }

    /// Main thread. Runs until a result and returns the exit code.
    func runToCompletion() -> Int32 {
        if requireVisibleWarning && (mode != .panel || !consoleAvailable()) {
            finish(4, message: "Update blocked: a visible console session is required; app left running.")
            return result ?? 4
        }
        running = true
        defer { running = false }
        switch mode {
        case .panel:
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.delegate = self
            start()
            if result == nil { app.run() }
        case .quiet:
            fputs("No screen session is reachable from here (locked screen, no console user, or ssh). "
                  + "Waiting for no dictation and 30 seconds of quiet, without a visible warning.\n", stderr)
            start()
            if result == nil { CFRunLoopRun() }
        }
        return result ?? 4
    }

    private func start() {
        if mode == .panel { showPanel() }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Let AppKit publish the ordered panel's occlusion state before the strict visibility
        // check. No quiet time accrues until the first timer observation confirms visibility.
        if !requireVisibleWarning { tick() }
    }

    private func showPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 160),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "SpeakFree update"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let label = NSTextField(wrappingLabelWithString:
            "Waiting for dictation to finish, then 30 seconds of quiet. Install now, keep dictating, or cancel this update.")
        label.frame = NSRect(x: 24, y: 63, width: 382, height: 76)
        panel.contentView?.addSubview(label)
        // Cancel on the left, "Install now »" on the right with clear space between them
        let cancel = NSButton(title: "Cancel update", target: self, action: #selector(cancelUpdate))
        cancel.frame = NSRect(x: 24, y: 19, width: 141, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(cancel)
        let installNow = NSButton(title: "Install now \u{00BB}", target: self, action: #selector(installNow))
        installNow.frame = NSRect(x: 265, y: 19, width: 141, height: 32)
        installNow.keyEquivalent = "\r"
        panel.contentView?.addSubview(installNow)
        self.panel = panel
        self.label = label
        panel.center()
        panel.orderFrontRegardless()
    }

    private func tick() {
        guard result == nil else { return }
        let now = clock()
        guard now - policy.startedAt < policy.timeout else { finish(3, message: "Update canceled: quiet-period timeout."); return }
        guard checkRequiredVisibility() else { return }
        guard !scanning, now - lastScanAt >= 1 else { return }
        scanning = true
        lastScanAt = now
        worker.async { [weak self] in
            guard let self else { return }
            let observation = Result { try self.observe() }
            let completedAt = self.clock()
            DispatchQueue.main.async {
                self.scanning = false
                guard self.result == nil else { return }
                switch observation {
                case .failure:
                    self.finish(4, message: "Update blocked: activity could not be established safely.")
                case .success(let snapshot):
                    self.apply(snapshot, observedAt: completedAt)
                }
            }
        }
    }

    // Internal so tests can drive observations with an injected clock/visibility/tone without
    // starting AppKit, showing a window, playing sound, or reading actual capture state.
    func apply(_ snapshot: UpdateActivitySnapshot, observedAt: TimeInterval) {
        guard result == nil, checkRequiredVisibility() else { return }
        if !requireVisibleWarning,
           UpdateInstallNow.shouldProceed(requested: installNowRequested, dictationActive: snapshot.active) {
            finish(0, message: "SPEAKFREE_UPDATE_READY")
            return
        }
        if installNowRequested && !requireVisibleWarning {
            label?.stringValue = "Dictation is active. The update will install as soon as it ends."
            return
        }
        switch policy.observe(now: clock(), active: snapshot.active,
                              changed: snapshot.changed, observedAt: observedAt,
                              skipQuietWait: installNowRequested) {
        case .waiting(let seconds):
            warningToneStarted = false
            sound?.stop()
            label?.stringValue = snapshot.active
                ? "Dictation is active. The update will wait. You can keep dictating or cancel."
                : installNowRequested
                    ? "Checking that dictation has finished before the update warning. You can cancel below."
                    : "Waiting for \(seconds) more seconds of quiet before the update warning. You can keep dictating or cancel."
        case .warning(let seconds, let playTone):
            label?.stringValue = "SpeakFree will pause for an update in \(seconds) seconds. Start dictating to postpone, or cancel below."
            if playTone, mode == .panel, requireVisibleWarning || consoleAvailable() {
                warningToneStarted = startWarningTone()
                if !warningToneStarted {
                    if requireVisibleWarning {
                        finish(4, message: "Update blocked: the required warning tone could not start; app left running.")
                        return
                    }
                    fputs("Update warning tone could not start; continuing on the quiet rule.\n", stderr)
                }
                panel?.orderFrontRegardless()
            }
        case .ready:
            guard !requireVisibleWarning || warningToneStarted else {
                finish(4, message: "Update blocked: the required warning tone was not played; app left running.")
                return
            }
            // This receipt is only an external observation, not a lock on the old app.
            finish(0, message: "SPEAKFREE_UPDATE_READY")
        case .timedOut:
            finish(3, message: "Update canceled: quiet-period timeout.")
        }
    }

    private func checkRequiredVisibility() -> Bool {
        guard requireVisibleWarning else { return true }
        let visible = warningVisible?() ?? (panel?.isVisible == true && panel?.occlusionState.contains(.visible) == true)
        guard mode == .panel, consoleAvailable(), visible else {
            finish(4, message: "Update blocked: the required warning is no longer visible; app left running.")
            return false
        }
        return true
    }

    private func startWarningTone() -> Bool {
        if let playWarningTone { return playWarningTone() }
        guard let sound = NSSound(named: NSSound.Name("Glass")), sound.play() else { return false }
        self.sound = sound
        return true
    }

    @objc func cancelUpdate() { finish(2, message: "Update canceled by user.") }
    @objc func installNow() {
        guard result == nil else { return }
        installNowRequested = true
        label?.stringValue = requireVisibleWarning
            ? "Starting the update warning as soon as no dictation is in progress."
            : "Installing now, as soon as no dictation is in progress."
        lastScanAt = -.infinity  // observe right away instead of on the next 1 s scan
        if running { tick() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelUpdate(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancelUpdate()
        return .terminateCancel
    }
    private func finish(_ code: Int32, message: String) {
        guard result == nil else { return }
        result = code
        timer?.invalidate()
        timer = nil
        sound?.stop()
        panel?.orderOut(nil)
        report(code, message)
        guard running else { return }
        switch mode {
        case .panel:
            NSApp.stop(nil)
            // stop() takes effect after the current event; wake a quiet run loop as well.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
        case .quiet:
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
}
