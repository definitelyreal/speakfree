// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

/// Immutable, deterministic vocabulary lookup for tap-typing candidates and conservative correction.
public struct TypingSuggestionIndex: Sendable {
    private struct IndexedEntry: Sendable {
        let entry: VocabularyEntry
        let normalizedWord: String
    }

    private let entries: [IndexedEntry]
    private let exactWords: Set<String>
    private let prefixBuckets: [Character: [IndexedEntry]]
    private let lengthBuckets: [Int: [IndexedEntry]]

    public init(entries vocabularyEntries: [VocabularyEntry]) {
        var aggregated: [String: (word: String, frequency: Double)] = [:]
        for entry in vocabularyEntries {
            let normalized = Self.normalize(entry.word)
            guard !normalized.isEmpty else { continue }
            let frequency = entry.frequency.isFinite
                ? max(entry.frequency, Double.leastNonzeroMagnitude)
                : Double.leastNonzeroMagnitude
            if let existing = aggregated[normalized] {
                aggregated[normalized] = (existing.word, existing.frequency + frequency)
            } else {
                aggregated[normalized] = (entry.word, frequency)
            }
        }

        let indexedEntries = aggregated.map { normalized, value in
            IndexedEntry(
                entry: VocabularyEntry(word: value.word, frequency: value.frequency),
                normalizedWord: normalized
            )
        }
        entries = indexedEntries
        exactWords = Set(aggregated.keys)
        prefixBuckets = Dictionary(grouping: indexedEntries) { $0.normalizedWord.first! }
        lengthBuckets = Dictionary(grouping: indexedEntries) { $0.normalizedWord.count }
    }

    public init(words: [String]) {
        self.init(entries: words.map { VocabularyEntry(word: $0) })
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Returns frequency-ranked completions. The already-complete query is omitted.
    public func prefixSuggestions(for prefix: String, limit: Int = 3) -> [VocabularyEntry] {
        let normalizedPrefix = Self.normalize(prefix)
        guard !normalizedPrefix.isEmpty, limit > 0 else { return [] }

        let candidates = normalizedPrefix.first.flatMap { prefixBuckets[$0] } ?? []
        return candidates
            .filter {
                $0.normalizedWord.hasPrefix(normalizedPrefix)
                    && $0.normalizedWord != normalizedPrefix
            }
            .sorted(by: Self.frequencyOrder)
            .prefix(limit)
            .map(\.entry)
    }

    /// Returns typo corrections ordered by edit distance, frequency, then spelling.
    /// Inputs shorter than three characters and exact vocabulary words are deliberately untouched.
    public func correctionSuggestions(for word: String, limit: Int = 3) -> [VocabularyEntry] {
        let normalized = Self.normalize(word)
        guard normalized.count >= 3,
              limit > 0,
              !exactWords.contains(normalized) else { return [] }

        let maximumDistance = normalized.count >= 7 ? 2 : 1
        let candidateEntries = ((normalized.count - maximumDistance)...(normalized.count + maximumDistance))
            .flatMap { lengthBuckets[$0] ?? [] }
        let candidates: [(entry: IndexedEntry, distance: Int)] = candidateEntries.compactMap { entry in
            guard let distance = Self.boundedEditDistance(
                    normalized,
                    entry.normalizedWord,
                    maximum: maximumDistance
                  ),
                  distance > 0 else { return nil }
            return (entry, distance)
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return Self.frequencyOrder(lhs.entry, rhs.entry)
            }
            .prefix(limit)
            .map(\.entry.entry)
    }

    public func bestCorrection(for word: String) -> VocabularyEntry? {
        correctionSuggestions(for: word, limit: 1).first
    }

    private static func normalize(_ word: String) -> String {
        word
            .lowercased()
            .map { $0 == "’" ? "'" : $0 }
            .filter { $0.isLetter || $0 == "'" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func frequencyOrder(_ lhs: IndexedEntry, _ rhs: IndexedEntry) -> Bool {
        if lhs.entry.frequency != rhs.entry.frequency {
            return lhs.entry.frequency > rhs.entry.frequency
        }
        if lhs.normalizedWord.count != rhs.normalizedWord.count {
            return lhs.normalizedWord.count < rhs.normalizedWord.count
        }
        return lhs.normalizedWord < rhs.normalizedWord
    }

    /// Optimal-string-alignment distance with an early bounded result.
    /// Adjacent transpositions such as "teh" -> "the" count as one edit.
    private static func boundedEditDistance(
        _ source: String,
        _ target: String,
        maximum: Int
    ) -> Int? {
        let sourceCharacters = Array(source)
        let targetCharacters = Array(target)
        guard abs(sourceCharacters.count - targetCharacters.count) <= maximum else { return nil }

        var matrix = Array(
            repeating: Array(repeating: 0, count: targetCharacters.count + 1),
            count: sourceCharacters.count + 1
        )
        for sourceIndex in 0...sourceCharacters.count { matrix[sourceIndex][0] = sourceIndex }
        for targetIndex in 0...targetCharacters.count { matrix[0][targetIndex] = targetIndex }

        if !sourceCharacters.isEmpty, !targetCharacters.isEmpty {
            for sourceIndex in 1...sourceCharacters.count {
                var rowMinimum = Int.max
                for targetIndex in 1...targetCharacters.count {
                    let substitutionCost = sourceCharacters[sourceIndex - 1]
                        == targetCharacters[targetIndex - 1] ? 0 : 1
                    var distance = min(
                        matrix[sourceIndex - 1][targetIndex] + 1,
                        matrix[sourceIndex][targetIndex - 1] + 1,
                        matrix[sourceIndex - 1][targetIndex - 1] + substitutionCost
                    )
                    if sourceIndex > 1,
                       targetIndex > 1,
                       sourceCharacters[sourceIndex - 1] == targetCharacters[targetIndex - 2],
                       sourceCharacters[sourceIndex - 2] == targetCharacters[targetIndex - 1] {
                        distance = min(distance, matrix[sourceIndex - 2][targetIndex - 2] + 1)
                    }
                    matrix[sourceIndex][targetIndex] = distance
                    rowMinimum = min(rowMinimum, distance)
                }
                // When the whole active row is already outside the bound and the remaining target
                // cannot shrink the length gap, no later row can produce an in-bound result.
                if rowMinimum > maximum,
                   sourceIndex >= targetCharacters.count + maximum {
                    return nil
                }
            }
        }

        let result = matrix[sourceCharacters.count][targetCharacters.count]
        return result <= maximum ? result : nil
    }
}
