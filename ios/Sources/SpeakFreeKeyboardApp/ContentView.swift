// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var standardText = ""
    @State private var emailText = ""
    @State private var urlText = ""
    @State private var numberText = ""
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Form {
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
                    TextField("Search", text: $searchText)
                        .submitLabel(.search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("searchTextField")
                    Button("Clear All Test Fields") {
                        standardText = ""
                        emailText = ""
                        urlText = ""
                        numberText = ""
                        searchText = ""
                    }
                    .accessibilityIdentifier("clearTestFields")
                }

                Section("Privacy") {
                    Label("Swipe decoding stays on this device.", systemImage: "lock.shield")
                    Text("The keyboard works without Allow Full Access.")
                        .foregroundStyle(.secondary)
                    Link(
                        "SpeakFree Keyboard Privacy Policy",
                        destination: URL(string: "https://definitelyreal.github.io/speakfree/keyboard-privacy.html")!
                    )
                    .accessibilityIdentifier("keyboardPrivacyPolicy")
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
                    Text("Powered by FUTO Swipe. FUTO model weights are used under the FUTO Model Weights License 1.0. SpeakFree's inference and decoding implementation is independent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SpeakFree Keyboard")
        }
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
