// ai-suggestion:unverified · session:unknown/agent:audio_file_integrity · 2026-10-03
import SwiftUI

/// An inline field; the shared monitor owns suppression and waits for key release on exit.
struct InlineHistoryShortcutRecorder: View {
    let action: HistorySettings.Action
    let shortcut: HistorySettings.Shortcut
    @Binding var recordingAction: HistorySettings.Action?
    let validate: (HistorySettings.Shortcut) -> String?
    let onChange: (HistorySettings.Shortcut) -> Void
    @StateObject private var holder = KeyMonitorHolder()
    @State private var rejection: String?
    private var isRecording: Bool { recordingAction == action }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(action.title)
                Spacer()
                Button {
                    rejection = nil
                    recordingAction = isRecording ? nil : action
                } label: {
                    Text(isRecording ? "Type shortcut…" : shortcut.label)
                        .foregroundStyle(isRecording || shortcut.isAssigned ? .primary : .secondary)
                        .frame(width: 132, height: 28)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.title) shortcut")
                .accessibilityValue(isRecording ? "Recording shortcut" : shortcut.label)
                .help(isRecording ? "Escape cancels. Tab moves to the next control." : "Record \(action.title) shortcut")
                Button { apply(.unassigned) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(!shortcut.isAssigned)
                    .accessibilityLabel("Clear \(action.title) shortcut")
                    .help("Clear shortcut")
                if action.defaultShortcut.isAssigned && !shortcut.matches(action.defaultShortcut) {
                    Button { apply(action.defaultShortcut) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Reset \(action.title) shortcut")
                        .help("Reset to \(action.defaultShortcut.label)")
                }
            }
            if let rejection { Text(rejection).font(.callout).foregroundStyle(.red) }
        }
        .onChange(of: isRecording) { recording in
            if recording {
                holder.install(onCapture: { code, modifiers in
                    // Modifier presses alone leave this chord recorder ready for the main key.
                    if modifiers.isEmpty && [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code) { return }
                    apply(.init(keyCode: code, modifiers: modifiers), captured: true)
                }, onCancel: { recordingAction = nil }, allowsFocusTraversal: true,
                   onClear: { apply(.unassigned) })
            } else { holder.remove() }
        }
        .onDisappear {
            holder.remove()
            if isRecording { recordingAction = nil }
        }
    }

    private func apply(_ candidate: HistorySettings.Shortcut, captured: Bool = false) {
        if captured && !candidate.isAssigned {
            rejection = "Use a key with Command, Option, or Control."
            return
        }
        if let error = validate(candidate) { rejection = error; return }
        rejection = nil
        onChange(candidate)
        recordingAction = nil
        holder.remove()
    }
}
