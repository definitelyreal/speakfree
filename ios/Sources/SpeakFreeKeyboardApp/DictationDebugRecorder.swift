// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation
import UIKit

/// Explicit, local-only diagnostics for development and TestFlight dogfooding. This is separate
/// from unified logging because transcript text must never enter ordinary production logs.
@MainActor
final class DictationDebugRecorder {
    struct Revision: Codable, Sendable {
        let elapsedMilliseconds: Int
        let text: String
        let confidence: Float?
    }

    struct Session: Codable, Identifiable, Sendable {
        let id: UUID
        let startedAt: Date
        var captureStartedAt: Date? = nil
        var firstPartialAt: Date? = nil
        var stopRequestedAt: Date? = nil
        var finishedAt: Date? = nil
        var previewModel: String
        var finalModel: String
        var revisions: [Revision]
        var finalText: String
        var finalConfidence: Float? = nil
        var finalPath: String? = nil
        var audioDurationSeconds: Double? = nil
        var outcome: String
        var error: String? = nil
    }

    static let shared = DictationDebugRecorder()
    static let sharedPreferenceKey = "developerDictationLoggingEnabled"

    private let preferenceKey = "SpeakFreeDeveloperDictationLoggingEnabled"
    private let persistenceQueue = DispatchQueue(
        label: "com.speakfree.keyboard.dictation-debug-log",
        qos: .utility
    )
    private var sessions: [Session] = []
    private var activeSessionID: UUID?
    private var persistenceWorkItem: DispatchWorkItem?

    private(set) var isEnabled: Bool

    private init() {
        if let saved = UserDefaults.standard.object(forKey: preferenceKey) as? Bool {
            isEnabled = saved
        } else {
#if DEBUG
            isEnabled = true
#else
            // TestFlight receipts are sandbox receipts. Public App Store receipts are not, so
            // shipped installs default to no transcript logging without a separate code path.
            isEnabled = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
        }
        UserDefaults(suiteName: "group.com.speakfree.keyboard")?.set(
            isEnabled,
            forKey: Self.sharedPreferenceKey
        )
        sessions = loadSessions()
    }

