// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

public struct VocabularyEntry: Equatable, Sendable {
    public let word: String
    public let frequency: Double

    public init(word: String, frequency: Double = 1) {
        self.word = word
        self.frequency = frequency
    }
}

public struct VocabularyTrie: Sendable {
    struct Node: Sendable {
        var children: [Character: Int] = [:]
        var terminalFrequency: Double?
    }

    private(set) var nodes: [Node] = [Node()]

    public init(entries: [VocabularyEntry]) {
        for entry in entries {
            insert(entry)
        }
    }

    public init(words: [String]) {
        self.init(entries: words.map { VocabularyEntry(word: $0) })
    }

    public var isEmpty: Bool { nodes[0].children.isEmpty }

    public func contains(_ word: String) -> Bool {
        guard let node = nodeIndex(for: normalizedWord(word)) else { return false }
        return nodes[node].terminalFrequency != nil
    }

    public func containsPrefix(_ prefix: String) -> Bool {
        nodeIndex(for: normalizedWord(prefix)) != nil
    }

    func child(of node: Int, character: Character) -> Int? {
        nodes[node].children[character]
    }

    func terminalFrequency(at node: Int) -> Double? {
        nodes[node].terminalFrequency
    }

    private mutating func insert(_ entry: VocabularyEntry) {
        let word = normalizedWord(entry.word)
        guard !word.isEmpty else { return }

        var nodeIndex = 0
        for character in word {
            if let existing = nodes[nodeIndex].children[character] {
                nodeIndex = existing
            } else {
                let newIndex = nodes.count
                nodes.append(Node())
                nodes[nodeIndex].children[character] = newIndex
                nodeIndex = newIndex
            }
        }
        let positiveFrequency = max(entry.frequency, Double.leastNonzeroMagnitude)
        nodes[nodeIndex].terminalFrequency =
            (nodes[nodeIndex].terminalFrequency ?? 0) + positiveFrequency
    }

    private func nodeIndex(for text: String) -> Int? {
        var node = 0
        for character in text {
            guard let next = nodes[node].children[character] else { return nil }
            node = next
        }
        return node
    }
}

private func normalizedWord(_ word: String) -> String {
    word.lowercased().filter { $0.isLetter || $0 == "'" }
}
