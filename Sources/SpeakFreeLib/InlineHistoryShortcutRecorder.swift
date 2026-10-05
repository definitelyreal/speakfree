// ai-suggestion:unverified · session:unknown · 2026-10-05
import AppKit
import SwiftUI

/// An inline field; the shared monitor owns suppression and waits for key release on exit.
struct InlineHistoryShortcutRecorder: View {
    let action: HistorySettings.Action
    let shortcut: HistorySettings.Shortcut
    @Binding var recordingAction: HistorySettings.Action?
    let validate: (HistorySettings.Shortcut) -> String?
    let onChange: (HistorySettings.Shortcut) -> Void
    @StateObject private var holder = HistoryKeyMonitorHolder()
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

/// The recorder waits until a modifier is released before choosing it by itself. Committing on
/// its press made the first Command/Option key swallow every attempted multi-key shortcut.
struct HistoryKeyRecorderState {
    enum Action: Equatable {
        case ignore, cancel, capture(UInt16, [String])
    }

    private var loneModifier: UInt16?
    private var modifierChordInProgress = false
    private static let flagsByKey: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 60: .shift,
        58: .option, 61: .option, 59: .control, 62: .control, 63: .function,
    ]
    private static let relevantFlags: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

    mutating func receive(type: NSEvent.EventType, keyCode: UInt16,
                          flags: NSEvent.ModifierFlags) -> Action {
        if type == .flagsChanged {
            guard let flag = Self.flagsByKey[keyCode] else { return .ignore }
            let held = flags.intersection(Self.relevantFlags)
            if flags.contains(flag) {
                if held == flag, !modifierChordInProgress, loneModifier == nil {
                    loneModifier = keyCode
                } else {
                    loneModifier = nil
                    modifierChordInProgress = true
                }
                return .ignore
            }
            let shouldCapture = loneModifier == keyCode && held.isEmpty && !modifierChordInProgress
            loneModifier = nil
            if held.isEmpty { modifierChordInProgress = false }
            return shouldCapture ? .capture(keyCode, []) : .ignore
        }
        guard type == .keyDown else { return .ignore }
        loneModifier = nil
        modifierChordInProgress = !flags.isDisjoint(with: Self.relevantFlags)
        if keyCode == 53 { return .cancel }
        var modifiers: [String] = []
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        return .capture(keyCode, modifiers)
    }
}

/// Holds the NSEvent monitor reference so it can be cleaned up reliably.
final class HistoryKeyMonitorHolder: ObservableObject {
    typealias EventHandler = (NSEvent) -> NSEvent?
    private let recordingGate: ShortcutRecordingGate
    private let notificationCenter: NotificationCenter
    private let installMonitor: (@escaping EventHandler) -> Any?
    private let removeMonitor: (Any) -> Void
    var monitor: Any?
    private var state = HistoryKeyRecorderState()
    private var recordingLease: UUID?
    private var capturedKey: UInt16?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(recordingGate: ShortcutRecordingGate = .shared, notificationCenter: NotificationCenter = .default,
         installMonitor: @escaping (@escaping EventHandler) -> Any? = {
             NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: $0)
         },
         removeMonitor: @escaping (Any) -> Void = NSEvent.removeMonitor) {
        self.recordingGate = recordingGate
        self.notificationCenter = notificationCenter
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    func install(onCapture: @escaping (UInt16, [String]) -> Void, onCancel: @escaping () -> Void,
                 allowsFocusTraversal: Bool = false, onClear: (() -> Void)? = nil) {
        remove()
        state = HistoryKeyRecorderState()
        capturedKey = nil
        recordingLease = recordingGate.begin()
        // A retained Settings host can disappear without SwiftUI immediately destroying its
        // overlay. Closing a window or switching apps always cancels and restores the hotkeys.
        for name in [NSWindow.willCloseNotification, NSApplication.didResignActiveNotification] {
            lifecycleObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard self?.monitor != nil else { return }
                self?.remove()
                onCancel()
            })
        }
        monitor = installMonitor { [weak self] event in
            guard let self else { return event }
            guard event.type != .keyDown || !event.isARepeat else { return nil }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
            if allowsFocusTraversal, event.type == .keyDown, event.keyCode == 48,
               modifiers.isEmpty || modifiers == .shift {
                self.remove()
                onCancel()
                return event // Inline fields leave Tab/Shift-Tab to ordinary focus traversal.
            }
            // Fn+Delete arrives as forward Delete with the function flag still set.
            if event.type == .keyDown, [51, 117].contains(event.keyCode), modifiers.subtracting(.function).isEmpty, let onClear {
                self.capturedKey = event.keyCode
                onClear()
                return nil
            }
            switch self.state.receive(type: event.type, keyCode: event.keyCode, flags: event.modifierFlags) {
            case .ignore: break
            case .cancel: onCancel()
            case .capture(let code, let modifiers):
                self.capturedKey = event.type == .keyDown ? code : nil
                onCapture(code, modifiers)
            }
            return nil
        }
        if monitor == nil {
            remove()
            onCancel()
        }
    }

    func remove() {
        if let m = monitor {
            removeMonitor(m)
            monitor = nil
        }
        lifecycleObservers.forEach(notificationCenter.removeObserver)
        lifecycleObservers.removeAll()
        if let recordingLease {
            self.recordingLease = nil
            recordingGate.finish(recordingLease, afterKeyRelease: capturedKey)
        }
        capturedKey = nil
    }

    deinit { remove() }
}
