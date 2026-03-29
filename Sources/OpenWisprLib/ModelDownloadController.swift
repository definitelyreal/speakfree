import AppKit
import Foundation

/// A modal, non-closeable dialog that shows model download progress.
/// Replaces the old ModelPickerController for download-only use cases.
class ModelDownloadController: NSObject, URLSessionDownloadDelegate {

    // MARK: - Known model sizes for display

    private static let modelSizes: [String: String] = [
        "tiny": "75 MB",
        "tiny.en": "75 MB",
        "base": "142 MB",
        "base.en": "142 MB",
        "small": "466 MB",
        "small.en": "466 MB",
        "medium": "1.5 GB",
        "medium.en": "1.5 GB",
        "large": "3.1 GB",
        "large-v1": "3.1 GB",
        "large-v2": "3.1 GB",
        "large-v3": "3.1 GB",
        "large-v3-turbo": "1.6 GB",
    ]

    // MARK: - UI elements

    private var panel: NSPanel!
    private var statusLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var percentLabel: NSTextField!
    private var descriptionLabel: NSTextField!
    private var closeButton: NSButton?

    // MARK: - State

    private var modelSize: String = ""
    private var completion: ((Bool) -> Void)?
    private var downloadTask: URLSessionDownloadTask?

    // MARK: - Public API

    /// Show a modal download dialog, download the model, and call completion when done.
    /// Must be called from the main thread.
    static func downloadModel(_ modelSize: String, completion: @escaping (Bool) -> Void) {
        assert(Thread.isMainThread, "ModelDownloadController.downloadModel must be called on the main thread")

        let controller = ModelDownloadController()
        controller.modelSize = modelSize
        controller.completion = completion
        controller.buildPanel()
        controller.startDownload()

        // Run as app-modal so nothing else can happen until download completes or fails
        NSApp.runModal(for: controller.panel)
    }

    // MARK: - UI construction

    private func buildPanel() {
        let width: CGFloat = 440
        let height: CGFloat = 160

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],  // No .closable — user can't dismiss
            backing: .buffered,
            defer: false
        )
        panel.title = "Downloading Model"
        panel.center()
        panel.isMovableByWindowBackground = true

        let content = panel.contentView!

        let sizeStr = ModelDownloadController.modelSizes[modelSize] ?? "unknown size"

        // Status label: "Downloading small.en (466 MB)..."
        statusLabel = NSTextField(labelWithString: "Downloading \(modelSize) (\(sizeStr))...")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.frame = NSRect(x: 20, y: height - 45, width: width - 40, height: 20)
        content.addSubview(statusLabel)

        // Progress bar
        progressBar = NSProgressIndicator()
        progressBar.frame = NSRect(x: 20, y: height - 75, width: width - 40, height: 20)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0
        content.addSubview(progressBar)

        // Percentage label
        percentLabel = NSTextField(labelWithString: "0%")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: width - 60, y: height - 95, width: 40, height: 16)
        content.addSubview(percentLabel)

        // Description text
        descriptionLabel = NSTextField(labelWithString: "Larger models are more accurate but slower.")
        descriptionLabel.font = NSFont.systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.frame = NSRect(x: 20, y: 15, width: width - 40, height: 16)
        content.addSubview(descriptionLabel)

        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Download

    private func startDownload() {
        let modelFileName = "ggml-\(modelSize).bin"
        let urlString = "\(ModelDownloader.baseURL)/\(modelFileName)"
        guard let url = URL(string: urlString) else {
            showError("Invalid download URL")
            return
        }

        // Ensure models directory exists
        let modelsDir = Config.configDir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Clean up any partial download
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        let tmpPath = destPath.appendingPathExtension("downloading")
        try? FileManager.default.removeItem(at: tmpPath)

        // If model already exists, succeed immediately
        if FileManager.default.fileExists(atPath: destPath.path) {
            print("Model '\(modelSize)' already exists at \(destPath.path)")
            finishSuccess()
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }
        DispatchQueue.main.async { [weak self] in
            self?.progressBar.doubleValue = progress
            self?.percentLabel.stringValue = "\(Int(progress * 100))%"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let destPath = modelsDir.appendingPathComponent(modelFileName)
        let tmpPath = destPath.appendingPathExtension("downloading")

        do {
            // Move downloaded file to tmp path first (URLSession's location is ephemeral)
            try? FileManager.default.removeItem(at: tmpPath)
            try FileManager.default.moveItem(at: location, to: tmpPath)

            // Validate: GGML files should be at least 1MB
            let attrs = try? FileManager.default.attributesOfItem(atPath: tmpPath.path)
            let fileSize = attrs?[.size] as? Int ?? 0
            if fileSize < 1_000_000 {
                try? FileManager.default.removeItem(at: tmpPath)
                DispatchQueue.main.async { [weak self] in
                    self?.showError("Downloaded file is not a valid Whisper model")
                }
                return
            }

            // Atomically move to final destination
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: tmpPath, to: destPath)
            print("Model downloaded to \(destPath.path)")

            DispatchQueue.main.async { [weak self] in
                self?.finishSuccess()
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
            DispatchQueue.main.async { [weak self] in
                self?.showError("Failed to save model: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async { [weak self] in
                self?.showError("Download failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Completion helpers

    private func finishSuccess() {
        assert(Thread.isMainThread)
        panel.orderOut(nil)
        NSApp.stopModal()
        completion?(true)
        completion = nil
    }

    private func showError(_ message: String) {
        assert(Thread.isMainThread)
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        progressBar.isHidden = true
        percentLabel.isHidden = true
        descriptionLabel.stringValue = ""

        // Add a Close button so the user can dismiss the error
        if closeButton == nil {
            let btn = NSButton(title: "Close", target: self, action: #selector(closeTapped))
            btn.bezelStyle = .rounded
            btn.keyEquivalent = "\r"
            let contentWidth = panel.contentView!.frame.width
            btn.frame = NSRect(x: contentWidth - 100, y: 15, width: 80, height: 28)
            panel.contentView!.addSubview(btn)
            closeButton = btn
        }
    }

    @objc private func closeTapped() {
        panel.orderOut(nil)
        NSApp.stopModal()
        completion?(false)
        completion = nil
    }
}
