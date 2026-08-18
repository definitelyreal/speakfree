// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var dictation: DictationSessionController
    @State private var selectedTab: SpeakFreeAppTab = .home
    @State private var standardText = ""
    @State private var emailText = ""
    @State private var urlText = ""
    @State private var numberText = ""
    @State private var numberPadText = ""
    @State private var decimalPadText = ""
    @State private var phonePadText = ""
    @State private var namePhonePadText = ""
    @State private var socialText = ""
    @State private var searchText = ""
    @State private var passwordText = ""
    @State private var diagnosticsCopied = false
    @State private var debugLogCopied = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SpeakFreeHomeScreen(dictation: dictation, selectedTab: $selectedTab)
            }
            .tabItem { Label("Home", systemImage: "waveform") }
            .tag(SpeakFreeAppTab.home)
            .accessibilityIdentifier("homeTab")

            NavigationStack {
                KeyboardLabScreen(
                    standardText: $standardText,
                    emailText: $emailText,
                    urlText: $urlText,
                    numberText: $numberText,
                    numberPadText: $numberPadText,
                    decimalPadText: $decimalPadText,
                    phonePadText: $phonePadText,
                    namePhonePadText: $namePhonePadText,
                    socialText: $socialText,
                    searchText: $searchText,
                    passwordText: $passwordText
                )
            }
            .tabItem { Label("Keyboard", systemImage: "keyboard") }
            .tag(SpeakFreeAppTab.keyboard)
            .accessibilityIdentifier("keyboardTab")

            NavigationStack {
                SpeakFreeSettingsScreen(
                    dictation: dictation,
                    diagnosticsCopied: $diagnosticsCopied,
                    debugLogCopied: $debugLogCopied
                )
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(SpeakFreeAppTab.settings)
            .accessibilityIdentifier("settingsTab")
        }
#if DEBUG
        .onAppear { DictationUITestFixture.startIfRequested() }
#endif
    }
}

private enum SpeakFreeAppTab: Hashable {
    case home
    case keyboard
    case settings
}

