import Foundation

class WordMemory {
    private static var wordsFile: URL {
        Config.configDir.appendingPathComponent("dictionary.json")
    }

    /// All remembered word corrections: wrong → right
    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: wordsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ words: [String: String]) {
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(words) else { return }
        try? data.write(to: wordsFile)
    }

    static func remember(wrong: String, right: String) {
        var words = load()
        words[wrong.lowercased()] = right
        save(words)
        addToVocabulary(right)
    }

    static func forget(_ wrong: String) {
        var words = load()
        let right = words.removeValue(forKey: wrong.lowercased())
        save(words)
        if let right = right {
            removeFromVocabulary(right)
        }
    }

    static func resetAll() {
        let words = load()
        try? FileManager.default.removeItem(at: wordsFile)
        for right in words.values {
            removeFromVocabulary(right)
        }
    }

    /// Represents a word entry from vocabulary.txt
    struct VocabEntry {
        let word: String
        let isAuto: Bool
    }

    /// Load all entries from vocabulary.txt with auto/manual annotation
    static func loadVocabularyEntries() -> [VocabEntry] {
        guard let content = try? String(contentsOf: Config.vocabularyFile, encoding: .utf8) else { return [] }
        return content.components(separatedBy: .newlines)
            .compactMap { line -> VocabEntry? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return nil }
                // Check for "word # auto" suffix
                if let hashRange = trimmed.range(of: " # auto", options: .backwards) {
                    let word = String(trimmed[..<hashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    return word.isEmpty ? nil : VocabEntry(word: word, isAuto: true)
                }
                return VocabEntry(word: trimmed, isAuto: false)
            }
    }

    /// Load just the words (for Whisper prompt — strips "# auto" annotations)
    static func loadVocabularyWords() -> [String] {
        return loadVocabularyEntries().map { $0.word }
    }

    /// Remove a word from vocabulary.txt (for manual words not in dictionary.json)
    static func removeFromVocab(_ word: String) {
        removeFromVocabulary(word)
    }

    // MARK: - Vocabulary sync

    private static func addToVocabulary(_ word: String) {
        let url = Config.vocabularyFile
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)

        var lines: [String] = []
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            lines = content.components(separatedBy: .newlines)
        }

        // Don't add if already present (with or without # auto suffix)
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        let alreadyExists = lines.contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l == trimmed || l == "\(trimmed) # auto"
        }
        if alreadyExists { return }

        lines.append("\(trimmed) # auto")
        let content = lines.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func removeFromVocabulary(_ word: String) {
        let url = Config.vocabularyFile
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        let trimmed = word.trimmingCharacters(in: .whitespaces)
        let lines = content.components(separatedBy: .newlines)
            .filter { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l != trimmed && l != "\(trimmed) # auto"
            }
        let updated = lines.joined(separator: "\n")
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
