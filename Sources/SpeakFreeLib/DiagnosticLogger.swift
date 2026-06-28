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
        let logsDir = Config.configDir.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        logFile = logsDir.appendingPathComponent("speakfree-\(dateStr).log")
        log("Session started — \(Bundle.main.bundleIdentifier ?? "unknown") v\(SpeakFree.version)")
        log("Machine: \(ProcessInfo.processInfo.operatingSystemVersionString), RAM: \(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))GB")
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
