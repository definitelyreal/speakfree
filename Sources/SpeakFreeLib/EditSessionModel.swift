import Foundation

// Edit Mode session state (the maintainer, 2026-08-28). This file is the model half of Edit Mode: an
// immutable-revision segment history (C3/M24), a single token-guarded reducer that drops stale
// async work (C4), and consent-bound draft persistence (C5). It is deliberately AppKit-free and
// pure so the whole race surface is unit-testable without a window — the finalize/insertion side
// (AppDelegate) and the window (Phase 2) never re-implement this logic.

// MARK: - Revisions (M24)

/// One immutable revision of a segment's text. History is a list of these, not mutable
/// raw/cleaned?/userEdited? fields — so "restore original" is a lookup, a stale cleanup result is a
/// no-op append that never clobbers a user edit, and every change carries its provenance.
public struct SegmentRevision: Codable, Equatable, Identifiable {
    public enum Origin: String, Codable, Equatable {
        case asr      // the pipeline output shown the instant recording ends (the provisional floor)
        case model    // an LLM cleanup result (carries the arm)
        case user     // a hand-edit in the window
        case restore  // "restore original" — recovers the asr text
    }
    public let id: UUID
    public let text: String
    public let origin: Origin
    /// The cleanup arm ("sonnet"/"opus") when origin == .model; nil otherwise.
    public let arm: String?
    public let timestamp: Date
    /// The revision this one descends from (nil for the first). A parent chain, not a tree.
    public let parent: UUID?
    /// The span edits applied to the parent's text to produce this revision (origin == .model).
    public let appliedEdits: [SpanEdit]

    public init(id: UUID = UUID(), text: String, origin: Origin, arm: String? = nil,
                timestamp: Date, parent: UUID?, appliedEdits: [SpanEdit] = []) {
        self.id = id
        self.text = text
        self.origin = origin
        self.arm = arm
        self.timestamp = timestamp
        self.parent = parent
        self.appliedEdits = appliedEdits
    }
}

// MARK: - Segment

public struct EditSegment: Codable, Equatable, Identifiable {
    /// Per-segment lifecycle. None of these are terminal at the segment level; the SESSION carries
    /// the absorbing terminal states.
    public enum State: String, Codable, Equatable {
        case recording     // audio is being captured
        case provisional   // pipeline text is in, no cleanup yet
        case cleaning      // a cleanup attempt is in flight
        case settled       // a cleanup result (or a no-op) has landed
        case edited        // the user hand-edited this segment (cleanup can no longer touch it)
        case failed        // the cleanup attempt failed; retry is available
    }

    /// The cleanup attempt currently in flight for this segment, if any. The reducer matches an
    /// incoming async result against ALL of these tokens and drops it unless every one matches (C4).
    public struct InFlightAttempt: Codable, Equatable {
        public let attemptID: UUID
        public let sourceRevision: UUID
        public let arm: String
    }

    public let id: UUID
    public var state: State
    /// The raw pre-pipeline transcript (the maintainer: "feed the raw phonemes"). Immutable once set.
    public var raw: String
    public private(set) var revisions: [SegmentRevision]
    public var inFlight: InFlightAttempt?
    /// Segments merged INTO this one by a Backspace at a paragraph boundary, in order, with their
    /// full revision history kept (merged-paragraph history stays inspectable).
    /// Optional so drafts written before the field existed still decode.
    public var absorbed: [EditSegment]?
    /// The archived recording stem(s) behind this paragraph (nil when recordings are off or the
    /// paragraph was typed). Used to list the paragraph as a component in Recent Dictations.
    public var componentStems: [String]?

    /// Bounded history (M24): keep the original asr revision (index 0, needed for Restore) plus the
    /// most recent revisions. A runaway A/B or retry loop can never grow this without bound.
    static let maxRevisions = 64

