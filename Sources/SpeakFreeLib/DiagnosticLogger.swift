// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import Foundation

public final class DiagnosticLogger {
    public static let shared = DiagnosticLogger()
    private let queue = DispatchQueue(label: "com.speakfree.logger", qos: .utility)
    private let stateLock = NSLock()
    private var enabled = false
    private var pendingLines = 0
    private var droppedLines = 0
    private let directoryOverride: URL?
    private let maxFileBytes: Int
    // Writer-queue-only state.
    private var logFile: URL?
    private var handle: FileHandle?
    private var bytesWritten = 0
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(logsDirectory: URL? = nil, maxFileBytes: Int = 8 * 1024 * 1024) {
        self.directoryOverride = logsDirectory
        self.maxFileBytes = max(1024, maxFileBytes)
    }

    var isEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return enabled
    }

    func setup() {
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        setEnabled(isBeta || (Config.load().diagnosticLogging?.value ?? false))
    }

    public func setEnabled(_ enabled: Bool) {
        let directory = directoryOverride ?? Config.configDir.appendingPathComponent("logs")
        stateLock.lock()
        self.enabled = enabled
        // Queue the file transition while holding the same lock as log(), so no
        // message can overtake enable, disable, or directory changes.
        queue.async {
            if enabled {
                self.startLogging(in: directory)
            } else {
                try? self.handle?.close()
                self.handle = nil
            }
        }
        stateLock.unlock()
    }

    private func startLogging(in directory: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if logFile?.deletingLastPathComponent().standardizedFileURL.path != directory.standardizedFileURL.path {
                try? handle?.close()
                handle = nil
                Self.pruneOldLogs(in: directory)
                let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                logFile = directory.appendingPathComponent("speakfree-\(date)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).log")
                bytesWritten = 0
                guard let logFile else { return }
                guard fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            guard handle == nil, let logFile else { return }
            if !fm.fileExists(atPath: logFile.path) {
                guard fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            handle = try FileHandle(forWritingTo: logFile)
            bytesWritten = Int(try handle!.seekToEnd())
            let info = Bundle.main.infoDictionary
            write("Session started — \(Bundle.main.bundleIdentifier ?? "unknown") v\(SpeakFree.version)", at: Date())
            write("Machine: \(ProcessInfo.processInfo.operatingSystemVersionString), RAM: \(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))GB", at: Date())
            write("Build: commit \(info?["SFBuildCommit"] as? String ?? "unstamped"), built \(info?["SFBuildDate"] as? String ?? "unstamped"), channel \(info?["SFBuildChannel"] as? String ?? "dev")", at: Date())
        } catch {
            handle = nil
            fputs("speakfree diagnostic log unavailable: \(error.localizedDescription)\n", stderr)
        }
    }

    private func write(_ message: String, at date: Date) {
        guard let logFile, let handle else { return }
        let line = "[\(formatter.string(from: date))] \(message)\n"
        print(line, terminator: "")
        do {
            let data = Data(line.utf8)
            if bytesWritten > 0 && bytesWritten + data.count > maxFileBytes {
                try handle.close()
                self.handle = nil
                let previous = logFile.deletingPathExtension().appendingPathExtension("previous.log")
                let older = logFile.deletingPathExtension().appendingPathExtension("older.log")
                let fm = FileManager.default
                if fm.fileExists(atPath: older.path) { try fm.removeItem(at: older) }
                if fm.fileExists(atPath: previous.path) { try fm.moveItem(at: previous, to: older) }
                try fm.moveItem(at: logFile, to: previous)
                guard fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                self.handle = try FileHandle(forWritingTo: logFile)
                bytesWritten = 0
            }
            try self.handle?.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            try? self.handle?.close()
            self.handle = nil
            fputs("speakfree diagnostic write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Delete session logs older than `days`. Beta builds log every session by default,
    /// so without a cap the logs directory grows forever.
    static func pruneOldLogs(in dir: URL, olderThanDays days: Int = 14) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files
        where file.lastPathComponent.hasPrefix("speakfree-") && file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    func log(_ message: String) {
        let now = Date()
        stateLock.lock()
        guard enabled else { stateLock.unlock(); return }
        guard pendingLines < 512 else {
            droppedLines += 1
            stateLock.unlock()
            return
        }
        pendingLines += 1
        let dropped = droppedLines
        droppedLines = 0
        // A pathological error message cannot bypass the per-file or queue cap.
        // The byte cap can split a UTF-8 scalar; retain the prefix with a replacement character.
        // swiftlint:disable:next optional_data_string_conversion
        let bounded = String(decoding: message.utf8.prefix(min(16_384, maxFileBytes / 4)), as: UTF8.self)
        queue.async {
            if dropped > 0 { self.write("Logger: dropped \(dropped) messages while busy", at: now) }
            self.write(bounded, at: now)
            self.stateLock.lock()
            self.pendingLines -= 1
            self.stateLock.unlock()
        }
        stateLock.unlock()
    }

    /// Deterministic test barrier; production logging never waits on disk.
    func flush() { queue.sync {} }
    deinit { try? handle?.close() }
}
