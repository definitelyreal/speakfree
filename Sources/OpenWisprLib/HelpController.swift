import AppKit

class HelpController: NSWindowController {
    private static var shared: HelpController?

    static func show() {
        if shared == nil { shared = HelpController() }
        shared?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    override func loadWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "speakfree Help"
        panel.minSize = NSSize(width: 380, height: 400)
        panel.center()
        self.window = panel

        let scrollView = NSScrollView(frame: panel.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textStorage?.setAttributedString(helpContent())
        textView.sizeToFit()

        let contentHeight = max(textView.frame.height + 40, 560)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: contentHeight)

        scrollView.documentView = textView
        panel.contentView!.addSubview(scrollView)
    }

    private func helpContent() -> NSAttributedString {
        let result = NSMutableAttributedString()

        func h(_ text: String) {
            result.append(NSAttributedString(string: "\n\(text)\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        func p(_ text: String) {
            result.append(NSAttributedString(string: "\(text)\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        func row(_ label: String, _ detail: String) {
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "  \(label)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
            s.append(NSAttributedString(string: " — \(detail)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
            result.append(s)
        }

        h("How it works")
        p("Hold your hotkey, speak, then release. speakfree transcribes your voice locally and types the text wherever your cursor is. If no text field is focused, the transcription is copied to your clipboard instead.")

        h("Models")
        p("Larger models are more accurate but take longer to transcribe. You can change the model in Settings → Model at any time — it will download automatically if needed.")
        row("tiny.en",   "75 MB · Fastest · Good for short notes and quick phrases")
        row("base.en",   "142 MB · Recommended · Fast and accurate for everyday use")
        row("small.en",  "466 MB · More accurate · Better for technical terms and longer dictation")
        row("medium.en", "1.5 GB · High accuracy · Noticeably slower to transcribe")
        row("large",     "3 GB · Best accuracy · Recommended only for M1 Pro or better")
        result.append(NSAttributedString(string: "\n", attributes: [:]))

        h("Punctuation")
        p("Choose in Settings → Punctuation.")
        row("Hybrid",        "Whisper adds punctuation automatically, and you can also say \"comma\", \"period\", \"question mark\" etc. to add punctuation explicitly. Recommended.")
        row("Off",           "Whisper adds punctuation automatically based on natural speech patterns. You cannot add punctuation by speaking it.")
        row("Spoken words",  "Whisper's auto-punctuation is disabled. All punctuation must be spoken explicitly.")
        result.append(NSAttributedString(string: "\n", attributes: [:]))

        h("Hotkey")
        p("The default hotkey is the Globe key (🌐), the key in the bottom-left corner of your keyboard. Hold it while you speak, then let go.\n\nTo change it: Settings → Hotkey. You can use Globe, Left or Right Command (⌘), Left or Right Option (⌥), or Left Control (⌃).")

        h("Privacy")
        p("speakfree is 100% local. Your voice never leaves your Mac — there are no servers, no accounts, and no internet connection required after the model is downloaded.\n\nAudio is recorded to a temporary file, transcribed on your device by the Whisper model, and the file is deleted. If you enable Recent Dictations (Settings → Max Recordings), recordings are stored only on your Mac.")

        h("\"Recover Unsaved Recording\"")
        p("If speakfree quit unexpectedly while you were recording, it can try to transcribe that recording the next time it starts. Click \"Recover Unsaved Recording\" in the Recent Dictations menu to do this.")

        return result
    }
}
