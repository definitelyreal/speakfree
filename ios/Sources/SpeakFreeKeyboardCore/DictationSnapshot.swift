// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

/// One exact text span emitted by the speech recognizer. Segment identifiers remain stable while
/// text is promoted from `volatileSegments` to `finalizedSegments`.
public struct DictationSegment: Codable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum DictationSessionPhase: String, Codable, Equatable, Sendable {
    case active
    case finalized
    case cancelled
}

public enum DictationSnapshotValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case emptySegmentIdentifier
    case duplicateSegmentIdentifier(String)
    case volatileSegmentsInTerminalSnapshot
    case invalidTimestampOrder
}

/// Versioned handoff payload shared by the containing app and keyboard extension.
///
/// Segment text is an exact span: no whitespace or punctuation is added while rendering. Finalized
/// segments are append-only within a session; volatile segments may be rewritten by later revisions.
public struct DictationSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: UUID
    public let revision: UInt64
    public let createdAt: Date
    public let updatedAt: Date
    public let phase: DictationSessionPhase
    public let finalizedSegments: [DictationSegment]
    public let volatileSegments: [DictationSegment]

    public init(
        schemaVersion: Int = DictationSnapshot.currentSchemaVersion,
        sessionID: UUID,
        revision: UInt64,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        phase: DictationSessionPhase = .active,
        finalizedSegments: [DictationSegment] = [],
        volatileSegments: [DictationSegment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.finalizedSegments = finalizedSegments
        self.volatileSegments = volatileSegments
    }

    public var finalizedText: String {
        finalizedSegments.map(\.text).joined()
    }

    public var volatileText: String {
        volatileSegments.map(\.text).joined()
    }

    public var renderedText: String {
        finalizedText + volatileText
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DictationSnapshotValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard updatedAt >= createdAt else {
            throw DictationSnapshotValidationError.invalidTimestampOrder
        }
        if phase != .active, !volatileSegments.isEmpty {
            throw DictationSnapshotValidationError.volatileSegmentsInTerminalSnapshot
        }

        var identifiers = Set<String>()
        for segment in finalizedSegments + volatileSegments {
            guard !segment.id.isEmpty else {
                throw DictationSnapshotValidationError.emptySegmentIdentifier
            }
            guard identifiers.insert(segment.id).inserted else {
                throw DictationSnapshotValidationError.duplicateSegmentIdentifier(segment.id)
            }
        }
    }

    /// Prevents a crashed or long-finished app session from inserting text when the keyboard is
    /// opened much later. A small future tolerance accommodates wall-clock skew during testing.
    public func isFresh(
        at referenceDate: Date = Date(),
        maximumAge: TimeInterval = 15
    ) -> Bool {
        updatedAt <= referenceDate.addingTimeInterval(5)
            && referenceDate.timeIntervalSince(updatedAt) <= maximumAge
    }
}