    public init(id: UUID = UUID(), state: State = .recording, raw: String = "",
                revisions: [SegmentRevision] = [], inFlight: InFlightAttempt? = nil) {
        self.id = id
        self.state = state
        self.raw = raw
        self.revisions = revisions
        self.inFlight = inFlight
    }

    /// The current text = the newest revision's text (empty while still recording).
    public var currentText: String { revisions.last?.text ?? "" }

    /// The original provisional (asr) text, for Restore. For a merged paragraph this is the
    /// originals of every merged take joined by one space (the merge removed the paragraph break).
    public var originalText: String? {
        let own = revisions.first(where: { $0.origin == .asr })?.text
        let merged = (absorbed ?? []).compactMap { $0.originalText }
        if merged.isEmpty { return own }
        return ([own].compactMap { $0 } + merged).joined(separator: " ")
    }

    /// The version shown just before the current one: the newest earlier revision whose text
    /// differs from the current text: the "previous" version the window offers beside the
    /// original. nil when nothing earlier differs.
    public var previousRevision: SegmentRevision? {
        let current = currentText
        return revisions.dropLast().last(where: { $0.text != current })
    }

    /// The newest model revision if it is still the current revision (its applied edits are the
    /// change marks shown in the window), else nil.
    public var currentModelRevision: SegmentRevision? {
        guard let last = revisions.last, last.origin == .model else { return nil }
        return last
    }

    /// Every cleanup change still visible in the current text: the applied edits of every model
    /// revision, newest first, whose replacement still occurs EXACTLY ONCE in the current text
    /// (undo anchors on it; a bare "," among several commas cannot be undone, so it is not
    /// offered, review 2026-09-29). Original and Previous restore still cover those.
    public var undoableChanges: [SpanEdit] {
        var out: [SpanEdit] = []
        let current = currentText
        for rev in revisions.reversed() where rev.origin == .model {
            for edit in rev.appliedEdits where !edit.replace.isEmpty
                && SpanEditApplier.allRanges(of: edit.replace, in: current).count == 1
                && !out.contains(edit) {
                out.append(edit)
            }
        }
        return out
    }

    /// Append a revision, maintaining the parent chain and the bound. Keeps index 0 (the asr
    /// original) and drops the oldest non-original when over the cap.
    mutating func appendRevision(text: String, origin: SegmentRevision.Origin, arm: String? = nil,
                                 timestamp: Date, appliedEdits: [SpanEdit] = []) {
        let rev = SegmentRevision(text: text, origin: origin, arm: arm, timestamp: timestamp,
                                  parent: revisions.last?.id, appliedEdits: appliedEdits)
        revisions.append(rev)
        if revisions.count > Self.maxRevisions {
            revisions.remove(at: 1)  // preserve the asr original at index 0
        }
    }
}

// MARK: - Session

public struct EditSessionState: Codable, Equatable, Identifiable {
    public enum Lifecycle: String, Codable, Equatable {
        case open
        case committed
        case cancelled
        case terminated

        var isTerminal: Bool { self != .open }
    }

    public let id: UUID
    public var segments: [EditSegment]
    public var lifecycle: Lifecycle
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), segments: [EditSegment] = [], lifecycle: Lifecycle = .open,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.segments = segments
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func indexOfSegment(_ segmentID: UUID) -> Int? {
        segments.firstIndex(where: { $0.id == segmentID })
    }
}

// MARK: - Async result envelope (C4)

/// A cleanup result carries every token the reducer needs to prove it is still relevant. Any
/// mismatch — the session moved on, the user edited the segment, a newer attempt superseded this
/// one, the source revision changed, the arm differs — drops it silently. User edits always win.
public struct CleanupCompletion: Equatable {
    public let sessionID: UUID
    public let segmentID: UUID
    public let sourceRevision: UUID
    public let attemptID: UUID
    public let arm: String
    public let edits: [SpanEdit]

