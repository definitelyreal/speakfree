// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b/agent:code_elegance_audit · 2026-10-01
// Claude · 2026-09-24 · Edit Mode V1
import Foundation

// The brain of one Edit Mode session, with no AppKit in it. The window (EditWindowController)
// renders what this holds and forwards keys and edits into it; the controller
// (EditSessionController) wires recording and insertion. Everything a person can do in the window
// is a method here, so the behavior is testable headless: Return, Esc, cleanup on and off,
// versions, restore, compare, commit and retain.

// MARK: - Settings snapshot

public enum EditAnimationStyle: String, Codable, CaseIterable, Equatable {
    /// iPhone-like: new text shows lighter and tinted, then eases to normal as fixes land.
    case settle
    /// No motion: text appears normally and fixes swap in place. Reduce Motion always uses this.
    case quiet

    public var displayName: String { self == .settle ? "Settle" : "Quiet" }

    public static func resolve(_ raw: String?) -> EditAnimationStyle {
        EditAnimationStyle(rawValue: raw?.lowercased() ?? "") ?? .settle
    }
}

public struct EditModeSettings: Equatable {
    /// The user's cleanup switch (Settings checkbox or the window's options).
    public var cleanupEnabled: Bool
    /// The first-use cloud explanation was accepted. Without it nothing is ever sent.
    public var consentGiven: Bool
    public var model: CleanupService.Model
    public var animation: EditAnimationStyle

    public init(cleanupEnabled: Bool, consentGiven: Bool, model: CleanupService.Model,
                animation: EditAnimationStyle) {
        self.cleanupEnabled = cleanupEnabled
        self.consentGiven = consentGiven
        self.model = model
        self.animation = animation
    }

    public static func from(_ config: Config) -> EditModeSettings {
        EditModeSettings(
            cleanupEnabled: config.editModeCleanup?.value ?? true,
            consentGiven: !(config.editModeCloudConsent ?? "").isEmpty,
            model: CleanupService.Model.resolve(config.editModeCleanupModel),
            animation: EditAnimationStyle.resolve(config.editModeAnimation))
    }

    /// Text may leave the Mac only when both the switch is on AND consent was given.
    public var sendsToCloud: Bool { cleanupEnabled && consentGiven }
}

// MARK: - Seams

/// The cleanup call, abstracted so tests drive the core with a scripted fake.
public protocol EditCleanupRunning: AnyObject {
    func cleanup(raw: String, pipelineText: String, model: CleanupService.Model,
                 cancellation: CleanupCancellation) async -> Result<[SpanEdit], CleanupService.CleanupError>
}

extension CleanupService: EditCleanupRunning {}

/// The clipboard, abstracted so tests never touch the real pasteboard.
public protocol EditClipboard: AnyObject {
    @discardableResult
    func copy(_ text: String) -> Bool
}

// MARK: - Outcomes and events

public enum EditReturnOutcome: Equatable {
    /// A take is still recording or transcribing. It will be finished and shown first; the core
    /// emits `.readyToCommit` once it is on screen (never silently omit it).
    case waitingForTake
    /// Nothing to insert: the session closes.
    case nothingToInsert
    /// Insert this text (paragraphs joined by a blank line).
    case commit(String)
}

public enum EditEscapeOutcome: Equatable {
    /// Esc while recording: that take is thrown away, earlier paragraphs stay.
    case discardedTake
    /// First Esc on a non-empty draft: "Press Esc again to discard".
    case armed
    /// The session is closed and its text discarded.
    case closed
}

public enum EditVersionKind: String, Equatable, CaseIterable {
    case original, previous, current
}

public enum EditCoreEvent: Equatable {
    /// A new paragraph arrived (instant on-device text).
    case appended(UUID)
    /// A paragraph's text changed for a reason other than typing in it (cleanup, restore, undo of
    /// a change, compare). `animate` is true when a cleanup settled.
    case replaced(UUID, animate: Bool)
    /// Paragraphs were merged, removed or re-ordered: re-render everything.
    case restructured
    /// Header/footer state changed (recording, cleaning counts, notices, options).
    case status
    /// A comparison started, progressed, finished or was dismissed.
    case comparison
    /// The take Return was waiting for is now on screen; insert now.
    case readyToCommit
}

