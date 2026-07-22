// Claude · 2026-07-22 · Session: vocab-boost-eval worktree loop
//
// Batch-anchored custom-vocabulary boosting with a real-word guard.
//
// WHY THIS EXISTS (2026-07-03 postmortem): the first vocab-boost attempt ran the
// whole utterance through FluidAudio's SlidingWindowAsrManager with vocabulary
// biasing and shipped whatever came back. Its first real-voice test produced five
// word-substitutions ("Viktor" invented, spoken "colon" mangled, "new line" x2,
// "Parakeet") because (a) the sliding-window decode itself diverges from the batch
// decode at window seams, so errors appeared even where no vocabulary term was
// involved, and (b) the rescorer was allowed to replace common English words and
// spoken-punctuation commands.
//
// This component fixes both structurally:
//   1. BATCH-ANCHORED: the transcript is the production batch TDT result. The CTC
//      keyword machinery (CtcKeywordSpotter + VocabularyRescorer — public FluidAudio
//      API) runs ON TOP of it using the batch result's token timings. The output is
//      IDENTICAL to production everywhere except spans the rescorer explicitly
//      replaced — window-seam divergence is impossible by construction.
//   2. GUARDED: every proposed replacement passes a veto chain before it is applied
//      (spoken-punctuation exemption, real-word guard with curated-alias override,
//      unmatched-region veto). Vetoed spans revert to the batch text verbatim.
//
// The final text is reconstructed by word-aligning the batch transcript against the
// rescored transcript (LCS) and splicing in only the ACCEPTED replacement spans, so
// formatting/punctuation of untouched text is preserved bit-for-bit.

import Foundation
import FluidAudio

public enum VocabularyBoost {

    // MARK: - Term loading

    /// A vocabulary term parsed from vocabulary.txt (optionally enriched with curated aliases).
    public struct TermSpec: Sendable {
        public let text: String
        public let weight: Float
        public let aliases: [String]

        public init(text: String, weight: Float = 1.5, aliases: [String] = []) {
            self.text = text
            self.weight = weight
            self.aliases = aliases
        }
    }

    /// Spoken-punctuation command words. Terms matching these are never allowed INTO the
    /// vocabulary (punctuation garbles are handled downstream by TextPipeline/overrides.json),
    /// and transcript spans containing them are never allowed to be rescored away.
    public static let punctuationCommandWords: Set<String> = [
        "comma", "period", "colon", "semicolon", "semi",
        "question", "exclamation", "mark", "point",
        "new", "line", "paragraph", "newline",
        "quote", "unquote", "quotes", "apostrophe",
        "dash", "hyphen", "ellipsis", "dot",
        "parenthesis", "paren", "parens", "bracket", "brace",
        "slash", "backslash", "tab", "space",
    ]