    var latestSession: Session? { sessions.last }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        UserDefaults(suiteName: "group.com.speakfree.keyboard")?.set(
            enabled,
            forKey: Self.sharedPreferenceKey
        )
        if !enabled { activeSessionID = nil }
    }

    func start(sessionID: UUID) {
        guard isEnabled else { return }
        activeSessionID = sessionID
        sessions.append(Session(
            id: sessionID,
            startedAt: Date(),
            previewModel: "Parakeet EOU 120M (320 ms)",
            finalModel: "Parakeet TDT 0.6B v2",
            revisions: [],
            finalText: "",
            outcome: "starting"
        ))
        trimAndPersist()
    }

    func captureStarted(sessionID: UUID) {
        mutate(sessionID) {
            $0.captureStartedAt = Date()
            $0.outcome = "recording"
        }
    }

    func recordPartial(sessionID: UUID, text: String, confidence: Float?) {
        guard !text.isEmpty else { return }
        mutate(sessionID) { session in
            let now = Date()
            if session.firstPartialAt == nil { session.firstPartialAt = now }
            let elapsed = Int(now.timeIntervalSince(session.startedAt) * 1_000)
            session.revisions.append(Revision(
                elapsedMilliseconds: elapsed,
                text: String(text.prefix(4_000)),
                confidence: confidence
            ))
            if session.revisions.count > 40 {
                session.revisions.removeFirst(session.revisions.count - 40)
            }
        }
    }

    func stopRequested(sessionID: UUID) {
        mutate(sessionID) {
            $0.stopRequestedAt = Date()
            $0.outcome = "finalizing"
        }
    }

    func finish(
        sessionID: UUID,
        text: String,
        confidence: Float?,
        finalPath: String,
        audioDurationSeconds: Double
    ) {
        mutate(sessionID) {
            $0.finishedAt = Date()
            $0.finalText = String(text.prefix(20_000))
            $0.finalConfidence = confidence
            $0.finalPath = finalPath
            $0.audioDurationSeconds = audioDurationSeconds
            $0.outcome = "finished"
        }
        if activeSessionID == sessionID { activeSessionID = nil }
        persist(immediately: true)
    }

    func fail(sessionID: UUID?, message: String, outcome: String = "failed") {
        guard let sessionID else { return }
        mutate(sessionID) {
            $0.finishedAt = Date()
            $0.outcome = outcome
            $0.error = message
        }
        if activeSessionID == sessionID { activeSessionID = nil }
        persist(immediately: true)
    }

    func clear() {
        sessions = []
        activeSessionID = nil
        persist(immediately: true)
    }

    var report: String {
        guard isEnabled else {
            return "Developer dictation logging is off. No transcript debug log is being recorded."
        }
        guard !sessions.isEmpty else { return "No dictation debug sessions recorded yet." }
        return sessions.suffix(10).map { render($0, includeRevisions: true) }
            .joined(separator: "\n\n")
    }

    var latestSummary: String {
        guard let session = latestSession else { return "No debug session recorded yet." }
        return render(session, includeRevisions: false)
    }

    private func mutate(_ id: UUID, _ body: (inout Session) -> Void) {
        guard isEnabled, let index = sessions.lastIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
        persist()
    }

    private func trimAndPersist() {
        if sessions.count > 10 { sessions.removeFirst(sessions.count - 10) }
        persist(immediately: true)
    }

    private func render(_ session: Session, includeRevisions: Bool) -> String {
        let startToCapture = milliseconds(from: session.startedAt, to: session.captureStartedAt)
        let firstPartial = milliseconds(from: session.captureStartedAt, to: session.firstPartialAt)
        let finalization = milliseconds(from: session.stopRequestedAt, to: session.finishedAt)
        let total = milliseconds(from: session.startedAt, to: session.finishedAt)
        let confidence = session.finalConfidence.map { String(format: "%.3f", $0) } ?? "unavailable"
        let audio = session.audioDurationSeconds.map { String(format: "%.2f s", $0) } ?? "unavailable"
        var lines = [
            "Session \(session.id.uuidString)",
            "Started: \(session.startedAt.formatted(.iso8601))",
            "Outcome: \(session.outcome)",
            "Preview: \(session.previewModel)",
            "Final: \(session.finalModel)",
            "Start → capture: \(startToCapture)",
            "Capture → first partial: \(firstPartial)",
            "Stop → final: \(finalization)",
            "Total: \(total)",
            "Audio: \(audio)",
            "Revisions: \(session.revisions.count)",
            "Final path: \(session.finalPath ?? "unavailable")",
            "Final confidence: \(confidence)",
            "Final text: \(session.finalText.isEmpty ? "<none>" : session.finalText)",
        ]
        if let error = session.error { lines.append("Error: \(error)") }
        if includeRevisions, !session.revisions.isEmpty {
            lines.append("Revision timeline:")
            lines.append(contentsOf: session.revisions.map {
                "  +\($0.elapsedMilliseconds) ms: \($0.text)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private func milliseconds(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "unavailable" }
        return "\(Int(end.timeIntervalSince(start) * 1_000)) ms"
    }

    private var logURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return support
            .appendingPathComponent("SpeakFreeDiagnostics", isDirectory: true)
            .appendingPathComponent("dictation-debug-sessions.json")
    }

    private func loadSessions() -> [Session] {
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    private func persist(immediately: Bool = false) {
        guard let logURL else { return }
        let snapshot = sessions
        persistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: logURL, options: [.atomic, .completeFileProtection])
            } catch {
                // Debug persistence must never interfere with recording or finalization.
            }
        }
        persistenceWorkItem = workItem
        if immediately {
            persistenceQueue.async(execute: workItem)
        } else {
            // Coalesce rapid 320 ms partial revisions. Writing the complete timeline for every
            // hypothesis would create avoidable I/O and memory pressure during recognition.
            persistenceQueue.asyncAfter(deadline: .now() + .milliseconds(750), execute: workItem)
        }
    }
}
