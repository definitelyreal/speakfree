// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import AppIntents

@available(iOS 18.0, *)
struct StartSpeakFreeDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start SpeakFree Dictation"
    static let description = IntentDescription(
        "Starts private on-device dictation without leaving your current app."
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await DictationSessionController.shared.startFromIntent()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(iOS 18.0, *)
struct SpeakFreeDictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSpeakFreeDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