    /// Parse `vocabulary.txt` (one term per line, `#` comments — same format the Whisper
    /// glossary prompt uses). Punctuation command words are excluded defensively.
    /// `curatedAliases` maps lowercased canonical term → aliases (from Michael's curated
    /// custom-vocabulary.json, e.g. "rorlik" → Rohrlich).
    public static func loadTermSpecs(
        vocabularyFile: URL,
        curatedAliases: [String: [String]] = [:]
    ) -> [TermSpec] {
        guard let raw = try? String(contentsOf: vocabularyFile, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var specs: [TermSpec] = []
        for line in raw.split(separator: "\n") {
            // Strip inline comments ("Gaubert # brain") and whitespace.
            let body = line.split(separator: "#").first.map(String.init) ?? ""
            let term = body.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            guard !punctuationCommandWords.contains(key) else { continue }
            // Skip filename-ish entries (Claude.md / CLAUDE.md) — the rescorer's normalizer
            // strips the dot, and "claudemd" is not a spoken token worth biasing toward.
            guard !key.contains(".") else { continue }
            seen.insert(key)
            specs.append(TermSpec(text: term, weight: 1.5, aliases: curatedAliases[key] ?? []))
        }
        return specs
    }

    /// Read curated aliases out of a FluidAudio-format custom-vocabulary.json (READ-ONLY).
    /// Punctuation command terms are dropped wholesale.
    public static func loadCuratedAliases(from url: URL) -> [String: [String]] {
        struct FileTerm: Decodable { let text: String; let aliases: [String]? }
        struct File: Decodable { let terms: [FileTerm] }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        var out: [String: [String]] = [:]
        for t in file.terms {
            let key = t.text.lowercased()
            guard !punctuationCommandWords.contains(key) else { continue }
            if let aliases = t.aliases, !aliases.isEmpty { out[key] = aliases }
        }
        return out
    }

    /// Build a CTC-tokenized CustomVocabularyContext from term specs (mirrors the
    /// tokenization fix from 130f970 — `.load()` leaves ctcTokenIds nil and nothing is
    /// ever spotted without it).
    public static func makeContext(
        specs: [TermSpec],
        tokenizer: CtcTokenizer,
        minTermLength: Int = 3
    ) -> CustomVocabularyContext {
        let terms = specs.compactMap { spec -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(spec.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: spec.text, weight: spec.weight,
                aliases: spec.aliases.isEmpty ? nil : spec.aliases,
                tokenIds: nil, ctcTokenIds: ids)
        }
        return CustomVocabularyContext(terms: terms, minTermLength: minTermLength)
    }

    // MARK: - Decisions

    /// One proposed replacement and what the guard did with it.
    public struct Decision: Codable, Sendable {
        public let original: String
        public let replacement: String
        public let similarity: Float?
        public let accepted: Bool
        /// Rescorer's acoustic-evidence reason when accepted; veto reason otherwise.
        public let reason: String
    }

    public struct Output: Sendable {
        /// Final guarded text (== batch text when nothing was accepted).
        public let text: String
        public let decisions: [Decision]
        /// The rescorer's raw (unguarded) reconstruction, for diagnostics only.
        public let rescoredRaw: String
    }

    // MARK: - The guard + selective application

    /// English lexicon for the real-word guard. /usr/share/dict/words (web2), lowercased.
    /// A static wordlist avoids NSSpellChecker's main-thread entanglements.
    private static let englishWords: Set<String> = {
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"),
                                    encoding: .utf8) else { return [] }
        var set = Set<String>()
        set.reserveCapacity(240_000)
        for line in raw.split(separator: "\n") {
            set.insert(line.lowercased())
        }
        return set
    }()

    static func isRealEnglishWord(_ word: String) -> Bool {
        let w = word.lowercased()
        guard !w.isEmpty else { return false }
        // Primary: the system spell checker — the same guard production's
        // GlossaryCorrector uses (proven off-main in FinalizePipeline). It knows
        // modern compounds web2 lacks: iteration 1 let 'timeline' → 'Trimble'
        // through because /usr/share/dict/words (1934 web2) has no 'timeline'.
        if GlossaryCorrector.systemIsRealWord(w) { return true }
        if englishWords.contains(w) { return true }
        // Trailing-s plurals/possessive-stripped forms (web2 lists lemmas, not inflections).
        if w.hasSuffix("s"), englishWords.contains(String(w.dropLast())) { return true }
        if w.hasSuffix("es"), englishWords.contains(String(w.dropLast(2))) { return true }
        if w.hasSuffix("ed"), englishWords.contains(String(w.dropLast(2))) { return true }
        if w.hasSuffix("ing"), englishWords.contains(String(w.dropLast(3))) { return true }
        return false
    }

