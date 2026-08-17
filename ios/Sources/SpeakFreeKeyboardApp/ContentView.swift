// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var dictation: DictationSessionController
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
        NavigationStack {
            Form {
                Section("SpeakFree Dictation") {
                    Label(
                        dictation.phase == .recording ? "Microphone on" : "Local Parakeet",
                        systemImage: dictation.phase == .recording ? "mic.fill" : "waveform"
                    )
                    .foregroundStyle(dictation.phase == .recording ? .red : .primary)

                    Text(dictation.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictationStatus")

                    if dictation.phase == .downloadingModel || dictation.phase == .preparingModel {
                        ProgressView(value: dictation.modelProgress)
                            .accessibilityIdentifier("dictationModelProgress")
                        Text(dictation.modelDownloadDetail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("dictationModelDownloadDetail")
                    }

                    if dictation.isModelDownloadCancellable {
                        Button("Cancel Download", role: .destructive) {
                            dictation.cancelModelDownload()
                        }
                        .accessibilityIdentifier("cancelDictationModelDownload")
                    }

                    if !dictation.transcript.isEmpty {
                        Text(dictation.transcript)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dictationTranscript")
                    }

                    if dictation.isModelActionAvailable {
                        Text("Requires a one-time local model download of about 657 MB. Wi-Fi is recommended.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(dictation.modelActionTitle) {
                            dictation.prepareModel()
                        }
                        .accessibilityIdentifier("prepareDictationModel")
                    }

                    if dictation.isStartAvailable {
                        Button("Start Dictation Session") {
                            dictation.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("startDictation")
                    }

                    if dictation.isStopAvailable {
                        Button("Stop and Finalize") {
                            dictation.stop()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .accessibilityIdentifier("stopDictation")
                        Button("Cancel Session", role: .destructive) {
                            dictation.cancel()
                        }
                        .accessibilityIdentifier("cancelDictation")
                    }

                    if #available(iOS 18.0, *) {
                        Text("For no-switch dictation, create a Shortcut using “Start SpeakFree Dictation,” then select that Shortcut for the Action Button, a Control Center Shortcut control, Back Tap, or Siri. A Live Activity keeps recording visible and provides Stop. You can also start here manually. In the keyboard, tap the red dictation key to claim the session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Start here, then manually return to the app where you want to type. In the SpeakFree keyboard, tap the red dictation key to claim the session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("iOS does not allow a custom keyboard itself to open the microphone or launch this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Enable SpeakFree Keyboard") {
                    Label("Open Settings → General → Keyboard → Keyboards", systemImage: "1.circle.fill")
                    Label("Tap Add New Keyboard and choose SpeakFree Keyboard", systemImage: "2.circle.fill")
                    Label("Return here and use the globe key to switch", systemImage: "3.circle.fill")
                    Button("Open SpeakFree Settings") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                    .accessibilityIdentifier("openAppSettings")
                    Text("iOS requires keyboards to be added manually in General → Keyboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Interactive Keyboard Lab") {
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

                Section("Privacy") {
                    Label("Swipe decoding stays on this device.", systemImage: "lock.shield")
                    Text("The keyboard works without Allow Full Access.")
                        .foregroundStyle(.secondary)
                    NavigationLink("SpeakFree Keyboard Privacy Policy") {
                        KeyboardPrivacyPolicyView()
                    }
                    .accessibilityIdentifier("keyboardPrivacyPolicy")
                }

                Section("Diagnostics") {
                    Button(diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") {
                        UIPasteboard.general.string = dictation.diagnosticReport
                        diagnosticsCopied = true
                    }
                    .accessibilityIdentifier("copyDiagnostics")
                    Text("The report excludes microphone audio and transcript text. Unified device logs record extension lifecycle, memory warnings, swipe-model failures, and dictation/download errors.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Developer Dictation Logging", isOn: Binding(
                        get: { dictation.debugLoggingEnabled },
                        set: { dictation.setDebugLoggingEnabled($0) }
                    ))
                    .accessibilityIdentifier("developerDictationLogging")

                    if dictation.debugLoggingEnabled {
                        Text("Local dogfood mode is on. It records dictated text, transcript revisions, model path, first-partial latency, finalization latency, and errors on this device. It never records microphone audio or uploads the log.")
                            .font(.footnote)
                            .foregroundStyle(.orange)

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

                Section("Acknowledgements") {
                    NavigationLink("FUTO model weights") {
                        AcknowledgementDocumentView(
                            title: "FUTO model weights",
                            resource: "FUTO-Model-Weights-License-1.0"
                        )
                    }
                    NavigationLink("English word-frequency data") {
                        AcknowledgementDocumentView(
                            title: "Word-frequency data",
                            resource: "WORD-FREQUENCY-LICENSE"
                        )
                    }
                    NavigationLink("ExecuTorch") {
                        AcknowledgementDocumentView(
                            title: "ExecuTorch",
                            resource: "EXECUTORCH-LICENSE.ai"
                        )
                    }
                    NavigationLink("XNNPACK") {
                        AcknowledgementDocumentView(
                            title: "XNNPACK",
                            resource: "XNNPACK-LICENSE.ai"
                        )
                    }
                    NavigationLink("cpuinfo") {
                        AcknowledgementDocumentView(
                            title: "cpuinfo",
                            resource: "CPUINFO-LICENSE.ai"
                        )
                    }
                    NavigationLink("pthreadpool") {
                        AcknowledgementDocumentView(
                            title: "pthreadpool",
                            resource: "PTHREADPOOL-LICENSE.ai"
                        )
                    }
                    NavigationLink("FXdiv") {
                        AcknowledgementDocumentView(
                            title: "FXdiv",
                            resource: "FXDIV-LICENSE.ai"
                        )
                    }
                    NavigationLink("KleidiAI") {
                        AcknowledgementDocumentView(
                            title: "KleidiAI",
                            resource: "KLEIDIAI-LICENSE.ai"
                        )
                    }
                    NavigationLink("Parakeet speech model") {
                        AcknowledgementDocumentView(
                            title: "Parakeet speech model",
                            resource: "PARAKEET-MODEL-ATTRIBUTION.ai"
                        )
                    }
                    NavigationLink("FluidAudio") {
                        AcknowledgementDocumentView(
                            title: "FluidAudio",
                            resource: "FLUIDAUDIO-LICENSE.ai"
                        )
                    }
                    Text("Powered by FUTO Swipe. FUTO model weights are used under the FUTO Model Weights License 1.0. SpeakFree's inference and decoding implementation is independent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SpeakFree Keyboard")
        }
#if DEBUG
        .onAppear { DictationUITestFixture.startIfRequested() }
#endif
    }
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
