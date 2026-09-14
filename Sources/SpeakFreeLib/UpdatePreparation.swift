// ai-suggestion:unverified · session:01a09da8-0424-7b71-a705-10868c5f46e4 · 2026-09-13
import AppKit
import Foundation
import Darwin

/// External legacy-app guard: observations are not an atomic capture-admission lease.
/// The caller must act immediately, request graceful exit, and never escalate to SIGKILL.
struct UpdateQuietPolicy {
    enum Decision: Equatable {
        case waiting(Int), warning(Int, playTone: Bool), ready, timedOut
    }
    let startedAt: TimeInterval
    let timeout: TimeInterval
    private(set) var quietSince: TimeInterval?
    private(set) var warningSince: TimeInterval?

    mutating func observe(now: TimeInterval, active: Bool, changed: Bool,
                          observedAt: TimeInterval? = nil) -> Decision {
        guard now - startedAt < timeout else { return .timedOut }
        let stale = observedAt.map { !$0.isFinite || $0 > now || now - $0 > 2 } ?? false
        if active || changed || stale {
            quietSince = nil
            warningSince = nil
            return .waiting(30)
        }
        if quietSince == nil { quietSince = now }
        let quietRemaining = 30 - (now - quietSince!)
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
            "Capture: WAV write failed:", "Parakeet model not downloaded", "Transcriber configured:"
        ]
        if activityPrefixes.contains(where: message.hasPrefix) { return .activity }
        // Periodic health checks describe subsystem health, not a dictation boundary.
        if message.hasPrefix("Health check:") { return .unrelated }
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
            recordingNames = Array(try FileManager.default.contentsOfDirectory(atPath: recordingDir.path)
                .filter { $0.hasPrefix("recording-") }.sorted(by: >).prefix(Self.recentFileLimit))
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

/// Runs only for the explicit prepare-update command; does not construct AppDelegate,
/// open a microphone, change routes, signal another process, or alter recording files.
public enum UpdatePreparation {
    public static func run(arguments: [String]) -> Int32 {
        var timeout: TimeInterval = 600
        if !arguments.isEmpty {
            guard arguments.count == 2, arguments[0] == "--timeout",
                  let value = Double(arguments[1]), value.isFinite, (60...3600).contains(value) else {
                fputs("Usage: speakfree prepare-update [--timeout 60...3600]\n", stderr)
                return 64
            }
            timeout = value
        }
        guard Thread.isMainThread else { return 4 }
        let app = NSApplication.shared
        let controller = UpdatePreparationController(directory: Config.configDir, timeout: timeout)
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        controller.start()
        if controller.result == nil { app.run() }
        return controller.result ?? 4
    }
}

private final class UpdatePreparationController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let observer: LegacyUpdateActivityObserver
    private let worker = DispatchQueue(label: "com.speakfree.prepare-update", qos: .utility)
    private var policy: UpdateQuietPolicy
    private var timer: Timer?
    private var scanning = false
    private var lastScanAt: TimeInterval = -.infinity
    private var panel: NSPanel?
    private var label: NSTextField?
    private var sound: NSSound?
    private(set) var result: Int32?

    init(directory: URL, timeout: TimeInterval) {
        observer = LegacyUpdateActivityObserver(directory: directory)
        policy = UpdateQuietPolicy(startedAt: ProcessInfo.processInfo.systemUptime, timeout: timeout)
    }

    private func consoleAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue == true,
              (session[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == geteuid(),
              (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true else { return false }
        return true
    }

    func start() {
        guard consoleAvailable() else { finish(4, message: "Update blocked: visible console session unavailable."); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 160),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "SpeakFree update"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let label = NSTextField(wrappingLabelWithString: "Waiting for dictation to finish, then 30 seconds of quiet. You can keep dictating or cancel this update.")
        label.frame = NSRect(x: 24, y: 63, width: 382, height: 76)
        panel.contentView?.addSubview(label)
        let cancel = NSButton(title: "Cancel update", target: self, action: #selector(cancelUpdate))
        cancel.frame = NSRect(x: 265, y: 19, width: 141, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(cancel)
        self.panel = panel
        self.label = label
        panel.center()
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    private func tick() {
        guard result == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - policy.startedAt < policy.timeout else { finish(3, message: "Update canceled: quiet-period timeout."); return }
        guard consoleAvailable(), panel?.isVisible == true else { finish(4, message: "Update blocked: warning is not visible."); return }
        guard !scanning, now - lastScanAt >= 1 else { return }
        scanning = true
        lastScanAt = now
        worker.async { [weak self] in
            guard let self else { return }
            let observation = Result { try self.observer.snapshot() }
            let completedAt = ProcessInfo.processInfo.systemUptime
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

    private func apply(_ snapshot: UpdateActivitySnapshot, observedAt: TimeInterval) {
        guard consoleAvailable(), panel?.isVisible == true else { finish(4, message: "Update blocked: warning is not visible."); return }
        switch policy.observe(now: ProcessInfo.processInfo.systemUptime, active: snapshot.active,
                              changed: snapshot.changed, observedAt: observedAt) {
        case .waiting(let seconds):
            sound?.stop()
            label?.stringValue = snapshot.active
                ? "Dictation is active. The update will wait. You can keep dictating or cancel."
                : "Waiting for \(seconds) more seconds of quiet before the update warning. You can keep dictating or cancel."
        case .warning(let seconds, let playTone):
            label?.stringValue = "SpeakFree will pause for an update in \(seconds) seconds. Start dictating to postpone, or cancel below."
            if playTone {
                guard let sound = NSSound(named: NSSound.Name("Glass")), sound.play() else {
                    finish(4, message: "Update blocked: warning tone could not start."); return
                }
                self.sound = sound
                panel?.orderFrontRegardless()
            }
        case .ready:
            // This receipt is only an external observation, not a lock on the old app.
            finish(0, message: "SPEAKFREE_UPDATE_READY")
        case .timedOut:
            finish(3, message: "Update canceled: quiet-period timeout.")
        }
    }

    @objc private func cancelUpdate() { finish(2, message: "Update canceled by user.") }
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
        if code == 0 { print(message) } else { fputs(message + "\n", stderr) }
        NSApp.stop(nil)
        // stop() takes effect after the current event; wake a quiet run loop as well.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
    }
}