/// One side of an on-demand comparison.
public struct EditCandidate: Equatable {
    public enum Status: Equatable {
        case running
        case ready(text: String, edits: [SpanEdit])
        case failed(String)
    }
    public let label: String          // "A" or "B"; the model stays hidden until one is chosen
    public let model: CleanupService.Model
    public var status: Status
    public var latencyMs: Int?
}

public struct EditComparison: Equatable {
    public let segmentID: UUID
    public let sourceRevision: UUID
    public let sourceText: String
    public var candidates: [EditCandidate]
    /// Set once a candidate is used, to reveal which model was which.
    public var chosenLabel: String?
    /// True when the paragraph changed after the comparison started (it can no longer apply).
    public var invalidated: Bool
}

/// What the window shows for one paragraph's history.
public struct EditParagraphVersions: Equatable {
    public let segmentID: UUID
    public let original: String?
    public let previous: String?
    public let current: String
    /// Cleanup changes still visible in the current text, each individually undoable.
    public let changes: [SpanEdit]
    /// How many dictations were merged into this paragraph (1 when never merged).
    public let takes: Int
}

/// The committed session, handed to Recents (written only when recordings are saved).
public struct EditSessionArtifact: Codable, Equatable {
    public struct Paragraph: Codable, Equatable {
        public let text: String
        public let original: String?
        public let componentStems: [String]
        public let revisions: [SegmentRevision]
    }
    public let sessionID: UUID
    public let committedAt: Date
    public let text: String
    public let paragraphs: [Paragraph]
    public let targetApp: String?
}

// MARK: - Core

@MainActor
public final class EditSessionCore {

    public let model: EditSessionModel
    public private(set) var settings: EditModeSettings
    public var onEvent: ((EditCoreEvent) -> Void)?

    // Recording posture
    public private(set) var recordingSegmentID: UUID?
    /// Takes whose audio has stopped and whose text has not arrived yet.
    public private(set) var transcribingSegmentIDs: [UUID] = []
    /// Return was pressed while a take was unfinished; insert once it is shown.
    public private(set) var pendingCommit = false
    /// Return, insertion, and the saved artifact share the same text and revisions.
    private struct CommitSnapshot {
        let text: String
        let paragraphs: [EditSessionArtifact.Paragraph]
    }
    private var commitSnapshot: CommitSnapshot?

    // Cleanup bookkeeping
    public static let maxConcurrentCleanups = 2
    private var queue: [UUID] = []
    /// Queued paragraphs whose cleanup he asked for explicitly (may start from a hand edit).
    private var explicitRetries: Set<UUID> = []
    private struct InFlight {
        let attemptID: UUID
        let cancellation: CleanupCancellation
        let startedAt: Date
        let model: CleanupService.Model
    }
    private var inFlight: [UUID: InFlight] = [:]
    public private(set) var failures: [UUID: CleanupService.CleanupError] = [:]
    /// A failure that would repeat for every paragraph (CLI missing, not logged in, usage limit).
    public private(set) var cleanupUnavailable: CleanupService.CleanupError?
    public private(set) var rejectedForMeaning: Int = 0

    // Esc guard
    public static let escArmWindow: TimeInterval = 3
    public private(set) var escArmedUntil: Date?

    // Notices (retained draft, copied text, compare result)
    public private(set) var notice: String?

    public private(set) var comparison: EditComparison?
    private var compareCancellations: [CleanupCancellation] = []

    private let cleaner: EditCleanupRunning
    private let clipboard: EditClipboard?
    private let latencyLog: EditLatencyLog?
    private let shuffle: ([CleanupService.Model]) -> [CleanupService.Model]
    private var stoppedAt: [UUID: Date] = [:]
    public let targetAppName: String?

    public init(sessionID: UUID = UUID(), persistenceEnabled: Bool, settings: EditModeSettings,
                cleaner: EditCleanupRunning, clipboard: EditClipboard? = nil,
                latencyLog: EditLatencyLog? = nil, targetAppName: String? = nil,
                shuffle: @escaping ([CleanupService.Model]) -> [CleanupService.Model] = { $0.shuffled() },
                now: Date = Date()) {
        self.model = EditSessionModel(sessionID: sessionID, persistenceEnabled: persistenceEnabled,
                                      now: now)
        self.settings = settings
        self.cleaner = cleaner
        self.clipboard = clipboard
        self.latencyLog = latencyLog
        self.targetAppName = targetAppName
        self.shuffle = shuffle
    }

