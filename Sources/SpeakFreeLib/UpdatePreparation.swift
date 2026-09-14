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

/// A strict parser for newly appended lines only. Never returns or prints message bodies.
/// Prefixes come from DiagnosticLogger, AudioRecorder, AppDelegate and HotkeyManager.
enum UpdateLogEvent {
    case captureStarted, captureStopped, activity, unrelated, unsupported
    static func classify(_ line: String) -> UpdateLogEvent {
        guard line.range(of: #"^\[[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\] "#,
                         options: .regularExpression) != nil else { return .unsupported }
        let message = String(line.dropFirst(11))
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

/// Worker-confined metadata observer. No audio, transcript or config bodies are read. A bounded existing log tail is
/// inspected only for its final newline; event parsing follows newly appended lines.
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
    private let directory: URL
    private var recordings: [String: Stamp]?
    private var recordingNames: [String] = []
    private var listingStamp: Stamp?
    // Recording names begin with sortable wall-clock timestamps. Older immutable takes
    // do not need 74k stat calls per poll; sentinel + new log events cover ongoing work.
    static let recentFileLimit = 256
    private(set) var recordingStatCount = 0
    private(set) var recordingListingCount = 0
    private var logCursors: [String: LogCursor] = [:]
    private var initialized = false
    private var activeCaptureLogs = Set<String>()

    init(directory: URL) { self.directory = directory }

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
        if lstat(path, &info) == 0 { return true } // malformed/stale/symlink sentinels also block
        guard errno == ENOENT else { throw Failure.unavailable }
        return false
    }

    func snapshot() throws -> UpdateActivitySnapshot {
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
        var changed = recordings.map { $0 != next } ?? false
        recordings = next
        let names = try FileManager.default.contentsOfDirectory(atPath: logDir.path).filter {
            $0.hasPrefix("speakfree-") && $0.hasSuffix(".log")
                && !$0.hasSuffix(".previous.log") && !$0.hasSuffix(".older.log")
        }
        guard !names.isEmpty else { throw Failure.unavailable }
        let namesSet = Set(names)
        if initialized && Set(logCursors.keys) != namesSet { changed = true }
        logCursors = logCursors.filter { namesSet.contains($0.key) }
        for name in names {
            let url = logDir.appendingPathComponent(name)
            let before = try stamp(url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var cursor: LogCursor
            if let old = logCursors[name], old.inode == before.inode, old.offset <= before.size {
                cursor = old
            } else if !initialized {
                // Retain a partial last line so its eventual completion cannot evade parsing.
                let start = before.size > 65_536 ? before.size - 65_536 : 0
                try handle.seek(toOffset: start)
                let tail = try handle.read(upToCount: Int(before.size - start)) ?? Data()
                guard tail.count <= 1_048_576 else { throw Failure.logBacklog }
                let boundary = tail.lastIndex(of: 10).map { UInt64($0 + 1) } ?? 0
                if start > 0 && boundary == 0 { throw Failure.unsupportedLog }
                cursor = LogCursor(offset: start + boundary, inode: before.inode)
            } else {
                changed = true // new session or rotation: restart quiet even without a take
                cursor = LogCursor(offset: 0, inode: before.inode)
            }
            guard before.size - cursor.offset <= 1_048_576 else { throw Failure.logBacklog }
            try handle.seek(toOffset: cursor.offset)
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw Failure.logBacklog }
            cursor.offset += UInt64(data.count)
            cursor.pending.append(data)
            guard cursor.pending.count <= 1_048_576 else { throw Failure.logBacklog }
            while let newline = cursor.pending.firstIndex(of: 10) {
                let bytes = cursor.pending.prefix(upTo: newline)
                guard let line = String(data: bytes, encoding: .utf8) else { throw Failure.unsupportedLog }
                switch UpdateLogEvent.classify(line) {
                case .captureStarted:
                    activeCaptureLogs.insert(name)
                    changed = true
                case .captureStopped:
                    activeCaptureLogs.remove(name)
                    changed = true
                case .activity: changed = true
                case .unrelated: break
                case .unsupported: throw Failure.unsupportedLog
                }
                cursor.pending.removeSubrange(...newline)
            }
            // An unfinished line could be a recording-start event. Never authorize over it.
            if !cursor.pending.isEmpty { changed = true }
            if try stamp(url) != before { changed = true }
            logCursors[name] = cursor
        }
        let activeAfter = try sentinelExists()
        if try stamp(recordingDir, directory: true) != directoryBefore { changed = true }
        initialized = true
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
