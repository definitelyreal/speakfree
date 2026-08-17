// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import ActivityKit
import AppIntents
import Foundation

struct SpeakFreeDictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let startedAt: Date
        let status: String
    }

    let sessionID: UUID
}

enum SpeakFreeDictationCommandStore {
    static let appGroupIdentifier = "group.com.speakfree.keyboard"
    private static let stopFilename = "speakfree-dictation-stop-command-v1"

    struct StopCommand: Codable, Equatable, Sendable {
        let sessionID: UUID
        let requestID: UUID
    }

    static func requestStop(sessionID: UUID, requestID: UUID = UUID()) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw CommandError.appGroupUnavailable
        }
        try requestStop(sessionID: sessionID, requestID: requestID, in: container)
    }

    static func requestStop(sessionID: UUID, requestID: UUID, in container: URL) throws {
        let command = StopCommand(sessionID: sessionID, requestID: requestID)
        let url = container.appendingPathComponent(stopFilename)
        try JSONEncoder().encode(command).write(
            to: url,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    static func readStopCommand() -> StopCommand? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return readStopCommand(in: container)
    }

    static func readStopCommand(in container: URL) -> StopCommand? {
        guard let data = try? Data(
            contentsOf: container.appendingPathComponent(stopFilename)
        ) else { return nil }
        return try? JSONDecoder().decode(
            StopCommand.self,
            from: data
        )
    }

    enum CommandError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            "SpeakFree's shared command container is unavailable."
        }
    }
}

struct DictationStopCommandTracker: Equatable, Sendable {
    private(set) var sessionID: UUID?
    private(set) var lastRequestID: UUID?

    mutating func arm(
        sessionID: UUID,
        currentCommand: SpeakFreeDictationCommandStore.StopCommand?
    ) {
        self.sessionID = sessionID
        lastRequestID = currentCommand?.requestID
    }

    mutating func shouldStop(
        for command: SpeakFreeDictationCommandStore.StopCommand?
    ) -> Bool {
        guard let command,
              command.sessionID == sessionID,
              command.requestID != lastRequestID else { return false }
        lastRequestID = command.requestID
        return true
    }
}

@available(iOS 17.0, *)
struct StopSpeakFreeDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop SpeakFree Dictation"
    static let description = IntentDescription("Stops and finalizes the active local dictation session.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionID: String

    static var parameterSummary: some ParameterSummary {
        Summary("Stop SpeakFree Dictation")
    }

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        guard let sessionID = UUID(uuidString: sessionID) else {
            throw CommandError.invalidSession
        }
        try SpeakFreeDictationCommandStore.requestStop(sessionID: sessionID)
        return .result()
    }

    private enum CommandError: LocalizedError {
        case invalidSession

        var errorDescription: String? { "This dictation session is no longer valid." }
    }
}
