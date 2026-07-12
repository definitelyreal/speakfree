import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Curated, similarity-gated proper-noun corrector.
///
/// Fixes near-miss ASR misspellings of user-curated glossary names
/// (e.g. "Rorlick" → "Rohrlich", "Pesa" → "Pessah") so custom names come out
/// right — including on the default **Parakeet** engine, where prompt-biasing is
/// impossible (Parakeet ignores the glossary prompt entirely). It runs on the
/// transcript text, so it is engine-agnostic (Parakeet AND Whisper).
///
/// This is NOT the auto-learning `dictionary.json` find/replace that was removed
/// 2026-06-11. That one *learned* pairs and accumulated garbage (truncations like
/// `coul→could`, quote-noise `don't→don't`, common→common `selection→election`).
/// This corrector:
///   - contains ONLY curated proper nouns (vocabulary.txt: manual / Contacts /
///     Brain) — it never learns;
///   - has a **real-word guard**: a token the system spell-checker recognizes is
///     NEVER altered, so genuine words ("marina", "election", "could") are safe
///     even when similar to a name. Injectable via `isRealWord` for tests;
///   - only fires on a token within a tight edit distance of EXACTLY ONE glossary
///     term (ambiguous matches are skipped), length ≥ 4.
///
/// Deliberately conservative: it would rather miss a correction than mangle a real
/// word. Ambiguous homophones (e.g. "marina" the harbor vs the name "Maryna") are
/// intentionally left alone — disambiguating those needs context/CTC biasing, a
/// documented future upgrade.
public enum GlossaryCorrector {

    /// Production real-word check: true when the macOS spell checker finds no
    /// misspelling in `word` (i.e. it is a legitimate word and must not be touched).
    public static func systemIsRealWord(_ word: String) -> Bool {
        #if canImport(AppKit)
        let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0)
        return range.location == NSNotFound
        #else
        return false
        #endif
    }

    /// Correct near-miss misspellings of curated single-word glossary terms.
    ///
    /// - Parameters:
    ///   - text: the transcript to correct.
    ///   - glossary: curated proper-noun terms (single words; multi-word terms are
    ///     ignored for now — a future enhancement).
    ///   - isRealWord: returns true if a token is a legitimate word that must NOT be
    ///     corrected. Defaults to the system spell checker; tests inject a fixture.
    ///   - overrides: curated exact garble→correct map (lowercased key → replacement).
    ///     Applied BEFORE the fuzzy logic and the real-word guard, for known recurring
    ///     mistranscriptions the fuzzy path can't safely fix — either because the garble
    ///     is itself a real word (e.g. "kama"→"Karma": the guard would block it) or it's
    ///     a short token below the fuzzy threshold (e.g. "crf"→"CRM"). Curated only;
    ///     nothing auto-learns into this.
    public static func correct(_ text: String,
                               glossary: [String],
                               overrides: [String: String] = [:],
                               isRealWord: (String) -> Bool = GlossaryCorrector.systemIsRealWord) -> String {
        guard !text.isEmpty, !glossary.isEmpty || !overrides.isEmpty else { return text }

        // Build lowercased-term → canonical-spelling map (single-word terms only).
        var canonical: [String: String] = [:]
        for term in glossary {
            let t = term.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.contains(" ") else { continue }
            canonical[t.lowercased()] = t
        }
        let terms = Array(canonical.keys)

        // Walk word tokens, emitting all non-word characters (spaces, punctuation,
        // newlines) verbatim so spacing/punctuation is exactly preserved.
        var result = ""
        var word = ""
        func flush() {
            if !word.isEmpty {
                result += correctedToken(word, canonical: canonical, terms: terms,
                                         overrides: overrides, isRealWord: isRealWord)
                word = ""
            }
        }
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                word.append(ch)
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }

    private static func correctedToken(_ token: String,
                                       canonical: [String: String],
                                       terms: [String],
                                       overrides: [String: String],
                                       isRealWord: (String) -> Bool) -> String {
        let lower = token.lowercased()

        // Curated exact override wins over everything — bypasses the real-word guard
        // and the length/edit-distance gates, because these are explicitly-listed,
        // user-confirmed corrections (e.g. "kama"→"Karma", "crf"→"CRM").
        if let forced = overrides[lower] { return forced }

        // Exact glossary term (any case) → normalize to the curated spelling
        // (e.g. mid-sentence "bexx" → "Bexx"; names keep their case).
        //
        // Real-word guard applies HERE too (audit 2026-07-01). On this path the
        // token already has the same letters as the term, so the only possible
        // "correction" is capitalization — and vocabulary comes from Contacts/
        // Brain, where names that are also common words are routine ("Will",
        // "Mark", "Grace", "Rose"). Without the guard, "i will send it" became
        // "I Will send it" in every dictation. A token that is itself a
        // legitimate word is left alone; put it in overrides to force it.
        if let canon = canonical[lower] {
            if token == canon { return token }
            if isRealWord(token) { return token }
            return canon
        }

        // Guards: long enough, and not a legitimate word.
        guard token.count >= 4 else { return token }
        if isRealWord(token) { return token }

        // Eligible only if within a tight edit distance of EXACTLY ONE glossary term.
        var matches: [String] = []
        for t in terms {
            let d = LevenshteinDistance.distance(lower, t)
            let maxLen = max(lower.count, t.count)
            // 1–2 edits, and < ~1/3 of the longer length — so 4-char names allow
            // 1 edit, 8-char names allow 2. Tight enough to avoid coincidences.
            if d >= 1, d <= 2, Double(d) / Double(maxLen) < 0.34 {
                matches.append(t)
            }
        }
        guard matches.count == 1, let canon = canonical[matches[0]] else { return token }
        return canon
    }
}