    public init(sessionID: UUID, segmentID: UUID, sourceRevision: UUID, attemptID: UUID,
                arm: String, edits: [SpanEdit]) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.sourceRevision = sourceRevision
        self.attemptID = attemptID
        self.arm = arm
        self.edits = edits
    }
}

// MARK: - Actions

public enum EditSessionAction {
    case beginSegment(segmentID: UUID)
    case provisional(segmentID: UUID, raw: String, pipelineText: String)
    case startCleaning(segmentID: UUID, attemptID: UUID, arm: String)
    /// An explicit "Clean up again" from the user. Unlike `startCleaning` it may start from
    /// `.edited`: the user asked for it.
    case retryCleaning(segmentID: UUID, attemptID: UUID, arm: String)
    case cleanupResult(CleanupCompletion)
    case cleanupFailed(segmentID: UUID, attemptID: UUID)
    /// The in-flight cleanup was stopped on purpose (cloud turned off, hand edit, restore, commit):
    /// back to the posture it had before the call, with no failure mark.
    case cancelCleaning(segmentID: UUID)
    case userEdit(segmentID: UUID, newText: String)
    case restoreOriginal(segmentID: UUID)
    /// Make an earlier revision current again (Original / Previous restore). Appends, never
    /// rewrites history, so restoring is itself reversible.
    case restoreRevision(segmentID: UUID, revisionID: UUID)
    /// Undo ONE cleanup change without discarding later hand edits: the inverse
    /// span edit (replace -> find) is applied to the CURRENT text, anchored uniquely, so edits made
    /// elsewhere in the paragraph survive.
    case revertChange(segmentID: UUID, edit: SpanEdit)
    /// Apply a chosen compare candidate. Guarded by the revision the candidates were computed from:
    /// any edit since then invalidates the comparison.
    case applyCandidate(segmentID: UUID, sourceRevision: UUID, arm: String, edits: [SpanEdit])
    /// A Backspace across a paragraph boundary merged `absorbedIDs` into `ownerID`; `text` is the
    /// merged paragraph as it now reads.
    case mergeSegments(ownerID: UUID, absorbedIDs: [UUID], text: String)
    /// A take that produced no text (too short, silent, failed transcription) or a paragraph the
    /// user deleted entirely.
    case removeSegment(segmentID: UUID)
    /// A paragraph typed by hand with no dictation behind it.
    case addTypedSegment(segmentID: UUID, text: String)
    /// Record the archived recording stem behind a paragraph (Recents components).
    case setComponentStem(segmentID: UUID, stem: String)
    case commit
    case cancel
    case terminate
}

// MARK: - Reducer (C4, pure)

public enum EditSessionReducer {

    public enum DropReason: String, Equatable {
        case sessionMismatch
        case segmentMissing
        case notCleaning       // the segment is no longer accepting this result (edited/restored/settled)
        case staleAttempt      // a newer attempt superseded this one
        case staleRevision     // the source revision changed under the attempt
        case armMismatch
        case invalidState      // the action does not fit the segment's current posture
    }

    public enum Outcome: Equatable {
        case applied
        case dropped(DropReason)
        case ignoredTerminal   // the session is committed/cancelled/terminated — absorbing
    }

    public struct Result {
        public let state: EditSessionState
        public let outcome: Outcome
    }