    /// Lowercase and strip everything but letters/digits (mirrors the rescorer's normalizer
    /// closely enough for span matching).
    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func normalizePhrase(_ s: String) -> String {
        s.split(separator: " ").map { normalize(String($0)) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Apply the guard chain to one proposed replacement.
    /// Returns nil when accepted, else the veto reason.
    static func vetoReason(
        originalSpan: [String],
        term: CustomVocabularyTerm
    ) -> String? {
        let normWords = originalSpan.map { normalize($0) }.filter { !$0.isEmpty }
        guard !normWords.isEmpty else { return "empty-span" }

        // 1. Spoken-punctuation exemption — unconditional. A span containing a punctuation
        //    command word carries formatting intent for TextPipeline; rescoring it away
        //    breaks the dictation ("colon", "new line" failures of 2026-07-03).
        for w in normWords where punctuationCommandWords.contains(w) {
            return "punctuation-command-word '\(w)'"
        }

        // 2. Curated-alias override — Michael explicitly listed this garble for this term
        //    (e.g. "marina" → Maryna), so the real-word guard steps aside.
        let phrase = normWords.joined(separator: " ")
        let aliasSet = Set((term.aliases ?? []).map { normalizePhrase($0) })
        if aliasSet.contains(phrase) { return nil }

        // 3. Real-word guard — never rescore a span of common English words into a vocab
        //    term on acoustic evidence alone ("Viktor" failure of 2026-07-03: a real word
        //    was replaced by a name). Non-word garbles (e.g. "rorlik", "pebblebed") pass.
        if normWords.allSatisfy({ isRealEnglishWord($0) }) {
            return "real-word span '\(originalSpan.joined(separator: " "))'"
        }

        return nil
    }

    /// Run the CTC rescorer over a finished batch transcription, then veto/apply.
    ///
    /// - Parameters:
    ///   - batchText: the production batch TDT transcript (anchor; returned verbatim on any doubt)
    ///   - tokenTimings: token timings from the same batch ASRResult
    ///   - audio: the SAME audio buffer the batch decode saw (including its silence pad)
    ///   - spotter/rescorer/vocabulary: prebuilt CTC machinery (reused across utterances)
    public static func boost(
        batchText: String,
        tokenTimings: [TokenTiming],
        audio: [Float],
        spotter: CtcKeywordSpotter,
        rescorer: VocabularyRescorer,
        vocabulary: CustomVocabularyContext
    ) async throws -> Output {
        guard !batchText.isEmpty, !tokenTimings.isEmpty, !vocabulary.terms.isEmpty else {
            return Output(text: batchText, decisions: [], rescoredRaw: batchText)
        }

        // CTC forward pass (chunked internally for >15s audio).
        let spot = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audio, customVocabulary: vocabulary, minScore: nil)
        guard !spot.logProbs.isEmpty else {
            return Output(text: batchText, decisions: [], rescoredRaw: batchText)
        }

        let rescored = rescorer.ctcTokenRescore(
            transcript: batchText,
            tokenTimings: tokenTimings,
            logProbs: spot.logProbs,
            frameDuration: spot.frameDuration)

        guard rescored.wasModified else {
            return Output(text: batchText, decisions: [], rescoredRaw: rescored.text)
        }

        // Word-align batch text vs rescored text; only regions that correspond to an
        // explicit rescorer replacement may change, and only if the guard accepts them.
        let termByText = Dictionary(uniqueKeysWithValues:
            vocabulary.terms.map { ($0.textLowercased, $0) }
        )
        let (finalText, decisions) = spliceAcceptedReplacements(
            batchText: batchText,
            rescoredText: rescored.text,
            replacements: rescored.replacements,
            termByText: termByText)

        return Output(text: finalText, decisions: decisions, rescoredRaw: rescored.text)
    }

    // MARK: - Alignment + splicing

    struct DiffRegion {
        let originalRange: Range<Int>
        let rescoredRange: Range<Int>
    }

    /// LCS word alignment: returns mismatched regions between the two word arrays.
    static func diffRegions(_ a: [String], _ b: [String]) -> [DiffRegion] {
        let n = a.count, m = b.count
        // DP table for LCS lengths. Transcripts are short (a dictation, not a document).
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var regions: [DiffRegion] = []
        var i = 0, j = 0
        var regionStartA = -1, regionStartB = -1
        func closeRegion(_ endA: Int, _ endB: Int) {
            if regionStartA >= 0 {
                regions.append(DiffRegion(originalRange: regionStartA..<endA,
                                          rescoredRange: regionStartB..<endB))
                regionStartA = -1; regionStartB = -1
            }
        }
        while i < n && j < m {
            if a[i] == b[j] {
                closeRegion(i, j)
                i += 1; j += 1
            } else {
                if regionStartA < 0 { regionStartA = i; regionStartB = j }
                if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
            }
        }
        if i < n || j < m {
            if regionStartA < 0 { regionStartA = i; regionStartB = j }
            regions.append(DiffRegion(originalRange: regionStartA..<n, rescoredRange: regionStartB..<m))
        } else {
            closeRegion(i, j)
        }
        return regions
    }

    /// Trailing punctuation of `word` (chars like .,!?;:…) to re-attach after a replacement.
    static func trailingPunctuation(of word: String) -> String {
        var out = ""
        for ch in word.reversed() {
            if ch.isLetter || ch.isNumber { break }
            out.insert(ch, at: out.startIndex)
        }
        return out
    }

    static func spliceAcceptedReplacements(
        batchText: String,
        rescoredText: String,
        replacements: [VocabularyRescorer.RescoringResult],
        termByText: [String: CustomVocabularyTerm]
    ) -> (String, [Decision]) {
        let originalWords = batchText.split(separator: " ").map(String.init)
        let rescoredWords = rescoredText.split(separator: " ").map(String.init)
        let regions = diffRegions(originalWords, rescoredWords)

        // Index the rescorer's applied replacements by (normalized original, normalized new).
        var replacementPool: [(key: String, r: VocabularyRescorer.RescoringResult)] =
            replacements.compactMap { r in
                guard let rep = r.replacementWord else { return nil }
                return ("\(normalizePhrase(r.originalWord))→\(normalizePhrase(rep))", r)
            }

        var decisions: [Decision] = []
        var out: [String] = []
        var cursor = 0

        for region in regions {
            // Copy untouched original words up to the region.
            out.append(contentsOf: originalWords[cursor..<region.originalRange.lowerBound])
            cursor = region.originalRange.upperBound

            let origSpan = Array(originalWords[region.originalRange])
            let newSpan = Array(rescoredWords[region.rescoredRange])
            let key = "\(normalizePhrase(origSpan.joined(separator: " ")))→\(normalizePhrase(newSpan.joined(separator: " ")))"

            // Find the rescorer replacement this region corresponds to.
            guard let poolIdx = replacementPool.firstIndex(where: { $0.key == key }) else {
                // Region not explained by an explicit replacement (reconstruction artifact,
                // partial overlap, …) → keep the batch words. Anchor property: nothing the
                // rescorer didn't explicitly claim may change.
                out.append(contentsOf: origSpan)
                if !origSpan.isEmpty || !newSpan.isEmpty {
                    decisions.append(Decision(
                        original: origSpan.joined(separator: " "),
                        replacement: newSpan.joined(separator: " "),
                        similarity: nil, accepted: false,
                        reason: "unmatched-diff-region"))
                }
                continue
            }
            let replacement = replacementPool.remove(at: poolIdx).r
            let termKey = normalizePhrase(replacement.replacementWord ?? "")
            let term = termByText[replacement.replacementWord?.lowercased() ?? ""]
                ?? termByText.values.first { normalizePhrase($0.text) == termKey }

            let veto: String?
            if let term {
                veto = vetoReason(originalSpan: origSpan, term: term)
            } else {
                veto = "replacement is not a vocabulary term"
            }

            if let veto {
                out.append(contentsOf: origSpan)
                decisions.append(Decision(
                    original: origSpan.joined(separator: " "),
                    replacement: replacement.replacementWord ?? "",
                    similarity: replacement.replacementScore, accepted: false, reason: veto))
            } else {
                // Accept: canonical term casing, re-attach trailing punctuation of the span.
                var text = replacement.replacementWord ?? newSpan.joined(separator: " ")
                if let last = origSpan.last {
                    let punct = trailingPunctuation(of: last)
                    if !punct.isEmpty, !text.hasSuffix(punct) { text += punct }
                }
                out.append(text)
                decisions.append(Decision(
                    original: origSpan.joined(separator: " "),
                    replacement: replacement.replacementWord ?? "",
                    similarity: replacement.replacementScore, accepted: true,
                    reason: replacement.reason))
            }
        }
        out.append(contentsOf: originalWords[cursor...])

        return (out.joined(separator: " "), decisions)
    }
}
