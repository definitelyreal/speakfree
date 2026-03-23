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
    }

    static func forget(_ wrong: String) {
        var words = load()
        words.removeValue(forKey: wrong.lowercased())
        save(words)
    }

    static func resetAll() {
        try? FileManager.default.removeItem(at: wordsFile)
    }

    /// Build a prompt hint from remembered words for whisper context
    static func promptHint() -> String? {
        let words = load()
        if words.isEmpty { return nil }
        return words.values.joined(separator: ", ")
    }
}