private struct SpeakFreeHomeScreen: View {
    @ObservedObject var dictation: DictationSessionController
    @Binding var selectedTab: SpeakFreeAppTab

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                readinessHeader
                dictationCard
                KeyboardPreviewCard {
                    selectedTab = .keyboard
                }
                if dictation.phase == .recording || !dictation.transcript.isEmpty {
                    latestTranscriptCard
                }
                setupCard
                privacyStrip
            }
            .padding(.horizontal, 16)
            // The iOS 26 floating tab bar overlaps scroll content unless the
            // final card has enough room to travel completely above it.
            .padding(.bottom, 112)
        }
        .background(SpeakFreePalette.canvas.ignoresSafeArea())
        .navigationTitle("SpeakFree")
        .navigationBarTitleDisplayMode(.large)
    }

    private var readinessHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: statusIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.variableColor.iterative, isActive: dictation.phase == .recording)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(dictation.phase == .recording ? "Listening on this iPhone" : "Private, on-device dictation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusBadge)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private var dictationCard: some View {
        SpeakFreeCard {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    WaveformMark(isRecording: dictation.phase == .recording)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(dictation.phase == .recording ? "Speak naturally" : "Local Parakeet")
                            .font(.title3.weight(.bold))
                        Text(dictation.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("dictationStatus")
                    }
                    Spacer(minLength: 0)
                }

                if dictation.phase == .downloadingModel || dictation.phase == .preparingModel {
                    VStack(spacing: 7) {
                        ProgressView(value: dictation.modelProgress)
                            .tint(SpeakFreePalette.coral)
                            .accessibilityIdentifier("dictationModelProgress")
                        HStack {
                            Text(dictation.modelDownloadDetail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("dictationModelDownloadDetail")
                            Spacer()
                            Text("Downloads in background")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if dictation.isModelActionAvailable {
                    Button(dictation.modelActionTitle) {
                        dictation.prepareModel()
                    }
                    .buttonStyle(SpeakFreePrimaryButtonStyle())
                    .accessibilityIdentifier("prepareDictationModel")

                    Text("One-time local download · about 689 MB · Wi-Fi recommended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if dictation.isModelDownloadCancellable {
                    Button("Cancel Download", role: .destructive) {
                        dictation.cancelModelDownload()
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("cancelDictationModelDownload")
                }

                if dictation.isStartAvailable {
                    Button {
                        dictation.start()
                    } label: {
                        Label("Start Dictation", systemImage: "mic.fill")
                    }
                    .buttonStyle(SpeakFreePrimaryButtonStyle())
                    .accessibilityIdentifier("startDictation")
                }

                if dictation.isStopAvailable {
                    HStack(spacing: 10) {
                        Button {
                            dictation.stop()
                        } label: {
                            Label("Stop & Finalize", systemImage: "stop.fill")
                        }
                        .buttonStyle(SpeakFreePrimaryButtonStyle(tint: SpeakFreePalette.coral))
                        .accessibilityIdentifier("stopDictation")

                        Button("Cancel", role: .destructive) {
                            dictation.cancel()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("cancelDictation")
                    }
                }
            }
        }
    }

    private var latestTranscriptCard: some View {
        SpeakFreeCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Latest dictation", systemImage: "text.quote")
                    .font(.headline)
                    .foregroundStyle(SpeakFreePalette.ink)
                Text(dictation.transcript)
                    .font(.body)
                    .lineLimit(4, reservesSpace: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("dictationTranscript")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setupCard: some View {
        SpeakFreeCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Use SpeakFree anywhere")
                    .font(.headline)
                SetupRow(number: 1, title: "Enable the keyboard", detail: "Settings → General → Keyboard")
                SetupRow(number: 2, title: "Start local dictation", detail: shortcutDetail)
                SetupRow(number: 3, title: "Tap the red SF key", detail: "Your words revise safely in place")
            }
        }
    }

    private var privacyStrip: some View {
        HStack(spacing: 18) {
            Label("On device", systemImage: "iphone.gen3")
            Label("No account", systemImage: "person.crop.circle.badge.xmark")
            Label("No Full Access", systemImage: "lock.fill")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var shortcutDetail: String {
        if #available(iOS 18.0, *) {
            return "App, Shortcut, Action Button, Back Tap, or Siri"
        }
        return "Start here, then return to the app where you type"
    }

    private var statusTitle: String {
        switch dictation.phase {
        case .ready: "Ready to speak"
        case .recording: "Microphone on"
        case .finalizing: "Polishing your words"
        case .downloadingModel: "Getting voice model"
        case .preparingModel: "Preparing local AI"
        case .starting: "Starting microphone"
        case .modelRequired: "Finish setup"
        case .failed: "Needs attention"
        }
    }

    private var statusBadge: String {
        switch dictation.phase {
        case .ready: "READY"
        case .recording: "LIVE"
        case .finalizing: "FINALIZING"
        case .downloadingModel: "DOWNLOADING"
        case .preparingModel, .starting: "LOADING"
        case .modelRequired: "SETUP"
        case .failed: "ERROR"
        }
    }

    private var statusIcon: String {
        switch dictation.phase {
        case .ready: "checkmark"
        case .recording: "mic.fill"
        case .finalizing: "sparkles"
        case .downloadingModel: "arrow.down"
        case .preparingModel, .starting: "ellipsis"
        case .modelRequired: "arrow.down.circle"
        case .failed: "exclamationmark"
        }
    }

    private var statusColor: Color {
        switch dictation.phase {
        case .failed: .orange
        case .recording, .finalizing: SpeakFreePalette.coral
        case .ready: SpeakFreePalette.green
        default: SpeakFreePalette.blue
        }
    }
}

private struct KeyboardLabScreen: View {
    @Binding var standardText: String
    @Binding var emailText: String
    @Binding var urlText: String
    @Binding var numberText: String
    @Binding var numberPadText: String
    @Binding var decimalPadText: String
    @Binding var phonePadText: String
    @Binding var namePhonePadText: String
    @Binding var socialText: String
    @Binding var searchText: String
    @Binding var passwordText: String

    var body: some View {
        Form {
            Section {
                KeyboardPreviewCard(action: nil)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Enable SpeakFree") {
                SetupRow(number: 1, title: "Open iPhone keyboard settings", detail: "Settings → General → Keyboard → Keyboards")
                SetupRow(number: 2, title: "Add SpeakFree Keyboard", detail: "Full Access is not required")
                SetupRow(number: 3, title: "Switch with the globe key", detail: "Then try typing below")
                Button("Open App Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                .accessibilityIdentifier("openAppSettings")
                Text("Apple requires third-party keyboards to be added manually in General → Keyboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Try every keyboard layout") {
                TextField("Standard text", text: $standardText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("standardTextField")
                TextField("Email address", text: $emailText)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("emailTextField")
                TextField("Web address", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("urlTextField")
                TextField("Number", text: $numberText)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("numberTextField")
                TextField("Number pad", text: $numberPadText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("numberPadTextField")
                TextField("Decimal pad", text: $decimalPadText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("decimalPadTextField")
                TextField("Phone number", text: $phonePadText)
                    .keyboardType(.phonePad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("phonePadTextField")
                TextField("Name or phone", text: $namePhonePadText)
                    .keyboardType(.namePhonePad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("namePhonePadTextField")
                TextField("Social handle", text: $socialText)
                    .keyboardType(.twitter)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("socialTextField")
                TextField("Search", text: $searchText)
                    .submitLabel(.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("searchTextField")
                SecureField("Password (system keyboard)", text: $passwordText)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("secureTextField")
                Button("Clear All Test Fields") {
                    standardText = ""
                    emailText = ""
                    urlText = ""
                    numberText = ""
                    numberPadText = ""
                    decimalPadText = ""
                    phonePadText = ""
                    namePhonePadText = ""
                    socialText = ""
                    searchText = ""
                    passwordText = ""
                }
                .accessibilityIdentifier("clearTestFields")
            }
        }
        .navigationTitle("Keyboard")
    }
}

private struct SpeakFreeSettingsScreen: View {
    @ObservedObject var dictation: DictationSessionController
    @Binding var diagnosticsCopied: Bool
    @Binding var debugLogCopied: Bool

    var body: some View {
        Form {
            Section("Voice engine") {
                SettingsValueRow(icon: "waveform", title: "Dictation engine", value: "Local Parakeet")
                SettingsValueRow(icon: "internaldrive", title: "Downloaded models", value: "About 689 MB")
                Text("SpeakFree uses a fast live model and a separate high-accuracy final model. Speech stays on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Swipe and speech processing stay on this device", systemImage: "lock.shield.fill")
                Label("Keyboard works without Allow Full Access", systemImage: "checkmark.shield.fill")
                NavigationLink("SpeakFree Keyboard Privacy Policy") {
                    KeyboardPrivacyPolicyView()
                }
                .accessibilityIdentifier("keyboardPrivacyPolicy")
            }

            Section("Developer diagnostics") {
                Button(diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") {
                    UIPasteboard.general.string = dictation.diagnosticReport
                    diagnosticsCopied = true
                }
                .accessibilityIdentifier("copyDiagnostics")
                Text("The standard report excludes microphone audio and transcript text.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Developer Dictation Logging", isOn: Binding(
                    get: { dictation.debugLoggingEnabled },
                    set: { dictation.setDebugLoggingEnabled($0) }
                ))
                .accessibilityIdentifier("developerDictationLogging")

                if dictation.debugLoggingEnabled {
                    Label("Dogfood mode: transcript text is stored locally", systemImage: "ladybug.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Text("Records transcript revisions, model path, first-partial latency, finalization latency, real-time factor, and errors. Microphone audio is never stored or uploaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(dictation.debugLatestSummary)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dictationDebugSummary")
                    Button(debugLogCopied ? "Debug Log Copied" : "Copy Dictation Debug Log") {
                        UIPasteboard.general.string = dictation.dictationDebugReport
                        debugLogCopied = true
                    }
                    .accessibilityIdentifier("copyDictationDebugLog")
                    Button("Clear Dictation Debug Log", role: .destructive) {
                        dictation.clearDictationDebugLog()
                        debugLogCopied = false
                    }
                    .accessibilityIdentifier("clearDictationDebugLog")
                }
            }

            acknowledgements
        }
        .navigationTitle("Settings")
    }

    private var acknowledgements: some View {
        Section("Acknowledgements") {
            acknowledgement("FUTO model weights", "FUTO-Model-Weights-License-1.0")
            acknowledgement("English word-frequency data", "WORD-FREQUENCY-LICENSE")
            acknowledgement("ExecuTorch", "EXECUTORCH-LICENSE.ai")
            acknowledgement("XNNPACK", "XNNPACK-LICENSE.ai")
            acknowledgement("cpuinfo", "CPUINFO-LICENSE.ai")
            acknowledgement("pthreadpool", "PTHREADPOOL-LICENSE.ai")
            acknowledgement("FXdiv", "FXDIV-LICENSE.ai")
            acknowledgement("KleidiAI", "KLEIDIAI-LICENSE.ai")
            acknowledgement("Parakeet speech model", "PARAKEET-MODEL-ATTRIBUTION.ai")
            acknowledgement("FluidAudio", "FLUIDAUDIO-LICENSE.ai")
            Text("Powered by FUTO Swipe. SpeakFree's inference and decoding implementation is independent.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func acknowledgement(_ title: String, _ resource: String) -> some View {
        NavigationLink(title) {
            AcknowledgementDocumentView(title: title, resource: resource)
        }
    }
}

private struct KeyboardPreviewCard: View {
    let action: (() -> Void)?

    var body: some View {
        SpeakFreeCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SpeakFree Keyboard")
                            .font(.headline)
                        Text("Swipe, type, or speak")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let action {
                        Button("Try it", action: action)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(16)

                MiniatureKeyboard()
            }
        }
        .accessibilityElement(children: action == nil ? .ignore : .contain)
        .accessibilityLabel("SpeakFree keyboard preview")
    }
}

private struct MiniatureKeyboard: View {
    private let rows: [[String]] = [
        ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
        ["A", "S", "D", "F", "G", "H", "J", "K", "L"],
        ["Z", "X", "C", "V", "B", "N", "M"],
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("the")
                Spacer()
                Text("to")
                Spacer()
                Text("and")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .frame(height: 28)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { letter in
                        Text(letter)
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(0.09), radius: 0, y: 1)
                    }
                }
                .padding(.horizontal, index == 1 ? 18 : (index == 2 ? 38 : 7))
            }

            HStack(spacing: 5) {
                MiniSpecialKey(label: "123", width: 44)
                MiniSpecialKey(systemImage: "globe", width: 38)
                MiniSpecialKey(label: "space", width: nil)
                MiniSpecialKey(
                    label: "SF",
                    width: 44,
                    tint: SpeakFreePalette.coral,
                    foreground: .white
                )
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 9)
        }
        .background(SpeakFreePalette.keyboard)
    }
}

private struct MiniSpecialKey: View {
    var label: String?
    var systemImage: String?
    var width: CGFloat?
    var tint: Color = SpeakFreePalette.keyUtility
    var foreground: Color = .primary

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Text(label ?? "")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(foreground)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, height: 32)
        .background(tint, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.09), radius: 0, y: 1)
    }
}

private struct SetupRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(SpeakFreePalette.blue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsValueRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(SpeakFreePalette.blue, in: RoundedRectangle(cornerRadius: 7))
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpeakFreeCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.primary.opacity(0.05), lineWidth: 1)
            }
    }
}

private struct WaveformMark: View {
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach([12.0, 24.0, 34.0, 22.0, 14.0], id: \.self) { height in
                Capsule()
                    .fill(isRecording ? SpeakFreePalette.coral : SpeakFreePalette.blue)
                    .frame(width: 4, height: height)
            }
        }
        .frame(width: 52, height: 52)
        .background((isRecording ? SpeakFreePalette.coral : SpeakFreePalette.blue).opacity(0.12), in: Circle())
        .accessibilityHidden(true)
    }
}

private struct SpeakFreePrimaryButtonStyle: ButtonStyle {
    var tint: Color = SpeakFreePalette.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(tint.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private enum SpeakFreePalette {
    static let canvas = Color(.systemGroupedBackground)
    static let ink = Color(red: 0.10, green: 0.12, blue: 0.16)
    static let blue = Color(red: 0.17, green: 0.39, blue: 0.94)
    static let green = Color(red: 0.08, green: 0.60, blue: 0.37)
    static let coral = Color(red: 0.94, green: 0.25, blue: 0.28)
    static let keyboard = Color(red: 0.82, green: 0.84, blue: 0.87)
    static let keyUtility = Color(red: 0.67, green: 0.70, blue: 0.74)
}

private struct KeyboardPrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("SpeakFree Keyboard Privacy Policy").font(.title.bold())
                Text("SpeakFree processes typing, swipe gestures, and optional speech recognition locally on your device.")
                Group {
                    Text("Data collection").font(.headline)
                    Text("SpeakFree has no advertising, analytics, tracking, accounts, or telemetry. It does not sell or share personal data.")
                    Text("Dictation").font(.headline)
                    Text("Microphone audio is processed by downloaded local Parakeet models and is not retained as an audio recording. On iOS 18 or later, a user-created Shortcut can start the same local session in the background from the Action Button, a Control Center Shortcut control, Back Tap, or Siri; a visible Live Activity provides its session-bound Stop control. Current and terminal transcripts use iOS file protection for keyboard handoff. The current file expires shortly; terminal recovery files expire after 24 hours when the app next opens.")
                    Text("Keyboard data").font(.headline)
                    Text("The keyboard does not transmit keystrokes, swipe paths, document context, audio, or model results. It works without Allow Full Access. An active claim keeps only the dictated text and nearby context needed to prove the suffix it owns; a completed claim is reduced to identifiers that prevent duplicate insertion.")
                    Text("Optional developer diagnostics").font(.headline)
                    Text("Developer Dictation Logging stores up to ten recent transcript revision timelines, timing measurements, model paths, and errors locally on this device. It never stores microphone audio or uploads the log. Development and TestFlight builds may default it on; public App Store builds default it off. You can disable or clear it in Diagnostics.")
                    Text("Models").font(.headline)
                    Text("Downloaded Parakeet model files remain on device until app data is cleared. Model downloads are the containing app's only network use.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementDocumentView: View {
    let title: String
    let resource: String

    private var document: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled acknowledgement could not be loaded."
        }
        return contents
    }

    var body: some View {
        ScrollView {
            Text(verbatim: document)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
