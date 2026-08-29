import Foundation

/// Where a finalized dictation's text goes (C1). Today's only destination is `insertImmediately` —
/// the pipeline text is composed and handed to the TextInserter. Edit Mode adds
/// `returnToEditSession`: the finalized segment is delivered to the open edit session and is
/// STRUCTURALLY unable to reach the inserter (see AppDelegate.finalizeRecording, where the two
/// destinations are mutually-exclusive branches — the edit branch never calls presentFinalizedText).
///
/// The captured target for an edit session is immutable for the session's life: segments 2+ do NOT
/// re-run focus capture. That is why the destination is decided from a target token captured when
/// the segment's recording began, not re-derived at finalize.
public enum FinalizeDestination: Equatable {
    case insertImmediately
    case returnToEditSession(sessionID: UUID, segmentID: UUID)

    /// Pure resolution so the routing rule is unit-testable without an AppKit AppDelegate. A segment
    /// belongs to an edit session iff a target was captured for it at record-start (nil for every
    /// hold/toggle dictation — those insert immediately, byte-identically to before Edit Mode).
    public static func resolve(editTarget: (sessionID: UUID, segmentID: UUID)?) -> FinalizeDestination {
        if let t = editTarget {
            return .returnToEditSession(sessionID: t.sessionID, segmentID: t.segmentID)
        }
        return .insertImmediately
    }
}

/// The payload the finalize path delivers to an open edit session instead of inserting. Carries the
/// raw pre-pipeline transcript (the model's input), the pipeline text (the provisional floor and
/// the model's reference), the audio URL, and the recording meta — everything the session needs to
/// settle the segment, with no path back to the inserter.
public struct EditFinalizePayload {
    public let sessionID: UUID
    public let segmentID: UUID
    public let raw: String
    public let pipelineText: String
    public let audioURL: URL
    public let meta: RecordingStore.RecordingMeta

    public init(sessionID: UUID, segmentID: UUID, raw: String, pipelineText: String,
                audioURL: URL, meta: RecordingStore.RecordingMeta) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.raw = raw
        self.pipelineText = pipelineText
        self.audioURL = audioURL
        self.meta = meta
    }
}
