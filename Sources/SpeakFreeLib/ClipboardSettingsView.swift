// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import SwiftUI

enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case dictation, clipboard

    var id: Self { self }
    var title: String { self == .dictation ? "Dictation" : "Clipboard" }
    var symbol: String { self == .dictation ? "waveform" : "clipboard" }
}

enum SettingsSidebarLayout {
    static let sidebarWidth: CGFloat = 152
    static let windowWidth: CGFloat = 860
    static let minimumWindowWidth: CGFloat = 800
}

/// One semantic canvas across both panes; groups provide structure without stacking
/// the platform's differently shaded GroupBox and TabView backgrounds.
struct SettingsSectionStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}

/// Both tabs share the same model and save path. The existing dictation controls
/// remain together while the independently developed Edit Mode pane evolves.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var isReview = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("speakfree")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                List(selection: Binding<SettingsTab?>(
                    get: { viewModel.selectedSettingsTab },
                    set: { if let tab = $0 { viewModel.selectedSettingsTab = tab } }
                )) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .padding(.vertical, 4)
                            .tag(tab)
                            .accessibilityIdentifier("settings-\(tab.title.lowercased())")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Preferences sections")
            }
            .frame(width: SettingsSidebarLayout.sidebarWidth)
            Divider()
            Group {
                switch viewModel.selectedSettingsTab {
                case .dictation:
                    DictationSettingsView(viewModel: viewModel, isReview: isReview)
                case .clipboard:
                    ClipboardSettingsView(viewModel: viewModel, isReview: isReview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .groupBoxStyle(SettingsSectionStyle())
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ClipboardSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var isReview = false
    @State private var recordingShortcut = false
    @State private var shortcutError: String?
    @State private var clearConfirmation = false
    @State private var registrationError: String?

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Clipboard")
                            .font(.title2.weight(.semibold))
                        Text("One history for what you say and copy.")
                            .foregroundStyle(.secondary)
                        Text("Clipboard managers can interfere with speakfree while it pastes a dictation. We built history into speakfree so your dictations and copied items can share one shortcut.")
                    }
                    GroupBox("History") {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text("Keep history")
                                Spacer()
                                Picker("Keep history", selection: $viewModel.historySettings.retention) {
                                    Text("Off").tag(HistorySettings.Retention.off)
                                    Text("Until speakfree quits").tag(HistorySettings.Retention.session)
                                    Text("7 days on this Mac").tag(HistorySettings.Retention.week)
                                }.labelsHidden().frame(width: 220)
                            }
                            Toggle("Include items copied in other apps", isOn: $viewModel.historySettings.includeClipboard)
                                .disabled(viewModel.historySettings.retention == .off)
                            Text("Text, formatting, images, and file references. Up to 200 items and 128 MB; items larger than 32 MB are skipped. PNG is preferred when an image also offers TIFF. File references depend on the original files staying available.")
                                .font(.callout).foregroundStyle(.secondary)
                            Divider()
                            HStack {
                                Text("History shortcut")
                                Spacer()
                                Button(viewModel.historySettings.shortcutLabel) { recordingShortcut = true }
                                    .frame(minWidth: 100)
                                    .disabled(viewModel.historySettings.retention == .off)
                            }
                            if let error = shortcutError ?? registrationError { Text(error).foregroundStyle(.red) }
                            Text("Choose the shortcut you already use for clipboard history. Disable it in your other clipboard app first.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Text("Off stops new entries. Until quit keeps history in memory and removes its saved copy from disk. Choosing an item in History makes it your current clipboard.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Open History") {
                            guard !isReview else { return }
                            (NSApp.delegate as? AppDelegate)?.historyCoordinator?.show()
                        }
                        Spacer()
                        Button("Clear History…") { clearConfirmation = true }
                    }
                    Button("Add recent saved dictations to History") {
                        if !isReview {
                            (NSApp.delegate as? AppDelegate)?.historyCoordinator?.importRecentDictations()
                        }
                    }.disabled(viewModel.historySettings.retention == .off)
                    Text("History stays on this Mac. Known concealed and temporary clipboard items are skipped; applications do not always identify sensitive content. Clearing history does not delete your separately saved recordings or transcripts.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = viewModel.saveError { Text(error).foregroundStyle(.red) }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Thank you to Clipy and its contributors for their open-source work and inspiration.")
                            .foregroundStyle(.secondary)
                        Link("Clipy on GitHub", destination: URL(string: "https://github.com/Clipy/Clipy")!)
                    }
                    .font(.footnote)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            if recordingShortcut {
                KeyRecorderOverlay(onCapture: { code, modifiers in
                    // History needs a chord; a modifier pressed and released by itself
                    // leaves the recorder open for another attempt.
                    if modifiers.isEmpty && [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code) { return }
                    guard HistorySettings.isSafeShortcut(modifiers) else {
                        shortcutError = "Use a key with Command, Option, or Control."
                        recordingShortcut = false
                        return
                    }
                    guard code != viewModel.hotkeyKeyCode || HistorySettings.normalizedModifiers(modifiers) != HistorySettings.normalizedModifiers(viewModel.hotkeyModifiers) else {
                        shortcutError = "Choose a different shortcut from your dictation key."
                        recordingShortcut = false
                        return
                    }
                    viewModel.historySettings.shortcutKeyCode = code
                    viewModel.historySettings.shortcutModifiers = modifiers
                    shortcutError = nil
                    recordingShortcut = false
                }, onCancel: { recordingShortcut = false })
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { updateRegistrationError() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryCoordinator.shortcutStatusChanged)) { _ in updateRegistrationError() }
        .onChange(of: viewModel.historySettings) { _ in if !isReview { viewModel.save() } }
        .alert("Clear history on this Mac?", isPresented: $clearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                if !isReview { (NSApp.delegate as? AppDelegate)?.historyCoordinator?.clear() }
            }
        } message: { Text("This removes text and rich clipboard items from speakfree's history. Recordings and transcript archives are kept.") }
    }

    private func updateRegistrationError() {
        guard !isReview else { return }
        registrationError = (NSApp.delegate as? AppDelegate)?.historyCoordinator?.shortcutError
    }

}
