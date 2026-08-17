// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SpeakFreeDictationWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeakFreeDictationLiveActivity()
    }
}

struct SpeakFreeDictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeakFreeDictationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpeakFree Dictation").font(.headline)
                    Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: StopSpeakFreeDictationIntent(sessionID: context.attributes.sessionID)) {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.86))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status).font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopSpeakFreeDictationIntent(sessionID: context.attributes.sessionID)) {
                        Image(systemName: "stop.fill")
                    }
                    .tint(.red)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Speech stays on this iPhone.").font(.caption2)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.red)
            } compactTrailing: {
                Image(systemName: "stop.fill").foregroundStyle(.red)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }
}
