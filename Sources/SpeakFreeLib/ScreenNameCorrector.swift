import Foundation

/// Screen-aware proper-noun correction (2026-07-25, Michael's revival of the
/// screenContext feature for the Parakeet path).
///
/// The ASR always picks the COMMON spelling of a homophone name — dictating about
/// Kris yields "Chris" no matter how good the acoustics are, because the audio is
/// identical. But when the screen visibly shows "Kris" (the chat thread, the email,
/// the document being replied to), the on-screen spelling is authoritative for THIS
/// dictation. This corrector rewrites transcript tokens to an on-screen spelling
/// when, and only when, the evidence is strong:
///
///   * the screen token and transcript token share a phonetic key (homophones)
///     and differ in spelling by at most 2 edits;
///   * the screen token appears at least `minOccurrences` times in the OCR text
///     (a name in a conversation recurs; incidental words usually don't);
///   * the screen token is NOT a common dictionary word ("Can", "He", "Aw" — OCR
///     of any chat is full of capitalized sentence-starts);
///   * both tokens are capitalized (proper-noun shaped).
///
/// Deliberately conservative: it fires on nothing at all in the absence of screen
/// text, and a wrong non-fire (missed correction) is always preferred over a wrong
/// fire (mangled word).
public enum ScreenNameCorrector {

    /// Phonetic key: collapses homophone spellings of names onto one string.
    /// Not a general phonetic algorithm — just the confusion classes ASR actually
    /// produces for names: Chris/Kris, Cathy/Kathy, Zander/Xander, Jon/John,
    /// Sara/Sarah, Eric/Erik, Mark/Marc.
    static func phoneticKey(_ word: String) -> String {
        var s = word.uppercased().filter { $0.isLetter }
        guard !s.isEmpty else { return s }
        // Leading-consonant confusions
        for (from, to) in [("CHR", "KR"), ("CR", "KR"), ("CK", "K"), ("PH", "F"),
                           ("X", "Z"), ("JH", "J"), ("GE", "JE"), ("GI", "JI")] {
            if s.hasPrefix(from) { s = to + s.dropFirst(from.count) }
        }
        // C sounding as K elsewhere; QU→KW; doubled letters collapse
        s = s.replacingOccurrences(of: "QU", with: "KW")
        s = s.replacingOccurrences(of: "C", with: "K")
        var collapsed = ""
        for ch in s where collapsed.last != ch { collapsed.append(ch) }
        // Trailing silent H (Sarah/Sara, Hannah/Hanna)
        if collapsed.hasSuffix("H") { collapsed.removeLast() }
        return collapsed
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let aa = Array(a.lowercased()), bb = Array(b.lowercased())
        var prev = Array(0...bb.count)
        for i in 1...max(aa.count, 1) where !aa.isEmpty {
            var cur = [i] + [Int](repeating: 0, count: bb.count)
            for j in 1...max(bb.count, 1) where !bb.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (aa[i - 1] == bb[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[bb.count]
    }

    /// Extract candidate proper nouns from OCR text: capitalized, 3–20 letters,
    /// recurring, and not a common dictionary word.
    static func candidateNames(fromScreenText screen: String,
                               minOccurrences: Int = 2,
                               isRealWord: (String) -> Bool) -> [String] {
        var counts: [String: Int] = [:]
        let tokens = screen.split(whereSeparator: { !$0.isLetter })
        for t in tokens {
            let word = String(t)
            guard word.count >= 3, word.count <= 20,
                  word.first!.isUppercase,
                  word.dropFirst().allSatisfy({ $0.isLowercase }) else { continue }
            counts[word, default: 0] += 1
        }
        return counts.filter { $0.value >= minOccurrences && !isRealWord($0.key.lowercased()) }
            .map(\.key)
    }

    /// Rewrite transcript tokens to on-screen spellings under the guards above.
    public static func correct(_ text: String,
                               screenText: String?,
                               isRealWord: (String) -> Bool = GlossaryCorrector.systemIsRealWord) -> String {
        guard let screen = screenText, !screen.isEmpty, !text.isEmpty else { return text }
        let names = candidateNames(fromScreenText: screen, isRealWord: isRealWord)
        guard !names.isEmpty else { return text }
        let keyed = Dictionary(grouping: names, by: phoneticKey)

        var out: [String] = []
        for chunk in text.split(separator: " ", omittingEmptySubsequences: false) {
            let word = String(chunk)
            // Split trailing punctuation off the token.
            let core = word.prefix(while: { $0.isLetter || $0 == "'" })
            let tail = word.dropFirst(core.count)
            let token = String(core)
            guard token.count >= 3, token.first?.isUppercase == true else {
                out.append(word); continue
            }
            if let matches = keyed[phoneticKey(token)],
               matches.count == 1,                       // unambiguous on-screen target
               let name = matches.first,
               name != token,                            // different spelling
               editDistance(name, token) <= 2 {
                out.append(name + tail)
            } else {
                out.append(word)
            }
        }
        return out.joined(separator: " ")
    }
}