    public static func reduce(_ state: EditSessionState, _ action: EditSessionAction,
                              now: Date = Date()) -> Result {
        // Terminal states are ABSORBING: once committed/cancelled/terminated, nothing mutates. This
        // is what makes a cleanup result that arrives AFTER commit a guaranteed no-op.
        if state.lifecycle.isTerminal {
            return Result(state: state, outcome: .ignoredTerminal)
        }

        var next = state

        switch action {
        case .beginSegment(let segmentID):
            next.segments.append(EditSegment(id: segmentID, state: .recording))
            return applied(&next, now)

        case .provisional(let segmentID, let raw, let pipelineText):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            guard next.segments[i].state == .recording else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            next.segments[i].raw = raw
            next.segments[i].appendRevision(text: pipelineText, origin: .asr, timestamp: now)
            next.segments[i].state = .provisional
            return applied(&next, now)

        case .startCleaning(let segmentID, let attemptID, let arm),
             .retryCleaning(let segmentID, let attemptID, let arm):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            let s = next.segments[i]
            var allowed: [EditSegment.State] = [.provisional, .settled, .failed]
            if case .retryCleaning = action { allowed.append(.edited) }
            // Automatic cleanup can start from any settled-ish state (provisional/settled/failed)
            // but never on a segment the user has taken over (.edited) or one still recording.
            // An explicit retry may also start from .edited.
            guard allowed.contains(s.state), !s.currentText.isEmpty,
                  let source = s.revisions.last?.id else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            next.segments[i].inFlight = EditSegment.InFlightAttempt(
                attemptID: attemptID, sourceRevision: source, arm: arm)
            next.segments[i].state = .cleaning
            return applied(&next, now)

        case .cleanupResult(let c):
            guard c.sessionID == state.id else {
                return Result(state: state, outcome: .dropped(.sessionMismatch))
            }
            guard let i = next.indexOfSegment(c.segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            let s = next.segments[i]
            // notCleaning covers "the user edited/restored it since dispatch" — the segment left
            // .cleaning, so the result is stale and the user's work stands (C4: user edits win).
            guard s.state == .cleaning, let inFlight = s.inFlight else {
                return Result(state: state, outcome: .dropped(.notCleaning))
            }
            guard inFlight.attemptID == c.attemptID else {
                return Result(state: state, outcome: .dropped(.staleAttempt))
            }
            guard inFlight.sourceRevision == c.sourceRevision else {
                return Result(state: state, outcome: .dropped(.staleRevision))
            }
            guard inFlight.arm == c.arm else {
                return Result(state: state, outcome: .dropped(.armMismatch))
            }
            // Apply against the source revision's text (== current text, since the segment stayed in
            // .cleaning). Even a zero-applied result settles the segment (a no-op settle is fine).
            let baseText = s.revisions.last?.text ?? ""
            let application = SpanEditApplier.apply(c.edits, to: baseText)
            next.segments[i].appendRevision(text: application.text, origin: .model, arm: c.arm,
                                            timestamp: now, appliedEdits: application.applied)
            next.segments[i].state = .settled
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .cleanupFailed(let segmentID, let attemptID):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            let s = next.segments[i]
            guard s.state == .cleaning, let inFlight = s.inFlight else {
                return Result(state: state, outcome: .dropped(.notCleaning))
            }
            guard inFlight.attemptID == attemptID else {
                return Result(state: state, outcome: .dropped(.staleAttempt))
            }
            next.segments[i].state = .failed
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .cancelCleaning(let segmentID):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            guard next.segments[i].state == .cleaning else {
                return Result(state: state, outcome: .dropped(.notCleaning))
            }
            switch next.segments[i].revisions.last?.origin {
            case .asr?: next.segments[i].state = .provisional
            case .model?: next.segments[i].state = .settled
            default: next.segments[i].state = .edited
            }
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .userEdit(let segmentID, let newText):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            next.segments[i].appendRevision(text: newText, origin: .user, timestamp: now)
            next.segments[i].state = .edited
            // Drop any in-flight attempt: its result will now be dropped as .notCleaning. User wins.
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .restoreOriginal(let segmentID):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            guard let original = next.segments[i].originalText else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            next.segments[i].appendRevision(text: original, origin: .restore, timestamp: now)
            // A restore is the user taking control: no automatic cleanup may land on it afterward.
            next.segments[i].state = .edited
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .restoreRevision(let segmentID, let revisionID):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            guard let rev = next.segments[i].revisions.first(where: { $0.id == revisionID }) else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            next.segments[i].appendRevision(text: rev.text, origin: .restore, timestamp: now)
            next.segments[i].state = .edited
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .revertChange(let segmentID, let edit):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            // A pure deletion leaves nothing to anchor on, so it cannot be undone individually;
            // Original/Previous restore still covers it.
            guard !edit.replace.isEmpty else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            let inverse = SpanEdit(find: edit.replace, replace: edit.find,
                                   reason: "undid: \(edit.reason)")
            // Undo never widens: it must put back exactly what the fix took out.
            let application = SpanEditApplier.apply([inverse], to: next.segments[i].currentText,
                                                    absorbSpace: false)
            guard application.applied.count == 1 else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            next.segments[i].appendRevision(text: application.text, origin: .restore,
                                            timestamp: now, appliedEdits: application.applied)
            next.segments[i].state = .edited
            next.segments[i].inFlight = nil
            return applied(&next, now)

        case .applyCandidate(let segmentID, let sourceRevision, let arm, let edits):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            let s = next.segments[i]
            guard s.state != .recording, s.state != .cleaning else {
                return Result(state: state, outcome: .dropped(.invalidState))
            }
            guard s.revisions.last?.id == sourceRevision else {
                return Result(state: state, outcome: .dropped(.staleRevision))
            }
            let application = SpanEditApplier.apply(edits, to: s.currentText)
            next.segments[i].appendRevision(text: application.text, origin: .model, arm: arm,
                                            timestamp: now, appliedEdits: application.applied)
            if s.state != .edited { next.segments[i].state = .settled }
            return applied(&next, now)

        case .mergeSegments(let ownerID, let absorbedIDs, let text):
            guard next.indexOfSegment(ownerID) != nil else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            var gathered: [EditSegment] = []
            for id in absorbedIDs where id != ownerID {
                guard let j = next.indexOfSegment(id) else { continue }
                var gone = next.segments[j]
                gone.inFlight = nil   // its cleanup result is now dropped as segmentMissing
                gathered.append(gone)
                next.segments.remove(at: j)
            }
            guard let k = next.indexOfSegment(ownerID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            let absorbed = (next.segments[k].absorbed ?? []) + gathered
            let stems = (next.segments[k].componentStems ?? [])
                + gathered.flatMap { $0.componentStems ?? [] }
            next.segments[k].absorbed = absorbed.isEmpty ? nil : absorbed
            next.segments[k].componentStems = stems.isEmpty ? nil : stems
            next.segments[k].appendRevision(text: text, origin: .user, timestamp: now)
            next.segments[k].state = .edited
            next.segments[k].inFlight = nil
            return applied(&next, now)

        case .removeSegment(let segmentID):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            next.segments.remove(at: i)
            return applied(&next, now)

        case .addTypedSegment(let segmentID, let text):
            var seg = EditSegment(id: segmentID, state: .edited)
            seg.appendRevision(text: text, origin: .user, timestamp: now)
            next.segments.append(seg)
            return applied(&next, now)

        case .setComponentStem(let segmentID, let stem):
            guard let i = next.indexOfSegment(segmentID) else {
                return Result(state: state, outcome: .dropped(.segmentMissing))
            }
            var stems = next.segments[i].componentStems ?? []
            if !stems.contains(stem) { stems.append(stem) }
            next.segments[i].componentStems = stems
            return applied(&next, now)

        case .commit:
            next.lifecycle = .committed
            return applied(&next, now)

        case .cancel:
            next.lifecycle = .cancelled
            return applied(&next, now)

        case .terminate:
            next.lifecycle = .terminated
            return applied(&next, now)
        }
    }

    private static func applied(_ next: inout EditSessionState, _ now: Date) -> Result {
        next.updatedAt = now
        return Result(state: next, outcome: .applied)
    }
}

// MARK: - Main-actor model wrapper

/// The one live owner of session state. The reducer is pure; this class is the single main-actor
/// serialization point through which every action (fn-tap routing, finalize delivery, cleanup
/// completion, user edits) flows — so there is no way to mutate session state off-main or race two
/// mutations. Consent-gated persistence hangs off applied mutations.
@MainActor
public final class EditSessionModel {
    public private(set) var state: EditSessionState
    private let draftStore: EditSessionDraftStore

    public init(sessionID: UUID = UUID(), persistenceEnabled: Bool, now: Date = Date()) {
        state = EditSessionState(id: sessionID, createdAt: now, updatedAt: now)
        draftStore = EditSessionDraftStore(enabled: persistenceEnabled)
    }

    @discardableResult
    public func dispatch(_ action: EditSessionAction, now: Date = Date())
        -> EditSessionReducer.Outcome
    {
        let result = EditSessionReducer.reduce(state, action, now: now)
        state = result.state
        guard result.outcome == .applied else { return result.outcome }
        switch state.lifecycle {
        case .committed:
            // The committed artifact (Phase 2) supersedes the draft.
            EditSessionDraftStore.clear()
        case .cancelled, .terminated:
            // Flush so a cancelled/terminated session is recoverable when saving is on; a no-op when
            // saving is off (nothing was ever written — Esc = gone, C5).
            draftStore.flush(state)
        case .open:
            draftStore.schedule(state)
        }
        return result.outcome
    }
}

// MARK: - Consent-bound draft persistence (C5)

/// Persists the open session to `<configDir>/edit-session-draft.json` for crash recovery — but ONLY
/// when the user has opted into saving (or DevMode). When saving is off, nothing is ever written and
/// Esc leaves no trace. Writes are debounced and atomic, 0600 file inside the 0700 config dir, and
/// expire after 24h so a stale draft is never resurrected.
public final class EditSessionDraftStore {
    private let enabled: Bool
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.speakfree.editdraft")
    private var pending: DispatchWorkItem?

    public init(enabled: Bool, debounce: TimeInterval = 0.5) {
        self.enabled = enabled
        self.debounce = debounce
    }

    /// Computed fresh (never stored) so a `Config.configDirOverride` switch in tests is honored —
    /// same discipline as RecordingStore.recordingsDir.
    ///
    /// Permanent regression guard (2026-09-25 fix/test-real-config): `write()`/`clear()` route
    /// through here, and `write()` can fire from a debounced background queue seconds after a
    /// test method returns — a real straggler was found racing past `tearDown()`'s
    /// `Config.configDirOverride = nil` and landing on the real edit-session-draft.json. Fail
    /// loudly instead of touching real data.
    public static var draftURL: URL {
        if Config.isResolvingRealDirUnderTest {
            fatalError(
                "EditSessionDraftStore.draftURL resolved to the REAL " +
                "~/.config/speakfree/edit-session-draft.json under XCTest. A debounced write can " +
                "fire after your test method returns — drain pending work (or wait past the " +
                "debounce interval) in tearDown() BEFORE resetting Config.configDirOverride to nil."
            )
        }
        return Config.configDir.appendingPathComponent("edit-session-draft.json")
    }

    public func schedule(_ state: EditSessionState) {
        guard enabled else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { Self.write(state) }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }

    public func flush(_ state: EditSessionState) {
        guard enabled else { return }
        queue.sync {
            self.pending?.cancel()
            self.pending = nil
        }
        Self.write(state)
    }

    private static func write(_ state: EditSessionState) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Config.configDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: draftURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Config.configDir.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL.path)
    }

    /// Load a recoverable draft, or nil if absent, unreadable, or expired (older than `maxAge`).
    public static func load(now: Date = Date(), maxAge: TimeInterval = 24 * 3600) -> EditSessionState? {
        guard let data = try? Data(contentsOf: draftURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(EditSessionState.self, from: data) else { return nil }
        guard now.timeIntervalSince(state.updatedAt) <= maxAge else { return nil }
        return state
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: draftURL)
    }
}
