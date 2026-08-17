// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

public enum DictationTranscriptLedgerError: Error, Equatable, Sendable {
    case finalizedTextRegressed
    case finalTextContradictsFinalizedPrefix
    case sessionAlreadyFinished
}

/// Turns aggregate recognizer hypotheses into the append-only finalized segments required for
/// safe cross-process insertion. Recognizer-confirmed text may only grow; volatile text may change
/// freely until it is promoted or the session ends.
public struct DictationTranscriptLedger: Equatable, Sendable {
    public let sessionID: UUID
    public let createdAt: Date
    public private(set) var revision: UInt64 = 0
    public private(set) var finalizedSegments: [DictationSegment] = []
    public private(set) var volatileText = ""
    public private(set) var phase: DictationSessionPhase = .active

    public init(sessionID: UUID = UUID(), createdAt: Date = Date()) {
        self.sessionID = sessionID
        self.createdAt = createdAt
    }

    public var finalizedText: String { finalizedSegments.map(\.text).joined() }

    @discardableResult
    public mutating func update(
        confirmedText: String,
        volatileText: String,
        at date: Date = Date()
    ) throws -> DictationSnapshot {
        guard phase == .active else {
            throw DictationTranscriptLedgerError.sessionAlreadyFinished
        }
        guard confirmedText.hasPrefix(finalizedText) else {
            throw DictationTranscriptLedgerError.finalizedTextRegressed
        }

        let confirmedDelta = String(confirmedText.dropFirst(finalizedText.count))
        if !confirmedDelta.isEmpty {
            finalizedSegments.append(DictationSegment(
                id: "final-\(finalizedSegments.count)",
                text: confirmedDelta
            ))
        }
        self.volatileText = volatileText
        revision &+= 1
        return snapshot(updatedAt: date)
    }

    /// Advances the active-session lease without changing transcript ownership. The keyboard
    /// intentionally rejects old active snapshots, so silence must still produce a fresh,
    /// monotonically revisioned snapshot rather than mutating `updatedAt` in place.
    @discardableResult
    public mutating func heartbeat(at date: Date = Date()) throws -> DictationSnapshot {
        guard phase == .active else {
            throw DictationTranscriptLedgerError.sessionAlreadyFinished
        }
        revision &+= 1
        return snapshot(updatedAt: date)
    }

    @discardableResult
    public mutating func finish(
        finalText: String,
        at date: Date = Date()
    ) throws -> DictationSnapshot {
        guard phase == .active else {
            throw DictationTranscriptLedgerError.sessionAlreadyFinished
        }
        guard finalText.hasPrefix(finalizedText) else {
            throw DictationTranscriptLedgerError.finalTextContradictsFinalizedPrefix
        }
        let finalDelta = String(finalText.dropFirst(finalizedText.count))
        if !finalDelta.isEmpty {
            finalizedSegments.append(DictationSegment(
                id: "final-\(finalizedSegments.count)",
                text: finalDelta
            ))
        }
        volatileText = ""
        phase = .finalized
        revision &+= 1
        return snapshot(updatedAt: date)
    }

    @discardableResult
    public mutating func cancel(at date: Date = Date()) throws -> DictationSnapshot {
        guard phase == .active else {
            throw DictationTranscriptLedgerError.sessionAlreadyFinished
        }
        volatileText = ""
        phase = .cancelled
        revision &+= 1
        return snapshot(updatedAt: date)
    }

    public func snapshot(updatedAt: Date? = nil) -> DictationSnapshot {
        DictationSnapshot(
            sessionID: sessionID,
            revision: revision,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt,
            phase: phase,
            finalizedSegments: finalizedSegments,
            volatileSegments: volatileText.isEmpty
                ? []
                : [DictationSegment(id: "volatile", text: volatileText)]
        )
    }
}
