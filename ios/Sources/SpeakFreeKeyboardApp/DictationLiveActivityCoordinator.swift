// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import ActivityKit
import Foundation

@MainActor
final class DictationLiveActivityCoordinator {
    static let shared = DictationLiveActivityCoordinator()

    enum ActivityError: LocalizedError {
        case disabled

        var errorDescription: String? {
            "Live Activities are disabled. Enable them for SpeakFree before using background dictation."
        }
    }

    private var activity: Activity<SpeakFreeDictationActivityAttributes>?
    private var activeSessionID: UUID?

    @discardableResult
    func start(sessionID: UUID, required: Bool) async throws -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if required { throw ActivityError.disabled }
            return false
        }
        if let activity, activeSessionID == sessionID,
           activity.activityState == .active || activity.activityState == .stale {
            return true
        }
        await endOrphans()
        let now = Date()
        activity = try Activity.request(
            attributes: SpeakFreeDictationActivityAttributes(sessionID: sessionID),
            content: ActivityContent(
                state: .init(startedAt: now, status: "Listening locally"),
                staleDate: now.addingTimeInterval(310)
            ),
            pushType: nil
        )
        activeSessionID = sessionID
        return true
    }

    func update(status: String) async {
        guard let activity else { return }
        await activity.update(ActivityContent(
            state: .init(startedAt: activity.content.state.startedAt, status: status),
            staleDate: Date().addingTimeInterval(310)
        ))
    }

    func end(status: String) async {
        let sessionID = activeSessionID
        let candidates = Activity<SpeakFreeDictationActivityAttributes>.activities.filter {
            sessionID == nil || $0.attributes.sessionID == sessionID
        }
        for candidate in candidates {
            await candidate.end(
                ActivityContent(
                    state: .init(startedAt: candidate.content.state.startedAt, status: status),
                    staleDate: nil
                ),
                dismissalPolicy: .after(Date().addingTimeInterval(15))
            )
        }
        self.activity = nil
        activeSessionID = nil
    }

    func endOrphans() async {
        for orphan in Activity<SpeakFreeDictationActivityAttributes>.activities {
            await orphan.end(
                ActivityContent(
                    state: .init(
                        startedAt: orphan.content.state.startedAt,
                        status: "Session ended"
                    ),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
        }
        activity = nil
        activeSessionID = nil
    }

    /// Suspends until the exact session's Live Activity is no longer active. AudioRecordingIntent
    /// requires the activity to remain present for the recording, so dismissal is a stop signal,
    /// not merely a UI change.
    func waitUntilInactive(sessionID: UUID) async {
        guard activeSessionID == sessionID, let activity else { return }
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        for await state in activity.activityStateUpdates {
            guard !Task.isCancelled else { return }
            if state == .dismissed || state == .ended { return }
        }
    }

    func isActive(sessionID: UUID) -> Bool {
        guard activeSessionID == sessionID, let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }
}
