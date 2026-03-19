import AppKit
import Foundation

class ModelPickerController: NSWindowController {
    private var onComplete: ((String) -> Void)?
    private var selectedModel = "base.en"
    private var progressLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var downloadButton: NSButton!
    private var radioButtons: [NSButton] = []
    private let modelIDs = ["tiny.en", "base.en", "small.en", "medium.en", "large"]

    static func show(onComplete: @escaping (String) -> Void) {
        let controller = ModelPickerController()
        controller.onComplete = onComplete
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func loadWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Choose Whisper Model"
        panel.center()
        panel.isMovableByWindowBackground = true
        self.window = panel
        buildUI(in: panel)
    }

    private func buildUI(in panel: NSPanel) {
        let content = panel.contentView!

        let intro = NSTextField(wrappingLabelWithString:
            "speakfree needs a Whisper model to transcribe your voice. Choose one to download:")
        intro.font = NSFont.systemFont(ofSize: 13)
        intro.frame = NSRect(x: 20, y: 265, width: 380, height: 40)
        content.addSubview(intro)

        let rows: [(id: String, label: String, detail: String)] = [
            ("tiny.en",   "tiny.en    — 75 MB",    "Fastest, good for quick notes"),
            ("base.en",   "base.en  — 142 MB",     "Recommended — fast and accurate"),
            ("small.en",  "small.en  — 466 MB",    "More accurate, slightly slower"),
            ("medium.en", "medium.en — 1.5 GB",    "High accuracy"),
            ("large",     "large       — 3 GB",    "Best accuracy (M1 Pro+ recommended)"),
        ]

        var y: CGFloat = 230
        for (index, row) in rows.enumerated() {
            let radio = NSButton(radioButtonWithTitle: row.label, target: self, action: #selector(modelSelected(_:)))
            radio.frame = NSRect(x: 24, y: y, width: 220, height: 18)
            radio.tag = index
            radio.state = row.id == "base.en" ? .on : .off
            content.addSubview(radio)
            radioButtons.append(radio)

            let detail = NSTextField(labelWithString: row.detail)
            detail.font = NSFont.systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: 248, y: y + 1, width: 155, height: 16)
            content.addSubview(detail)

            y -= 28
        }

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = NSFont.systemFont(ofSize: 12)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: 20, y: 50, width: 300, height: 16)
        content.addSubview(progressLabel)

        progressBar = NSProgressIndicator()
        progressBar.frame = NSRect(x: 20, y: 30, width: 380, height: 12)
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.isHidden = true
        content.addSubview(progressBar)

        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadTapped))
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"
        downloadButton.frame = NSRect(x: 310, y: 18, width: 90, height: 28)
        content.addSubview(downloadButton)
    }

    @objc private func modelSelected(_ sender: NSButton) {
        selectedModel = modelIDs[sender.tag]
    }

    @objc private func downloadTapped() {
        downloadButton.isEnabled = false
        radioButtons.forEach { $0.isEnabled = false }
        progressBar.isHidden = false
        progressBar.startAnimation(nil)
        progressLabel.stringValue = "Downloading \(selectedModel) model…"

        let model = selectedModel
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ModelDownloader.download(modelSize: model)
                DispatchQueue.main.async {
                    self.progressBar.stopAnimation(nil)
                    self.progressBar.isHidden = true
                    self.progressLabel.stringValue = "Download complete."
                    self.close()
                    self.onComplete?(model)
                }
            } catch {
                DispatchQueue.main.async {
                    self.progressBar.stopAnimation(nil)
                    self.progressBar.isHidden = true
                    self.progressLabel.stringValue = "Error: \(error.localizedDescription)"
                    self.downloadButton.isEnabled = true
                    self.radioButtons.forEach { $0.isEnabled = true }
                }
            }
        }
    }
}
