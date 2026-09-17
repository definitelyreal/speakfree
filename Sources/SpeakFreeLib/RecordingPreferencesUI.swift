// ai-suggestion:unverified · session:01a0a336-fe39-7870-bdab-33c820f98955 · 2026-09-17
import AppKit
import SwiftUI

/// One vocabulary and mapping for the notice and Settings. Negative means no future saving;
/// zero means unlimited. Merely constructing a choice never changes disk or preferences.
enum RecordingRetention {
    static let label = "Keep Recordings & Transcripts"
    static let options = [0, -1, 1_000, 10_000]

    static func title(_ value: Int) -> String {
        switch value {
        case -1: return "Keep None"
        case 0: return "Keep All"
        default: return "Last \(value.formatted())"
        }
    }

    static func selection(in config: Config) -> Int {
        guard config.saveRecordings?.value == true else { return -1 }
        return config.preserveAllRecordings?.value == true ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
    }

    static func apply(_ value: Int, to config: inout Config) {
        config.saveRecordings = FlexBool(value != -1)
        config.maxRecordings = max(0, value)
        config.maxRecordingsUserConfirmed = true
        config.preserveAllRecordings = nil
    }

    static func explanation(_ value: Int, notice: Bool = false) -> String {
        switch value {
        case -1:
            return notice ? "Stop saving new dictations. Review moving existing files to Trash next."
                : "New dictations won’t be saved. Existing files stay until you move them to Trash."
        case 0: return "Keep audio and transcripts from every dictation on this Mac."
        default: return "Keep the latest \(value.formatted()) dictations. Older recordings and transcripts are permanently deleted."
        }
    }
}

enum SettingsLayout {
    static let labelWidth: CGFloat = 200
    static let controlSpacing: CGFloat = 12
    static let windowWidth: CGFloat = 900
}

struct RecordingRetentionPicker: View {
    @Binding var selection: Int
    var developerMode = false

    var body: some View {
        Picker(RecordingRetention.label, selection: developerMode ? .constant(0) : $selection) {
            ForEach(RecordingRetention.options, id: \.self) { value in
                Text(RecordingRetention.title(value)).tag(value)
            }
            if !RecordingRetention.options.contains(selection), selection > 0 {
                Divider()
                Text(RecordingRetention.title(selection)).tag(selection)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: 170, idealWidth: 190, maxWidth: 220, alignment: .leading)
        .controlSize(.regular)
        .disabled(developerMode)
        .accessibilityIdentifier("recording-retention-picker")
    }
}

struct RecordingsFolderButton: View {
    let folderPath: String
    var open: ((String) -> Void)? = nil

    var body: some View {
        Button {
            if let open { open(folderPath) }
            else { NSWorkspace.shared.open(URL(fileURLWithPath: folderPath, isDirectory: true)) }
        } label: {
            Label {
                Text("Recordings & Transcripts Folder")
            } icon: {
                // Keep Apple's folder shape explicitly yellow; the folder emoji's
                // color varies with the installed Apple Color Emoji version.
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(nsColor: .systemYellow))
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
            }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        // macOS gives large controls a capsule bezel. Use the same regular
        // rounded rectangle as neighboring controls, with roomier label insets.
        .controlSize(.regular)
        .help(folderPath)
        .accessibilityIdentifier("recordings-folder-button")
    }
}

/// Native keyboard focus, not a Return-key default: Space activates this button
/// while it has focus. The OS draws the focus ring, and Tab can move it elsewhere.
struct RecordingsChoiceButton: NSViewRepresentable {
    let title: String
    var action: () -> Void

    final class FocusButton: NSButton {
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activateChoice() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> FocusButton {
        let button = FocusButton(title: title, target: context.coordinator, action: #selector(Coordinator.activateChoice))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.keyEquivalent = ""
        button.focusRingType = .default
        button.setAccessibilityIdentifier("continue-btn")
        return button
    }
    func updateNSView(_ button: FocusButton, context: Context) {
        button.title = title
        context.coordinator.action = action
        button.toolTip = "Apply your recording choice; Keep None opens a separate Trash confirmation"
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
