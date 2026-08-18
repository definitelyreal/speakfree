// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation

/// What the private claim receipt proves about the field the user is currently editing.
public enum DictationRelayOwnership: Equatable, Sendable {
    /// No receipt for this session: the relay may take ownership of a new insertion region here.
    case unclaimed
    /// This field already holds text from this session, at the recorded revision.
    case claimedHere(DictationRevisionState)
    /// This session was claimed in a *different* host field. Its text there is left untouched.
    case claimedInAnotherDocument
    /// A receipt exists but we cannot prove whether its edit landed. Never guess.
    case unverifiable
}

public struct DictationRelayTapRequest {
    public let fieldAcceptsDictation: Bool
    public let relayStorageAvailable: Bool
    public let freshSnapshot: DictationSnapshot?
    public let hasSelection: Bool
    /// Resolved only once the cheaper guards pass, because reading and reconciling the receipt can
    /// perform a recovery edit.
    public let resolveOwnership: (DictationSnapshot) -> DictationRelayOwnership

    public init(
        fieldAcceptsDictation: Bool,
        relayStorageAvailable: Bool,
        freshSnapshot: DictationSnapshot?,
        hasSelection: Bool,
        resolveOwnership: @escaping (DictationSnapshot) -> DictationRelayOwnership
    ) {
        self.fieldAcceptsDictation = fieldAcceptsDictation
        self.relayStorageAvailable = relayStorageAvailable
        self.freshSnapshot = freshSnapshot
        self.hasSelection = hasSelection
        self.resolveOwnership = resolveOwnership
    }
}

/// The complete decision table for a relay-key tap. Every case either edits the document or names
/// a reason out loud — a tap must never be a silent no-op.
public enum DictationRelayTapAction: Equatable, Sendable {
    /// Take ownership of a new insertion region at the cursor and insert the visible transcript.
    case insertFresh
    /// Extend the region this field already owns to the newest revision.
    case revise(DictationRevisionState)
    case explainUnsupportedField
    case explainRelayUnavailable
    case explainNoSession
    case explainSelection
    case explainNothingToInsertYet
    case explainAlreadyCurrent
    case explainUnverifiableClaim

    public var insertsText: Bool {
        switch self {
        case .insertFresh, .revise: return true
        default: return false
        }
    }

    /// The status shown in the candidate bar. `nil` only for actions that edit the document, which
    /// report their own progress instead.
    public var explanation: String? {
        switch self {
        case .insertFresh, .revise:
            return nil
        case .explainUnsupportedField:
            return "SpeakFree inserts into standard text fields"
        case .explainRelayUnavailable:
            return "SpeakFree relay unavailable in this build"
        case .explainNoSession:
            return "Start dictation in the SpeakFree app or Shortcut, then tap SF"
        case .explainSelection:
            return "Clear the selection, then tap SF to insert"
        case .explainNothingToInsertYet:
            return "SpeakFree is listening — nothing to insert yet"
        case .explainAlreadyCurrent:
            return "SpeakFree text is already inserted here"
        case .explainUnverifiableClaim:
            return "SpeakFree can't verify the last insert — move the cursor first"
        }
    }
}

public enum DictationRelayTapPlanner {
    public static func plan(_ request: DictationRelayTapRequest) -> DictationRelayTapAction {
        guard request.fieldAcceptsDictation else { return .explainUnsupportedField }
        guard request.relayStorageAvailable else { return .explainRelayUnavailable }
        guard let snapshot = request.freshSnapshot else { return .explainNoSession }
        guard !request.hasSelection else { return .explainSelection }

        switch request.resolveOwnership(snapshot) {
        case .claimedHere(let state):
            guard snapshot.revision > state.appliedRevision else {
                return state.insertedText.isEmpty
                    ? .explainNothingToInsertYet
                    : .explainAlreadyCurrent
            }
            return .revise(state)
        case .unclaimed, .claimedInAnotherDocument:
            // Tapping the relay in a new field is an explicit request for the transcript *here*.
            // The previously claimed field keeps whatever it already holds; it is never edited
            // from this field, and this field is never written without this tap.
            return .insertFresh
        case .unverifiable:
            return .explainUnverifiableClaim
        }
    }
}
