// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import Foundation
import SpeakFreeKeyboardCore

enum EnglishVocabularyLoader {
    static func load(bundle: Bundle = .main) throws -> VocabularyTrie {
        VocabularyTrie(entries: try loadEntries(bundle: bundle))
    }

    static func loadEntries(bundle: Bundle = .main) throws -> [VocabularyEntry] {
        guard let url = bundle.url(forResource: "wordfreq-en-25000-log", withExtension: "json") else {
            return fallbackWords.map { VocabularyEntry(word: $0) }
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] ?? []
        let entries = rows.compactMap { row -> VocabularyEntry? in
            guard row.count == 2,
                  let word = row[0] as? String,
                  let logFrequency = row[1] as? Double,
                  word.allSatisfy({ $0.isLetter || $0 == "'" }),
                  word.count >= 2 else { return nil }
            return VocabularyEntry(word: word, frequency: exp(logFrequency) * 1_000_000_000)
        }
        return entries
    }

    private static let fallbackWords = [
        "a", "about", "and", "are", "as", "at", "be", "but", "by", "can", "come",
        "computer", "do", "for", "from", "get", "go", "good", "have", "hello", "how",
        "i", "if", "in", "is", "it", "just", "like", "make", "me", "my", "not", "of",
        "on", "one", "or", "our", "out", "say", "see", "so", "speakfree", "that", "the",
        "their", "there", "they", "this", "time", "to", "type", "up", "use", "want", "we",
        "well", "what", "when", "which", "who", "will", "with", "word", "work", "would", "you"
    ]
}
