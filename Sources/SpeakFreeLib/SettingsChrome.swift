import SwiftUI

/// The panes of the Settings window, in tab-bar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, microphone, transcription, words, recordings, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .microphone: return "Microphone"
        case .transcription: return "Transcription"
        case .words: return "Words"
        case .recordings: return "Recordings"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .microphone: return "mic"
        case .transcription: return "waveform"
        case .words: return "character.book.closed"
        case .recordings: return "folder"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    /// One plain sentence under the pane's title.
    var summary: String {
        switch self {
        case .general: return "How speakfree starts, and what it has saved you so far."
        case .shortcuts: return "The keys that start, cancel, repeat and recover a dictation."
        case .microphone: return "Which microphone speakfree listens to."
        case .transcription: return "The speech engine, its language and its punctuation."
        case .words: return "Teach speakfree the names and terms it gets wrong."
        case .recordings: return "What is kept on this Mac after each dictation."
        case .advanced: return "Diagnostics and experimental features."
        }
    }
}

/// Which pane the Settings window is showing. Shared so a menu item can open Settings
/// straight to a pane.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

/// The look shared by the Settings window. It borrows from the dictation pill: a dark
/// rounded surface with white marks on it, and red only while something is live.
enum SettingsStyle {
    static let pillSurface = Color(white: 0.09)
    static let live = Color(nsColor: .systemRed)
    static let panelFill = Color.primary.opacity(0.045)
    static let panelEdge = Color.primary.opacity(0.08)
    static let rowInset: CGFloat = 14

    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// The tab bar: one dark track, like the pill, with the current pane raised on it.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(height: 18)
                        Text(tab.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(selected ? 1 : 0.55))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(selected ? 0.16 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SettingsStyle.pillSurface))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct SettingsPaneHeader: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tab.title).font(SettingsStyle.title(22))
            Text(tab.summary).foregroundColor(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

/// A group of related settings on one quiet surface.
struct SettingsPanel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(SettingsStyle.title(13)).padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsStyle.panelFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SettingsStyle.panelEdge, lineWidth: 1))
        }
    }
}

/// The hairline between two rows of a panel.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, SettingsStyle.rowInset)
    }
}

/// One setting: its name and a sentence of help on the left, its control on the right.
struct SettingRow<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var content: Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let help {
                    Text(help)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 11)
    }
}

/// A shortcut drawn as raised key caps.
struct KeyCaps: View {
    let parts: [String]
    var onDark = false

    init(keyCode: UInt16, modifiers: [String], onDark: Bool = false) {
        parts = ShortcutSymbols.parts(keyCode: keyCode, modifiers: modifiers)
        self.onDark = onDark
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(parts.indices, id: \.self) { index in
                Text(parts[index])
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(onDark ? .white : .primary)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(onDark ? Color.white.opacity(0.17) : Color.primary.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(onDark ? Color.white.opacity(0.22) : Color.primary.opacity(0.18),
                                          lineWidth: 1))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(parts.joined(separator: " "))
    }
}

/// The one control for every shortcut: a dark well holding the keys. Click it and type
/// to change the shortcut; it turns red while it is listening.
struct ShortcutWell: View {
    let shortcut: HotkeyConfig?
    let isRecording: Bool
    var canClear = true
    var isFixed = false
    let onToggleRecording: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleRecording) {
                HStack(spacing: 8) {
                    if isRecording {
                        Text("Type a shortcut")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    } else if let shortcut {
                        KeyCaps(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, onDark: true)
                    } else {
                        Text("Click to set")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 132, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SettingsStyle.pillSurface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isRecording ? SettingsStyle.live : Color.white.opacity(0.1),
                                      lineWidth: isRecording ? 2 : 1))
                .shadow(color: isRecording ? SettingsStyle.live.opacity(0.45) : .clear, radius: 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFixed)
            .help(isFixed ? "" : (isRecording ? "Press Escape to keep the current shortcut" : "Click, then type a shortcut"))
            .accessibilityLabel(isRecording ? "Recording shortcut" : "Change shortcut")

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this shortcut")
            .accessibilityLabel("Remove shortcut")
            .opacity(canClear && shortcut != nil && !isRecording && !isFixed ? 1 : 0)
            .disabled(!(canClear && shortcut != nil && !isRecording && !isFixed))
        }
        .animation(.easeOut(duration: 0.15), value: isRecording)
    }
}

enum ShortcutSymbols {
    private static let order = ["ctrl", "option", "shift", "cmd"]
    private static let symbols = ["ctrl": "\u{2303}", "option": "\u{2325}", "shift": "\u{21E7}", "cmd": "\u{2318}"]
    /// A modifier used alone as the dictation key names its side of the keyboard.
    private static let loneModifiers: [UInt16: String] = [
        63: "fn", 55: "Left \u{2318}", 54: "Right \u{2318}", 58: "Left \u{2325}", 61: "Right \u{2325}",
        59: "Left \u{2303}", 62: "Right \u{2303}", 56: "Left \u{21E7}", 60: "Right \u{21E7}",
    ]

    /// Modifier symbols in the standard macOS order, then the key's name.
    static func parts(keyCode: UInt16, modifiers: [String]) -> [String] {
        let known = order.filter(modifiers.contains).compactMap { symbols[$0] }
        if let lone = loneModifiers[keyCode] { return known + [lone] }
        let name = KeyCodes.describe(keyCode: keyCode, modifiers: [])
        let key = name.count == 1 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
        return known + [key]
    }
}
