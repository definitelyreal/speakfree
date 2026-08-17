// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import SwiftUI

@main
struct SpeakFreeKeyboardApp: App {
    @UIApplicationDelegateAdaptor(SpeakFreeApplicationDelegate.self) private var appDelegate
    @StateObject private var dictation = DictationSessionController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dictation)
        }
    }
}