    // MARK: Read-only views

    public var state: EditSessionState { model.state }
    public var isOpen: Bool { model.state.lifecycle == .open }

    /// Paragraphs on screen, in order (a take still recording or transcribing has none yet).
    public var displayedSegments: [EditSegment] {
        model.state.segments.filter { $0.state != .recording }
    }

    public func segment(_ id: UUID) -> EditSegment? {
        model.state.segments.first(where: { $0.id == id })
    }

    /// Exactly what Return inserts: each non-empty paragraph, joined by a blank line (a real
    /// paragraph break becomes two line breaks once it leaves the window).
    public var commitText: String {
        displayedSegments.map(\.currentText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    public var hasDraft: Bool {
        !commitText.isEmpty || recordingSegmentID != nil || !transcribingSegmentIDs.isEmpty
    }

    public var cleaningCount: Int {
        model.state.segments.filter { $0.state == .cleaning }.count + queue.count
    }

    public var failedCount: Int { model.state.segments.filter { $0.state == .failed }.count }

    /// The footer's cloud phrase. Always states whether text leaves the Mac.
    public var cleanupStatusLine: String {
        if !settings.cleanupEnabled { return "Cleanup off (on-device only)" }
        if !settings.consentGiven { return "Cleanup off until you allow Claude in Settings" }
        if let err = cleanupUnavailable { return "Cleanup unavailable: \(err.userMessage)" }
        return "Cleanup by Claude (cloud) · \(settings.model.displayName)"
    }

    /// "1 paragraph still cleaning" style hint shown before Return is pressed (review).
    public var progressLine: String? {
        var parts: [String] = []
        if recordingSegmentID != nil { parts.append("Recording") }
        if !transcribingSegmentIDs.isEmpty { parts.append("Transcribing") }
        let cleaning = cleaningCount
        if cleaning > 0 {
            parts.append(cleaning == 1 ? "1 paragraph still cleaning" : "\(cleaning) paragraphs still cleaning")
        }
        let failed = failedCount
        if failed > 0 {
            parts.append(failed == 1 ? "cleanup failed on 1 paragraph" : "cleanup failed on \(failed) paragraphs")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public func failureMessage(for segmentID: UUID) -> String? {
        failures[segmentID]?.userMessage
    }

    // MARK: Takes

    /// fn tap started a take. Returns its segment id.
    @discardableResult
    public func beginTake(now: Date = Date()) -> UUID {
        let id = UUID()
        model.dispatch(.beginSegment(segmentID: id), now: now)
        recordingSegmentID = id
        escArmedUntil = nil
        // A new take means he is still dictating: an earlier Return that was waiting on a take
        // no longer fires by itself.
        pendingCommit = false
        notice = nil
        onEvent?(.status)
        return id
    }

    /// The take's audio stopped; its text is being transcribed.
    public func takeStopped(_ segmentID: UUID, now: Date = Date()) {
        if recordingSegmentID == segmentID { recordingSegmentID = nil }
        if !transcribingSegmentIDs.contains(segmentID) { transcribingSegmentIDs.append(segmentID) }
        stoppedAt[segmentID] = now
        onEvent?(.status)
    }

    /// The on-device text arrived: show it at once as a new paragraph, then clean it up in the
    /// background. `componentStem` is the archived recording behind it (nil when not saved).
    public func takeTranscribed(_ segmentID: UUID, raw: String, pipelineText: String,
                                componentStem: String? = nil, now: Date = Date()) {
        if recordingSegmentID == segmentID { recordingSegmentID = nil }
        transcribingSegmentIDs.removeAll { $0 == segmentID }
        let text = pipelineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            takeProducedNothing(segmentID, now: now)
            return
        }
        let outcome = model.dispatch(.provisional(segmentID: segmentID, raw: raw, pipelineText: text),
                                     now: now)
        guard outcome == .applied else { onEvent?(.status); return }
        if let stem = componentStem {
            model.dispatch(.setComponentStem(segmentID: segmentID, stem: stem), now: now)
        }
        if let stopped = stoppedAt.removeValue(forKey: segmentID) {
            latencyLog?.record(.init(event: "provisional", model: nil,
                                     ms: Int(now.timeIntervalSince(stopped) * 1000),
                                     chars: text.count, applied: nil, rejected: nil, outcome: "ok"))
        }
        onEvent?(.appended(segmentID))
        enqueueCleanup(segmentID)
        firePendingCommitIfReady()
        onEvent?(.status)
    }

    /// The take ended with no usable text (too short, silent, failed, cancelled).
    public func takeProducedNothing(_ segmentID: UUID, now: Date = Date()) {
        if recordingSegmentID == segmentID { recordingSegmentID = nil }
        transcribingSegmentIDs.removeAll { $0 == segmentID }
        stoppedAt.removeValue(forKey: segmentID)
        model.dispatch(.removeSegment(segmentID: segmentID), now: now)
        firePendingCommitIfReady()
        onEvent?(.status)
    }

    // MARK: Typing

    /// The window reports what the user typed, as paragraphs mapped to segments (see
    /// EditDocumentReconciler). Hand edits always win over any cleanup in flight.
    public func applyUserEdits(_ ops: [EditDocumentReconciler.Op], now: Date = Date()) {
        var restructured = false
        for op in ops {
            switch op {
            case .edit(let id, let text):
                cancelCleanup(id)
                model.dispatch(.userEdit(segmentID: id, newText: text), now: now)
            case .merge(let owner, let absorbed, let text):
                absorbed.forEach { cancelCleanup($0) }
                cancelCleanup(owner)
                model.dispatch(.mergeSegments(ownerID: owner, absorbedIDs: absorbed, text: text), now: now)
                restructured = true
            case .remove(let id):
                cancelCleanup(id)
                model.dispatch(.removeSegment(segmentID: id), now: now)
                restructured = true
            case .addTyped(let id, let text):
                model.dispatch(.addTypedSegment(segmentID: id, text: text), now: now)
                restructured = true
            }
        }
        if let c = comparison, !c.invalidated,
           segment(c.segmentID)?.revisions.last?.id != c.sourceRevision {
            comparison?.invalidated = true
            onEvent?(.comparison)
        }
        escArmedUntil = nil
        if restructured { onEvent?(.restructured) }
        onEvent?(.status)
    }

    // MARK: Return

    public func returnPressed() -> EditReturnOutcome {
        escArmedUntil = nil
        if recordingSegmentID != nil || !transcribingSegmentIDs.isEmpty {
            pendingCommit = true
            onEvent?(.status)
            return .waitingForTake
        }
        let snapshot = makeCommitSnapshot()
        guard !snapshot.text.isEmpty else {
            commitSnapshot = nil
            return .nothingToInsert
        }
        // Cleanup may finish while the target app activates or validates. Stop it at
        // the user's Return, before any asynchronous insertion begins.
        cancelAllCleanup()
        commitSnapshot = snapshot
        return .commit(snapshot.text)
    }

    private func firePendingCommitIfReady() {
        guard pendingCommit, recordingSegmentID == nil, transcribingSegmentIDs.isEmpty else { return }
        pendingCommit = false
        onEvent?(.readyToCommit)
    }

    private func makeCommitSnapshot() -> CommitSnapshot {
        let paragraphs = displayedSegments
            .filter { !$0.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { seg in
                EditSessionArtifact.Paragraph(text: seg.currentText, original: seg.originalText,
                                              componentStems: seg.componentStems ?? [],
                                              revisions: seg.revisions)
            }
        return CommitSnapshot(text: paragraphs.map(\.text).joined(separator: "\n\n"),
                              paragraphs: paragraphs)
    }

    /// The text landed in the original place: close the session. The artifact uses
    /// Return's snapshot, even if an asynchronous completion arrived during insertion.
    @discardableResult
    public func commitSucceeded(targetApp: String?, now: Date = Date()) -> EditSessionArtifact {
        let snapshot = commitSnapshot ?? makeCommitSnapshot()
        commitSnapshot = nil
        cancelAllCleanup()
        model.dispatch(.commit, now: now)
        latencyLog?.record(.init(event: "commit", model: nil, ms: nil, chars: snapshot.text.count,
                                 applied: nil, rejected: nil, outcome: "inserted"))
        onEvent?(.status)
        return EditSessionArtifact(sessionID: model.state.id, committedAt: now, text: snapshot.text,
                                   paragraphs: snapshot.paragraphs, targetApp: targetApp)
    }

    /// The original place could not be established (or the insert was uncertain): copy the text
    /// and KEEP the draft open. The session stays open; Return tries again.
    public func commitRetained(_ reason: EditRetainReason) {
        commitSnapshot = nil
        let text = commitText
        let copied = !text.isEmpty && clipboard?.copy(text) == true
        if reason == .insertionUncertain {
            // It may have landed: never invite a retry that could insert it twice.
            notice = copied
                ? "\(reason.explanation) Check the app before pasting. Your text is copied and still here; Esc twice closes this window."
                : "\(reason.explanation) Check the app before pasting. Your text could not be copied and is still here; Esc twice closes this window."
        } else {
            notice = copied
                ? "\(reason.explanation) Your text is copied and still here. Press ⌘V to paste it, or Return to try again."
                : "\(reason.explanation) Your text could not be copied and is still here. Return tries again."
        }
        latencyLog?.record(.init(event: "commit", model: nil, ms: nil, chars: text.count,
                                 applied: nil, rejected: nil, outcome: "retained:\(reason.rawValue)"))
        onEvent?(.status)
    }

    // MARK: Esc

    public func escapePressed(now: Date = Date()) -> EditEscapeOutcome {
        pendingCommit = false
        if let rec = recordingSegmentID {
            recordingSegmentID = nil
            model.dispatch(.removeSegment(segmentID: rec), now: now)
            escArmedUntil = nil
            onEvent?(.status)
            return .discardedTake
        }
        if hasDraft {
            if let until = escArmedUntil, now <= until {
                close(now: now)
                return .closed
            }
            escArmedUntil = now.addingTimeInterval(Self.escArmWindow)
            onEvent?(.status)
            return .armed
        }
        close(now: now)
        return .closed
    }

    /// True while the "Press Esc again to discard" prompt is showing.
    public func isEscArmed(now: Date = Date()) -> Bool {
        guard let until = escArmedUntil else { return false }
        return now <= until
    }

    private func close(now: Date) {
        commitSnapshot = nil
        cancelAllCleanup()
        model.dispatch(.cancel, now: now)
        onEvent?(.status)
    }

    /// App quit or crash-safe shutdown while open.
    public func terminate(now: Date = Date()) {
        commitSnapshot = nil
        cancelAllCleanup()
        model.dispatch(.terminate, now: now)
    }

    // MARK: Cleanup

    private func enqueueCleanup(_ segmentID: UUID) {
        guard settings.sendsToCloud, cleanupUnavailable == nil else { return }
        if !queue.contains(segmentID) && inFlight[segmentID] == nil { queue.append(segmentID) }
        pump()
    }

    private func pump(now: Date = Date()) {
        guard settings.sendsToCloud, cleanupUnavailable == nil, isOpen else { return }
        while inFlight.count < Self.maxConcurrentCleanups, !queue.isEmpty {
            let id = queue.removeFirst()
            start(id, retry: explicitRetries.remove(id) != nil, now: now)
        }
    }

    private func start(_ segmentID: UUID, retry: Bool, now: Date) {
        let attemptID = UUID()
        let arm = settings.model.rawValue
        let action: EditSessionAction = retry
            ? .retryCleaning(segmentID: segmentID, attemptID: attemptID, arm: arm)
            : .startCleaning(segmentID: segmentID, attemptID: attemptID, arm: arm)
        guard model.dispatch(action, now: now) == .applied,
              let seg = segment(segmentID), let source = seg.inFlight?.sourceRevision else { return }
        failures.removeValue(forKey: segmentID)
        let cancellation = CleanupCancellation()
        let chosen = settings.model
        inFlight[segmentID] = InFlight(attemptID: attemptID, cancellation: cancellation,
                                       startedAt: now, model: chosen)
        let raw = seg.raw
        let text = seg.currentText
        let sessionID = model.state.id
        let cleaner = self.cleaner
        onEvent?(.status)
        Task { @MainActor [weak self] in
            let result = await cleaner.cleanup(raw: raw, pipelineText: text, model: chosen,
                                               cancellation: cancellation)
            self?.finish(segmentID: segmentID, sessionID: sessionID, attemptID: attemptID,
                         source: source, model: chosen, result: result)
        }
    }

    private func finish(segmentID: UUID, sessionID: UUID, attemptID: UUID, source: UUID,
                        model chosen: CleanupService.Model,
                        result: Result<[SpanEdit], CleanupService.CleanupError>) {
        let now = Date()
        guard let entry = inFlight[segmentID], entry.attemptID == attemptID else { return }
        inFlight.removeValue(forKey: segmentID)
        let ms = Int(now.timeIntervalSince(entry.startedAt) * 1000)
        if entry.cancellation.isCancelled {
            latencyLog?.record(.init(event: "cleanup", model: chosen.rawValue, ms: ms, chars: nil,
                                     applied: nil, rejected: nil, outcome: "cancelled"))
            pump()
            return
        }
        switch result {
        case .success(let edits):
            let screened = CleanupFaithfulness.screen(edits)
            rejectedForMeaning += screened.rejected.count
            let outcome = model.dispatch(.cleanupResult(CleanupCompletion(
                sessionID: sessionID, segmentID: segmentID, sourceRevision: source,
                attemptID: attemptID, arm: chosen.rawValue, edits: screened.kept)), now: now)
            let applied = segment(segmentID)?.currentModelRevision?.appliedEdits.count ?? 0
            latencyLog?.record(.init(event: "cleanup", model: chosen.rawValue, ms: ms,
                                     chars: segment(segmentID)?.currentText.count,
                                     applied: outcome == .applied ? applied : 0,
                                     rejected: edits.count - (outcome == .applied ? applied : 0),
                                     outcome: outcome == .applied ? "ok" : "dropped"))
            if outcome == .applied { onEvent?(.replaced(segmentID, animate: true)) }
        case .failure(let error):
            if model.dispatch(.cleanupFailed(segmentID: segmentID, attemptID: attemptID), now: now)
                == .applied {
                failures[segmentID] = error
            }
            if error.isSessionWide {
                cleanupUnavailable = error
                // Nothing further is sent this session; queued paragraphs stay on-device text.
                queue.removeAll()
            }
            latencyLog?.record(.init(event: "cleanup", model: chosen.rawValue, ms: ms, chars: nil,
                                     applied: nil, rejected: nil,
                                     outcome: "failed:\(Self.failureCode(error))"))
            // No .replaced: the text did not change. The .status below redraws the paragraph state.
        }
        pump()
        onEvent?(.status)
    }

    static func failureCode(_ e: CleanupService.CleanupError) -> String {
        switch e {
        case .executableNotFound: return "notFound"
        case .preflightFailed: return "preflight"
        case .launchFailed: return "launch"
        case .timedOut: return "timeout"
        case .outputTooLarge: return "tooLarge"
        case .badOutput: return "badOutput"
        case .notLoggedIn: return "notLoggedIn"
        case .usageLimit: return "usageLimit"
        case .cliError: return "cliError"
        case .cancelled: return "cancelled"
        }
    }

    /// Stop any queued or running cleanup of one paragraph and put it back to the text it showed
    /// before the call (no failure mark: nothing failed).
    private func cancelCleanup(_ segmentID: UUID, now: Date = Date()) {
        queue.removeAll { $0 == segmentID }
        explicitRetries.remove(segmentID)
        if let entry = inFlight.removeValue(forKey: segmentID) {
            entry.cancellation.cancel()
        }
        if segment(segmentID)?.state == .cleaning {
            model.dispatch(.cancelCleaning(segmentID: segmentID), now: now)
        }
    }

    private func cancelAllCleanup(now: Date = Date()) {
        queue.removeAll()
        explicitRetries.removeAll()
        for (_, entry) in inFlight { entry.cancellation.cancel() }
        inFlight.removeAll()
        compareCancellations.forEach { $0.cancel() }
        compareCancellations.removeAll()
        if isOpen {
            for seg in model.state.segments where seg.state == .cleaning {
                model.dispatch(.cancelCleaning(segmentID: seg.id), now: now)
            }
        }
    }

    /// "Clean up again" on one paragraph (after a failure, or on a paragraph he edited).
    public func retryCleanup(_ segmentID: UUID, now: Date = Date()) {
        guard settings.sendsToCloud, isOpen else { return }
        // A session-wide failure gets one fresh try when he asks explicitly (he may have logged
        // in or installed the CLI since).
        cleanupUnavailable = nil
        cancelCleanup(segmentID, now: now)
        if inFlight.count < Self.maxConcurrentCleanups {
            start(segmentID, retry: true, now: now)
        } else {
            // Over the limit: the explicit retry waits its turn like any paragraph, and still
            // counts as explicit when it starts (so it may clean a hand-edited paragraph).
            queue.append(segmentID)
            explicitRetries.insert(segmentID)
        }
        onEvent?(.status)
    }

    // MARK: Options

    /// Cleanup on/off takes effect immediately: turning it off cancels every
    /// queued call, terminates every running call, never retries, and cancels a comparison.
    /// Turning it on (with consent) cleans every paragraph still showing on-device text.
    public func setCleanupEnabled(_ enabled: Bool, now: Date = Date()) {
        settings.cleanupEnabled = enabled
        applySendingChange(now: now)
    }

    public func setConsentGiven(_ given: Bool, now: Date = Date()) {
        settings.consentGiven = given
        applySendingChange(now: now)
    }

    private func applySendingChange(now: Date) {
        if !settings.sendsToCloud {
            // Every queued and running call stops now; paragraphs go back to the on-device text
            // with no failure mark (nothing failed, he turned it off).
            cancelAllCleanup(now: now)
            if comparison != nil { comparison = nil; onEvent?(.comparison) }
        } else {
            cleanupUnavailable = nil
            for seg in model.state.segments where seg.state == .provisional {
                if !queue.contains(seg.id) { queue.append(seg.id) }
            }
            pump(now: now)
        }
        onEvent?(.status)
    }

    public func setModel(_ m: CleanupService.Model) {
        settings.model = m
        onEvent?(.status)
    }

    public func setAnimation(_ style: EditAnimationStyle) {
        settings.animation = style
        onEvent?(.status)
    }

    // MARK: Versions

    public func versions(for segmentID: UUID) -> EditParagraphVersions? {
        guard let seg = segment(segmentID) else { return nil }
        return EditParagraphVersions(
            segmentID: segmentID, original: seg.originalText, previous: seg.previousRevision?.text,
            current: seg.currentText, changes: seg.undoableChanges,
            takes: 1 + (seg.absorbed?.count ?? 0))
    }

    @discardableResult
    public func restore(_ kind: EditVersionKind, segmentID: UUID, now: Date = Date()) -> Bool {
        guard let seg = segment(segmentID) else { return false }
        cancelCleanup(segmentID)
        let outcome: EditSessionReducer.Outcome
        switch kind {
        case .current:
            return false
        case .original:
            // A merged paragraph's original is the joined originals (not a stored revision).
            if seg.absorbed?.isEmpty == false, let joined = seg.originalText {
                outcome = model.dispatch(.userEdit(segmentID: segmentID, newText: joined), now: now)
            } else {
                outcome = model.dispatch(.restoreOriginal(segmentID: segmentID), now: now)
            }
        case .previous:
            guard let prev = seg.previousRevision else { return false }
            outcome = model.dispatch(.restoreRevision(segmentID: segmentID, revisionID: prev.id), now: now)
        }
        guard outcome == .applied else { return false }
        failures.removeValue(forKey: segmentID)
        onEvent?(.replaced(segmentID, animate: false))
        onEvent?(.status)
        return true
    }

    /// Undo one cleanup change, keeping every hand edit made since.
    @discardableResult
    public func revertChange(_ edit: SpanEdit, segmentID: UUID, now: Date = Date()) -> Bool {
        cancelCleanup(segmentID)
        guard model.dispatch(.revertChange(segmentID: segmentID, edit: edit), now: now) == .applied
        else { return false }
        onEvent?(.replaced(segmentID, animate: false))
        onEvent?(.status)
        return true
    }

    /// Copy one version of a paragraph.
    @discardableResult
    public func copyVersion(_ kind: EditVersionKind, segmentID: UUID) -> Bool {
        guard let v = versions(for: segmentID) else { return false }
        let text: String?
        switch kind {
        case .original: text = v.original
        case .previous: text = v.previous
        case .current: text = v.current
        }
        guard let t = text, let clipboard = clipboard else { return false }
        guard clipboard.copy(t) else {
            notice = "Could not copy the \(kind.rawValue) version. Your text is still here."
            onEvent?(.status)
            return false
        }
        notice = "Copied the \(kind.rawValue) version."
        onEvent?(.status)
        return true
    }

    // MARK: Compare (on demand, same paragraph, two models)

    /// Run the same paragraph through two models, side by side, labelled A and B in a random
    /// order. Nothing is applied until he picks one. Returns false when it cannot start.
    @discardableResult
    public func startCompare(segmentID: UUID, models: [CleanupService.Model],
                             now: Date = Date()) -> Bool {
        guard settings.sendsToCloud, isOpen, models.count == 2, models[0] != models[1],
              let seg = segment(segmentID), seg.state != .cleaning, seg.state != .recording,
              let source = seg.revisions.last?.id, !seg.currentText.isEmpty else { return false }
        compareCancellations.forEach { $0.cancel() }
        compareCancellations.removeAll()
        let order = shuffle(models)
        let labels = ["A", "B"]
        comparison = EditComparison(
            segmentID: segmentID, sourceRevision: source, sourceText: seg.currentText,
            candidates: order.enumerated().map { i, m in
                EditCandidate(label: labels[i], model: m, status: .running, latencyMs: nil)
            },
            chosenLabel: nil, invalidated: false)
        onEvent?(.comparison)
        let raw = seg.raw
        let text = seg.currentText
        for (i, m) in order.enumerated() {
            let cancellation = CleanupCancellation()
            compareCancellations.append(cancellation)
            let cleaner = self.cleaner
            let started = now
            Task { @MainActor [weak self] in
                let result = await cleaner.cleanup(raw: raw, pipelineText: text, model: m,
                                                   cancellation: cancellation)
                self?.finishCompare(index: i, source: source, started: started,
                                    cancellation: cancellation, result: result)
            }
        }
        return true
    }

    private func finishCompare(index: Int, source: UUID, started: Date,
                               cancellation: CleanupCancellation,
                               result: Result<[SpanEdit], CleanupService.CleanupError>) {
        guard !cancellation.isCancelled, var c = comparison, c.sourceRevision == source,
              index < c.candidates.count else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success(let edits):
            let kept = CleanupFaithfulness.screen(edits).kept
            let application = SpanEditApplier.apply(kept, to: c.sourceText)
            c.candidates[index].status = .ready(text: application.text, edits: application.applied)
        case .failure(let e):
            c.candidates[index].status = .failed(e.userMessage)
        }
        c.candidates[index].latencyMs = ms
        comparison = c
        latencyLog?.record(.init(event: "compare", model: c.candidates[index].model.rawValue, ms: ms,
                                 chars: c.sourceText.count, applied: nil, rejected: nil,
                                 outcome: { if case .ready = c.candidates[index].status { return "ok" }; return "failed" }()))
        onEvent?(.comparison)
    }

    /// Use candidate A or B. Fails (and marks the comparison stale) if the paragraph changed.
    @discardableResult
    public func chooseCandidate(_ label: String, now: Date = Date()) -> Bool {
        guard var c = comparison, !c.invalidated,
              let cand = c.candidates.first(where: { $0.label == label }),
              case .ready(_, let edits) = cand.status else { return false }
        let outcome = model.dispatch(.applyCandidate(segmentID: c.segmentID, sourceRevision: c.sourceRevision,
                                                     arm: cand.model.rawValue, edits: edits), now: now)
        guard outcome == .applied else {
            c.invalidated = true
            comparison = c
            onEvent?(.comparison)
            return false
        }
        c.chosenLabel = label
        comparison = c
        let reveal = c.candidates.map { "\($0.label) was \($0.model.displayName)" }.joined(separator: ", ")
        notice = "Used \(label). \(reveal)."
        latencyLog?.record(.init(event: "compare-choice", model: cand.model.rawValue, ms: nil,
                                 chars: nil, applied: edits.count, rejected: nil, outcome: "chosen"))
        onEvent?(.replaced(c.segmentID, animate: true))
        onEvent?(.comparison)
        onEvent?(.status)
        return true
    }

    public func dismissCompare() {
        compareCancellations.forEach { $0.cancel() }
        compareCancellations.removeAll()
        comparison = nil
        onEvent?(.comparison)
    }

    public func clearNotice() {
        notice = nil
        onEvent?(.status)
    }
}
