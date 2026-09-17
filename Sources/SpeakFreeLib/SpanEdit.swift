import Foundation

/// A single repair the cleanup model proposes: replace the (unique) occurrence of `find` with
/// `replace`, for the stated `reason` (Michael 2026-08-28; the 08-05 settled design). The edits
/// ARE the diff — animation targets, hover tooltips ("was: … — reason"), and per-edit revert come
/// free. Structured span edits (not a rewrite) bound confabulation: the cleanup-ladder study
/// (build/26-07-25-speech-audit/findings/22-cleanup-ladder.md) showed every model invents
/// specifics once it is allowed to rewrite, so cleanup is repair-only and every repair must match
/// the current text exactly.
public struct SpanEdit: Codable, Equatable {
    public let find: String
    public let replace: String
    public let reason: String

    public init(find: String, replace: String, reason: String) {
        self.find = find
        self.replace = replace
        self.reason = reason
    }
}

/// Why a proposed edit did not apply. Recorded so unapplied edits are never silently dropped — the
/// cleanup log carries the cause (the "I Will" glossary bug, mine-claude-corrections.py, is the
/// precedent for auditing what a correction layer did and did not do).
public enum SpanEditRejection: String, Equatable, Codable {
    case emptyFind            // find was empty — nothing to locate
    case noOp                 // find == replace — applying it changes nothing
    case noMatch              // find does not occur in the current text
    case ambiguousMatch       // find occurs more than once — not a unique anchor
    case overlap              // the match overlaps an already-accepted edit's range
    case invalidReplacement   // replace carries a newline or control character (rejected, see below)
}

/// The outcome of applying a batch of span edits to one segment's current text.
public struct SpanEditApplication: Equatable {
    public let text: String
    public let applied: [SpanEdit]
    public let rejected: [Rejected]

    public struct Rejected: Equatable {
        public let edit: SpanEdit
        public let cause: SpanEditRejection
    }
}

public enum SpanEditApplier {

    /// Apply `edits` to `text`, honoring only edits that anchor UNIQUELY and do not collide.
    ///
    /// Rules (each rejection is recorded, never silently dropped):
    ///  - `find` must be non-empty and occur EXACTLY once in the current text (a non-unique anchor
    ///    is ambiguous and could relocate the repair — reject it).
    ///  - `replace` must not introduce a newline or any other control character. We REJECT rather
    ///    than strip: the transcript feeding the model is untrusted (prompt-injection surface, C6),
    ///    and a silently stripped replacement is an un-auditable mutation of the model's output;
    ///    a newline would also change paragraph/segment identity (C3), which a span edit may never do.
    ///  - Accepted edits are matched against the ORIGINAL text; if two accepted matches overlap, the
    ///    later one is rejected. Edits are then applied from the last match to the first so earlier
    ///    offsets never shift.
    public static func apply(_ edits: [SpanEdit], to text: String) -> SpanEditApplication {
        var applied: [SpanEdit] = []
        var rejected: [SpanEditApplication.Rejected] = []
        // Accepted (edit, matched range in `text`), collected before any mutation so overlap is
        // checked against stable offsets.
        var accepted: [(edit: SpanEdit, range: Range<String.Index>)] = []

        for edit in edits {
            if edit.find.isEmpty {
                rejected.append(.init(edit: edit, cause: .emptyFind)); continue
            }
            if edit.find == edit.replace {
                rejected.append(.init(edit: edit, cause: .noOp)); continue
            }
            if containsDisallowedCharacter(edit.replace) {
                rejected.append(.init(edit: edit, cause: .invalidReplacement)); continue
            }
            let ranges = allRanges(of: edit.find, in: text)
            guard !ranges.isEmpty else {
                rejected.append(.init(edit: edit, cause: .noMatch)); continue
            }
            guard ranges.count == 1 else {
                rejected.append(.init(edit: edit, cause: .ambiguousMatch)); continue
            }
            let range = ranges[0]
            if accepted.contains(where: { $0.range.overlaps(range) }) {
                rejected.append(.init(edit: edit, cause: .overlap)); continue
            }
            accepted.append((edit, range))
        }

        // Apply from the last match to the first so mutating an earlier span never invalidates a
        // later, already-computed index.
        var result = text
        for entry in accepted.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(entry.range, with: entry.edit.replace)
            applied.append(entry.edit)
        }
        // `applied` is built in reverse-application order; present it in the edits' original order.
        let appliedInOrder = edits.filter { e in applied.contains(where: { $0 == e }) }
        return SpanEditApplication(text: result, applied: appliedInOrder, rejected: rejected)
    }

    /// True if `s` contains a newline or any Unicode control character. Emoji and combining marks
    /// are NOT control characters and are allowed (the applier is unicode-safe).
    static func containsDisallowedCharacter(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { return true }
            if scalar.properties.generalCategory == .control { return true }
        }
        return false
    }

    /// Every non-overlapping occurrence of `needle` in `haystack` (exact substring match).
    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound  // non-overlapping: continue past this match
        }
        return ranges
    }
}

/// The result of parsing the cleanup model's stdout into span edits.
public enum SpanEditParse: Equatable {
    case parsed([SpanEdit])
    case rejected(SpanEditParseError)
}

public enum SpanEditParseError: String, Equatable {
    case empty          // output was blank
    case notJSONArray   // fenced / prose-wrapped / not a bare `[ … ]`
    case malformed      // starts and ends like an array but is not valid JSON
    case wrongShape     // valid JSON array, but not [{find, replace, reason}]
}

public enum SpanEditParser {

    /// Strictly parse the cleanup model's stdout. The hardened prompt demands ONLY the JSON array,
    /// so anything else is a contract violation and is rejected (never salvaged):
    ///  - fenced (```json … ```) or prose-wrapped output does not trim to a bare `[ … ]` → notJSONArray
    ///  - a bare array that is not valid JSON → malformed
    ///  - valid JSON that is not an array of {find, replace, reason} → wrongShape
    ///  - `[]` is valid and means "no repairs" (parsed with zero edits)
    ///
    /// Rejecting rather than extracting-from-noise matters because the transcript is untrusted: a
    /// model that wrapped the array in prose is not following the contract, and honoring a stray
    /// array buried in that prose is exactly the confabulation surface span edits exist to bound.
    public static func parse(_ output: String) -> SpanEditParse {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return .rejected(.notJSONArray)
        }
        let data = Data(trimmed.utf8)
        // First confirm it is valid JSON at all (distinguishes malformed from wrong-shape).
        guard let json = try? JSONSerialization.jsonObject(with: data),
              json is [Any] else {
            return .rejected(.malformed)
        }
        guard let edits = try? JSONDecoder().decode([SpanEdit].self, from: data) else {
            return .rejected(.wrongShape)
        }
        return .parsed(edits)
    }
}
