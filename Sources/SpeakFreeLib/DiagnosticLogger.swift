import Foundation

public class DiagnosticLogger {
    public static let shared = DiagnosticLogger()

    private var logFile: URL?
    private let queue = DispatchQueue(label: "com.speakfree.logger")

    /// Whether logging is active
    var isEnabled: Bool = false

    func setup() {
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        let config = Config.load()

        // Beta: on by default. Production: on if config says so.
        isEnabled = isBeta || (config.diagnosticLogging?.value ?? false)

        if isEnabled {
            startLogging()
        }
    }

    /// Enable or disable logging at runtime (from settings toggle)
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled && logFile == nil {
            startLogging()
        }
    }

    private func startLogging() {
        let fm = FileManager.default
        let logsDir = Config.configDir.appendingPathComponent("logs")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // createDirectory attributes only apply on first creation — re-assert for
        // logs dirs that predate the permission fix.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDir.path)
        Self.pruneOldLogs(in: logsDir)
        let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = logsDir.appendingPathComponent("speakfree-\(dateStr).log")
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logFile = file
        log("Session started — \(Bundle.main.bundleIdentifier ?? "unknown") v\(SpeakFree.version)")
        log("Machine: \(ProcessInfo.processInfo.operatingSystemVersionString), RAM: \(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))GB")
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
        guard isEnabled else { return }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")  // Also print to console
        queue.async { [weak self] in
            guard let url = self?.logFile else { return }
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
