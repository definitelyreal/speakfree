import Foundation

/// A single repair the cleanup model proposes: replace the (unique) occurrence of `find` with
/// `replace`, for the stated `reason` (the maintainer 2026-08-28; the 08-05 settled design). The edits
/// ARE the diff — animation targets, hover tooltips ("was: … — reason"), and per-edit revert come
/// free. Structured span edits (not a rewrite) bound confabulation: the cleanup-ladder study
/// (an internal speech audit, cleanup-ladder finding) showed every model invents
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
    case overlap              // the edit's changed text collides with an already-accepted edit's
    case duplicate            // the same change (same place, same new text) was already accepted
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
    ///  - Every edit is matched against the ORIGINAL text and reduced to its changed core: the
    ///    characters it shares with its replacement at the start and end are context, not change
    ///    ("eggs Kama bread" -> "eggs, bread" changes only " Kama" -> ","). Conflicts are judged
    ///    on cores, so fixes that merely share context words all apply (real calls, 2026-09-29: a
    ///    dictated list anchored each comma on its neighbours, and the middle one was lost), while
    ///    two fixes that change the same characters still conflict (`.overlap`). An insertion
    ///    that touches another core, or falls inside it, conflicts too.
    ///  - A core identical to an accepted one (same place, same new text) is the same repair
    ///    proposed twice ("Tom" -> "Tom," and "Hi Tom" -> "Hi Tom,") and applies once
    ///    (`.duplicate`).
    ///  - Cores are applied from the last to the first so earlier offsets never shift. The result
    ///    is exactly what applying each whole edit would give.
    ///  - With `absorbSpace` (every cleanup path; undo passes false), a replacement that starts
    ///    with attaching punctuation takes the space before its anchor. See
    ///    `absorbingSpaceBeforePunctuation`. If only the widened core conflicts, the plain one
    ///    is used.
    ///  - Rejections record the edit as the model proposed it; `applied` records the edits as they
    ///    ran (whole, with any absorbed space), in proposal order, so undoing one restores its
    ///    text exactly.
    public static func apply(_ edits: [SpanEdit], to text: String,
                             absorbSpace: Bool = true) -> SpanEditApplication {
        var rejected: [SpanEditApplication.Rejected] = []
        var accepted: [(index: Int, edit: SpanEdit, core: Range<String.Index>, newText: String)] = []

        func conflict(_ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
            if a.overlaps(b) { return true }
            if a.isEmpty || b.isEmpty {
                // An insertion conflicts with a core it falls inside or starts at (order there is
                // undefined). At a non-empty core's END it is fine: applied last to first, it
                // lands right after that change ("Katy" -> "Katie" plus a comma after it).
                let (point, other) = a.isEmpty ? (a.lowerBound, b) : (b.lowerBound, a)
                if !other.isEmpty && point == other.upperBound { return false }
                return point >= other.lowerBound && point <= other.upperBound
            }
            return false
        }

        for (index, proposed) in edits.enumerated() {
            if proposed.find.isEmpty {
                rejected.append(.init(edit: proposed, cause: .emptyFind)); continue
            }
            if proposed.find == proposed.replace {
                rejected.append(.init(edit: proposed, cause: .noOp)); continue
            }
            if containsDisallowedCharacter(proposed.replace) {
                rejected.append(.init(edit: proposed, cause: .invalidReplacement)); continue
            }
            let ranges = allRanges(of: proposed.find, in: text)
            guard !ranges.isEmpty else {
                rejected.append(.init(edit: proposed, cause: .noMatch)); continue
            }
            guard ranges.count == 1 else {
                rejected.append(.init(edit: proposed, cause: .ambiguousMatch)); continue
            }
            var candidates: [(edit: SpanEdit, range: Range<String.Index>)] = []
            if absorbSpace, let wide = absorbingSpaceBeforePunctuation(proposed, in: text) {
                candidates.append(wide)
            }
            candidates.append((proposed, ranges[0]))

            var outcome: SpanEditRejection? = .overlap
            for candidate in candidates {
                let (core, coreText) = changedCore(of: candidate.edit, at: candidate.range, in: text)
                var newText = coreText
                if accepted.contains(where: { $0.core == core && $0.newText == newText }) {
                    outcome = .duplicate; break
                }
                // An insertion at the end of a change that already ends with the same text is that
                // change's own last characters proposed again ("Tom" -> "Tom," beside
                // "b Kama Tom" -> "b, Tom,"): a duplicate.
                if core.isEmpty, accepted.contains(where: { x in
                    !x.core.isEmpty && core.lowerBound == x.core.upperBound && x.newText.hasSuffix(newText)
                }) { outcome = .duplicate; break }
                // The other order: this change ends where an accepted insertion adds the same
                // characters. Drop the repeat from this change and keep the rest of its repair.
                if !core.isEmpty, let x = accepted.first(where: { x in
                    x.core.isEmpty && !x.newText.isEmpty && x.core.lowerBound == core.upperBound
                        && newText.hasSuffix(x.newText)
                }) {
                    newText = String(newText.dropLast(x.newText.count))
                }
                // Two changes that meet edge to edge must not repeat a punctuation mark across the
                // seam ("U.S.A." then ". Now" would read "U.S.A.. Now").
                let seamRepeat = accepted.contains { x in
                    guard !x.core.isEmpty, !core.isEmpty else { return false }
                    if x.core.upperBound == core.lowerBound, let last = x.newText.last, last.isPunctuation,
                       newText.first == last { return true }
                    if core.upperBound == x.core.lowerBound, let last = newText.last, last.isPunctuation,
                       x.newText.first == last { return true }
                    return false
                }
                if seamRepeat { continue }
                if accepted.contains(where: { conflict($0.core, core) }) { continue }
                // Record the edit as it runs: if a repeat was trimmed, rebuild the whole
                // replacement around the trimmed core so a per-fix undo restores only this fix.
                let ran = newText == coreText ? candidate.edit : SpanEdit(
                    find: candidate.edit.find,
                    replace: String(text[candidate.range.lowerBound..<core.lowerBound]) + newText
                        + String(text[core.upperBound..<candidate.range.upperBound]),
                    reason: candidate.edit.reason)
                accepted.append((index, ran, core, newText))
                outcome = nil
                break
            }
            if let cause = outcome { rejected.append(.init(edit: proposed, cause: cause)) }
        }

        var result = text
        for entry in accepted.sorted(by: { $0.core.lowerBound > $1.core.lowerBound }) {
            result.replaceSubrange(entry.core, with: entry.newText)
        }
        let applied = accepted.sorted(by: { $0.index < $1.index }).map(\.edit)
        return SpanEditApplication(text: result, applied: applied, rejected: rejected)
    }

    /// The part of `text[range]` an edit actually changes, and what replaces it: the common
    /// leading and trailing characters of the matched text and the replacement are dropped.
    static func changedCore(of edit: SpanEdit, at range: Range<String.Index>, in text: String)
        -> (Range<String.Index>, String) {
        let old = Array(text[range])
        let new = Array(edit.replace)
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let lower = text.index(range.lowerBound, offsetBy: head)
        let upper = text.index(range.upperBound, offsetBy: -tail)
        return (lower..<upper, String(new[head..<(new.count - tail)]))
    }

    /// Punctuation a spoken command turns into. When an edit replaces a word with one of these
    /// ("Kama" -> ","), the space before that word must go too, or the result reads "milk , bread".
    /// Real Sonnet calls (2026-09-29) anchored on the bare word in 4 of 9 such repairs.
    static let attachingPunctuation: Set<Character> = [",", ".", ";", ":", "?", "!"]

    /// The edit widened to take in the single space before `find`, with its range in `text`, or
    /// nil. Widens only when `replace` starts with attaching punctuation that stands alone (the
    /// mark is the whole replacement, or is followed by whitespace or more punctuation: "," ", "
    /// ". Then" "..."), never for ".NET" or ".5", when `find` does not already start with
    /// whitespace, and when both `find` and the widened span are unique in `text`.
    static func absorbingSpaceBeforePunctuation(_ edit: SpanEdit, in text: String)
        -> (edit: SpanEdit, range: Range<String.Index>)? {
        guard let r = edit.replace.first, attachingPunctuation.contains(r),
              let f = edit.find.first, !f.isWhitespace else { return nil }
        let rest = edit.replace.dropFirst()
        if let next = rest.first, !next.isWhitespace, !next.isPunctuation { return nil }
        let widened = " " + edit.find
        guard allRanges(of: edit.find, in: text).count == 1 else { return nil }
        let wideRanges = allRanges(of: widened, in: text)
        guard wideRanges.count == 1 else { return nil }
        return (SpanEdit(find: widened, replace: edit.replace, reason: edit.reason), wideRanges[0])
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
    static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            ranges.append(r)
            // Step one character, not past the match: "aba" occurs twice in "ababa", and an
            // anchor that can land in two places is not unique (review 2026-09-29).
            searchStart = haystack.index(after: r.lowerBound)
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
    case notJSONArray   // prose-wrapped / fence plus prose / not a bare `[ … ]`
    case malformed      // starts and ends like an array but is not valid JSON
    case wrongShape     // valid JSON array, but not [{find, replace, reason}]
}

public enum SpanEditParser {

    /// Strictly parse the cleanup model's stdout. The hardened prompt demands ONLY the JSON array,
    /// so anything else is a contract violation and is rejected (never salvaged):
    ///  - prose-wrapped output, or a fence with anything around it, does not trim to a bare `[ … ]` → notJSONArray
    ///  - a bare array that is not valid JSON → malformed
    ///  - valid JSON that is not an array of {find, replace, reason} → wrongShape
    ///  - `[]` is valid and means "no repairs" (parsed with zero edits)
    ///
    /// Rejecting rather than extracting-from-noise matters because the transcript is untrusted: a
    /// model that wrapped the array in prose is not following the contract, and honoring a stray
    /// array buried in that prose is exactly the confabulation surface span edits exist to bound.
    ///
    /// One exception, from real CLI calls on 2026-09-29: when the WHOLE output is a single code
    /// fence (```` ```json ```` or ```` ``` ```` on the first line, ```` ``` ```` on the last, nothing before
    /// or after, no other fence inside), the fence is packaging, not prose, and the body is parsed
    /// under the same strict rules. Haiku fenced 11 of 12 answers and Sonnet 2 of 12 despite the
    /// prompt, and every one of those was dropped as "not a list of fixes". Prose before, after or
    /// around a fence is still rejected.
    public static func parse(_ output: String) -> SpanEditParse {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }
        if trimmed.hasPrefix("```") {
            guard let body = unwrapWholeOutputFence(trimmed) else { return .rejected(.notJSONArray) }
            trimmed = body
            guard !trimmed.isEmpty else { return .rejected(.empty) }
        }
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

    /// The body of an output that is exactly one fenced block, or nil. The opening line may carry
    /// only an optional `json` language tag; the closing line must be the bare fence.
    static func unwrapWholeOutputFence(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        let open = lines.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        let close = lines.removeLast().trimmingCharacters(in: .whitespaces)
        guard open == "```" || open == "```json", close == "```" else { return nil }
        let body = lines.joined(separator: "\n")
        guard !body.contains("```") else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
