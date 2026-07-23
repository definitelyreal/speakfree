// Claude · 2026-07-22 · Session: vocab-boost-eval worktree loop
//
// Batch-anchored custom-vocabulary boosting with a real-word guard.
//
// WHY THIS EXISTS (2026-07-03 postmortem): the first vocab-boost attempt ran the
// whole utterance through FluidAudio's SlidingWindowAsrManager with vocabulary
// biasing and shipped whatever came back. Its first real-voice test produced five
// word-substitutions ("Viktor" invented, spoken "colon" mangled, "new line" x2,
// "Parakeet") because (a) the sliding-window decode itself diverges from the batch
// decode at window seams (~2.5% of words, measured 2026-07-22), so errors appeared
// even where no vocabulary term was involved, and (b) the rescorer was allowed to
// replace common English words and spoken-punctuation commands.
//
// This component fixes both structurally:
//   1. BATCH-ANCHORED: the transcript is the production batch TDT result. The CTC
//      keyword machinery (CtcKeywordSpotter + VocabularyRescorer — public FluidAudio
//      API) runs ON TOP of it using the batch result's token timings. The output is
//      byte-identical to production everywhere except spans the rescorer explicitly
//      replaced AND the guard accepted — window-seam divergence is impossible by
//      construction, and untouched text (including whitespace) is preserved verbatim.
//   2. GUARDED: every proposed replacement passes a veto chain before it is applied
//      (spoken-punctuation exemption, acronym guard, digit guard, curated-alias
//      override, length-loss/gain bounds, real-word guard, unmatched-region veto).
//      Vetoed spans revert to the batch text.
//
// Hardened 2026-07-22 after a 39-finding Codex adversarial review; the accepted
// findings are marked [CXn] below.

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

    /// Spoken-punctuation command words. Terms containing these are never allowed INTO the
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
        // [CX22] common command variants ("full stop", "open paren", "close quote", …)
        "full", "stop", "open", "close", "return", "enter",
    ]

    /// Parse `vocabulary.txt` (one term per line, `#` comments — same format the Whisper
    /// glossary prompt uses). Terms containing punctuation command words are excluded.
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
            // Strip inline comments ("Gaubert # brain") and whitespace. NOTE: must cut at
            // the first '#' (not split-and-take-first — Swift's split drops LEADING
            // separators, which turned full-line comments into multi-word vocab terms;
            // caught by testTermLoadingSkipsPunctuationAndComments).
            let body = line.firstIndex(of: "#").map { String(line[line.startIndex..<$0]) }
                ?? String(line)
            let term = body.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            // [CX36] dedupe on the same normalization runtime matching uses.
            let normKey = normalizePhrase(term)
            guard !normKey.isEmpty, !seen.contains(normKey) else { continue }
            // [CX35] check every word of a multi-word term against the punctuation set.
            let words = normKey.split(separator: " ").map(String.init)
            guard !words.contains(where: { punctuationCommandWords.contains($0) }) else { continue }
            // Skip filename-ish entries (Claude.md / CLAUDE.md) — the rescorer's normalizer
            // strips the dot, and "claudemd" is not a spoken token worth biasing toward.
            guard !key.contains(".") else { continue }
            seen.insert(normKey)
            var aliases = curatedAliases[key] ?? []
            // Possessive terms ("Zander's") inherit the base term's curated aliases in
            // possessive form ("xander" → "xander's"), so possessive garbles stay
            // alias-covered — NSSpellChecker knows many first names, and without the
            // alias the real-word guard vetoes "Xander's" → "Zander's".
            if key.hasSuffix("'s") || key.hasSuffix("\u{2019}s") {
                let base = String(key.dropLast(2))
                for a in curatedAliases[base] ?? [] { aliases.append(a + "'s") }
            }
            specs.append(TermSpec(text: term, weight: 1.5, aliases: aliases))
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
            let words = normalizePhrase(t.text).split(separator: " ").map(String.init)
            guard !words.contains(where: { punctuationCommandWords.contains($0) }) else { continue }
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
        /// True when the eligibility prefilter proved the CTC pass unnecessary.
        public var prefilterSkipped: Bool = false
    }

    // MARK: - Normalization ([CX23] NFC first, then casefold + strip)

    /// Lowercase and strip everything but letters/digits, after canonical (NFC)
    /// composition so composed/decomposed accents normalize identically.
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func normalizePhrase(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Trim leading/trailing non-alphanumerics but KEEP internal apostrophes and hyphens,
    /// so "don't," → "don't" and "day-to-day." → "day-to-day". [CX18]
    static func trimPunctuation(_ s: String) -> String {
        let core = s.precomposedStringWithCanonicalMapping
        guard let first = core.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = core.lastIndex(where: { $0.isLetter || $0.isNumber })
        else { return "" }
        return String(core[first...last])
    }

    // MARK: - Word classification

    /// English lexicon fallback for the real-word guard. /usr/share/dict/words (web2),
    /// lowercased. A static wordlist avoids NSSpellChecker's AppKit entanglements on
    /// platforms where it is unavailable.
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

    private static func inDictionary(_ w: String) -> Bool {
        guard !w.isEmpty else { return false }
        // Primary: the system spell checker — the same guard production's
        // GlossaryCorrector uses (proven per-dictation in FinalizePipeline). It knows
        // modern compounds web2 lacks ('timeline', 'email', 'workflow', …).
        if GlossaryCorrector.systemIsRealWord(w) { return true }
        if englishWords.contains(w) { return true }
        // Trailing inflections (web2 lists lemmas).
        if w.hasSuffix("s"), englishWords.contains(String(w.dropLast())) { return true }
        if w.hasSuffix("es"), englishWords.contains(String(w.dropLast(2))) { return true }
        if w.hasSuffix("ed"), englishWords.contains(String(w.dropLast(2))) { return true }
        if w.hasSuffix("ing"), englishWords.contains(String(w.dropLast(3))) { return true }
        return false
    }

    /// Is this RAW transcript token a real English word the boost must not touch?
    /// Checks the apostrophe/hyphen-preserving core ("don't", "day-to-day") AND the
    /// fully stripped form, plus hyphen components. [CX18]
    static func isRealEnglishWord(_ raw: String) -> Bool {
        let core = trimPunctuation(raw)
        guard !core.isEmpty else { return false }
        if inDictionary(core.lowercased()) { return true }
        let stripped = normalize(core)
        if stripped != core.lowercased(), inDictionary(stripped) { return true }
        if core.contains("-") {
            let parts = core.split(separator: "-").map(String.init)
            if !parts.isEmpty, parts.allSatisfy({ inDictionary($0.lowercased()) }) { return true }
        }
        return false
    }

    /// ALL-CAPS/mixed-case acronym-ish token (AAF, LLMs, eBPF, iOS): ≥2 uppercase
    /// letters. Recognized acronyms are decoder output, not garbles. [CX21]
    static func isAcronymish(_ raw: String) -> Bool {
        let letters = raw.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let uppers = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        return letters.count >= 2 && uppers.count >= 2
    }

    static func containsDigit(_ raw: String) -> Bool {
        raw.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    // MARK: - The guard chain

    /// Apply the guard chain to one proposed replacement.
    /// Returns nil when accepted, else the veto reason.
    static func vetoReason(
        originalSpan: [String],
        term: CustomVocabularyTerm
    ) -> String? {
        let normWords = originalSpan.map { normalize($0) }.filter { !$0.isEmpty }
        guard !normWords.isEmpty else { return "empty-span" }
        let phrase = normWords.joined(separator: " ")
        let termPhrase = normalizePhrase(term.text)
        let spanEqualsTerm = phrase == termPhrase

        // 1. Spoken-punctuation exemption — unconditional. A span containing a punctuation
        //    command word carries formatting intent for TextPipeline; rescoring it away
        //    breaks the dictation ("colon", "new line" failures of 2026-07-03).
        for w in normWords where punctuationCommandWords.contains(w) {
            return "punctuation-command-word '\(w)'"
        }

        // 2. Case/punctuation-fix exemption — the span IS the term modulo case and
        //    punctuation ("ec-2" → EC2, "rohrlich" → Rohrlich). Only presentation
        //    changes; content is identical, so the remaining guards don't apply.
        if spanEqualsTerm { return nil }

        // 3. Acronym guard — a span the batch decoder emitted with ≥2 uppercase letters
        //    (AAF, ADR, LLMs, eBPF) is a recognized acronym, not a garble; never rescore
        //    it into a different term. (it2 false positive: 'AAF' → 'Naam' while
        //    dictating about AAF audio files.) [CX21]
        if originalSpan.contains(where: { isAcronymish($0) }), !spanEqualsTerm {
            return "acronym span '\(originalSpan.joined(separator: " "))'"
        }

        // 3. Digit guard — dates, amounts, versions, model numbers are never garbled
        //    names. Exempt only a case/punctuation variant of the term itself
        //    ("ec-2" → EC2). [CX19]
        if originalSpan.contains(where: { containsDigit($0) }), !spanEqualsTerm {
            return "digit span '\(originalSpan.joined(separator: " "))'"
        }

        // 5. Curated-alias override — Michael explicitly listed this garble for this term
        //    (e.g. "marina" → Maryna), so the remaining guards step aside. Aliases also
        //    match their possessive/plural form ("xander" covers "Xander's" → "xanders"
        //    after normalization): NSSpellChecker knows many first names, so the
        //    real-word guard below would otherwise veto possessive garbles the alias
        //    was explicitly curated to fix.
        var aliasSet = Set((term.aliases ?? []).map { normalizePhrase($0) })
        for a in aliasSet where !a.hasSuffix("s") { aliasSet.insert(a + "s") }
        if aliasSet.contains(phrase) { return nil }

        // 5. Length bounds — the replacement must not swallow a substantially longer
        //    spoken span (it2 false positive: 'Xanderbot' → 'Zander' dropped "bot"),
        //    nor balloon a short one into a much longer term. [CX15]
        let compactOriginal = normWords.joined()
        let compactTerm = normalize(term.text)
        if compactOriginal.count - compactTerm.count >= 3 {
            return "length-loss '\(originalSpan.joined(separator: " "))' → '\(term.text)'"
        }
        if compactTerm.count - compactOriginal.count >= 6 {
            return "length-gain '\(originalSpan.joined(separator: " "))' → '\(term.text)'"
        }

        // 6. Real-word guard — never rescore a span containing ANY common English word
        //    into a vocab term on acoustic evidence alone ("Viktor" failure of
        //    2026-07-03). ANY (not ALL): a multi-word span must not lose its real words
        //    to a name ("to rorlik" must not become "Rohrlich" wholesale — and mixed
        //    spans like that are exactly where alignment errors live). Multi-word garble
        //    compounds go through curated aliases ("pebble bed" → Pebblebed). [CX14]
        if let real = originalSpan.first(where: { isRealEnglishWord($0) }) {
            return "real-word '\(real)' in span '\(originalSpan.joined(separator: " "))'"
        }

        return nil
    }

    // MARK: - Prefilter

    /// Cheap prefilter: can the guard chain possibly ACCEPT anything in this transcript?
    ///
    /// Mirrors the guard's own predicates on the SAME raw-token inputs [CX37]: a token is
    /// "eligible" iff the guard could pass it (not punctuation, not acronym-ish, no digits,
    /// not a real English word) or it is a case/punct variant of a term, or a curated alias
    /// phrase occurs. If nothing is eligible, the CTC pass cannot change the final text.
    /// Guard-side protection is strictly wider (span-level ANY-real veto), so skipping is
    /// conservative in the safe direction.
    public static func hasEligibleToken(
        batchText: String, vocabulary: CustomVocabularyContext
    ) -> Bool {
        let rawTokens = batchText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rawTokens.isEmpty else { return false }
        let termSet = Set(vocabulary.terms.map { normalizePhrase($0.text) })
        var normTokens: [String] = []
        normTokens.reserveCapacity(rawTokens.count)
        var eligible = false
        for raw in rawTokens {
            let nt = normalize(raw)
            if !nt.isEmpty { normTokens.append(nt) }
            guard !eligible, !nt.isEmpty else { continue }
            if punctuationCommandWords.contains(nt) { continue }
            if termSet.contains(nt) { eligible = true; continue }  // case/punct fix path
            if isAcronymish(raw) { continue }
            if containsDigit(raw) { continue }
            if !isRealEnglishWord(raw) { eligible = true }
        }
        if eligible { return true }
        // All tokens are protected — only a curated alias phrase can still be accepted.
        let joined = " " + normTokens.joined(separator: " ") + " "
        for term in vocabulary.terms {
            for alias in term.aliases ?? [] {
                let a = normalizePhrase(alias)
                if !a.isEmpty, joined.contains(" " + a + " ") { return true }
            }
        }
        return false
    }

    // MARK: - Boost

    /// Transcripts beyond this many words skip the boost (quadratic alignment bound). [CX31]
    static let maxBoostWords = 800

    /// Run the CTC rescorer over a finished batch transcription, then veto/apply.
    ///
    /// - Parameters:
    ///   - batchText: the production batch TDT transcript (anchor; returned verbatim on any doubt)
    ///   - tokenTimings: token timings from the same batch ASRResult
    ///   - audio: the SAME audio buffer the batch decode saw (including its silence pad)
    ///   - spotter/rescorer/vocabulary: prebuilt CTC machinery (reused across utterances;
    ///     callers serialize — ParakeetEngine's Core actor does)
    public static func boost(
        batchText: String,
        tokenTimings: [TokenTiming],
        audio: [Float],
        spotter: CtcKeywordSpotter,
        rescorer: VocabularyRescorer,
        vocabulary: CustomVocabularyContext,
        usePrefilter: Bool = true
    ) async throws -> Output {
        guard !batchText.isEmpty, !tokenTimings.isEmpty, !vocabulary.terms.isEmpty else {
            return Output(text: batchText, decisions: [], rescoredRaw: batchText)
        }

        // Skip the CTC forward pass entirely when nothing in the transcript could be
        // accepted anyway (most dictations contain no garbled names).
        if usePrefilter, !hasEligibleToken(batchText: batchText, vocabulary: vocabulary) {
            return Output(text: batchText, decisions: [], rescoredRaw: batchText,
                          prefilterSkipped: true)
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
        // [CX13] tolerate duplicate keys instead of trapping.
        let termByText = Dictionary(
            vocabulary.terms.map { ($0.textLowercased, $0) },
            uniquingKeysWith: { a, _ in a })
        let proposals = rescored.replacements.compactMap { r -> ProposedReplacement? in
            guard let rep = r.replacementWord else { return nil }
            return ProposedReplacement(
                original: r.originalWord, replacement: rep,
                score: r.replacementScore, reason: r.reason)
        }
        let (finalText, decisions) = spliceAcceptedReplacements(
            batchText: batchText,
            rescoredText: rescored.text,
            replacements: proposals,
            termByText: termByText)

        return Output(text: finalText, decisions: decisions, rescoredRaw: rescored.text)
    }

    // MARK: - Alignment + splicing

    /// Rescorer-agnostic view of one applied replacement (decoupled from
    /// VocabularyRescorer.RescoringResult, whose memberwise init is internal to
    /// FluidAudio — this keeps the splicer unit-testable).
    struct ProposedReplacement {
        let original: String
        let replacement: String
        let score: Float?
        let reason: String
    }

    struct DiffRegion {
        let originalRange: Range<Int>
        let rescoredRange: Range<Int>
    }

    /// LCS word alignment: returns mismatched regions between the two word arrays.
    static func diffRegions(_ a: [String], _ b: [String]) -> [DiffRegion] {
        let n = a.count, m = b.count
        // DP table for LCS lengths. Transcripts are short (a dictation, not a document);
        // callers bound input size via maxBoostWords.
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

    /// Leading punctuation of `word` (quotes/parens) to re-attach before a replacement. [CX3]
    static func leadingPunctuation(of word: String) -> String {
        var out = ""
        for ch in word {
            if ch.isLetter || ch.isNumber { break }
            out.append(ch)
        }
        return out
    }

    /// Whitespace-preserving tokenization of `text`: words plus the exact separator
    /// substrings around them (gaps.count == words.count + 1), so reconstruction of
    /// untouched regions is byte-identical. [CX1] [CX2]
    static func tokenizePreservingGaps(_ text: String) -> (words: [String], gaps: [String]) {
        var words: [String] = []
        var gaps: [String] = [""]
        var inWord = false
        var current = ""
        for ch in text {
            if ch.isWhitespace {
                if inWord {
                    words.append(current); current = ""; inWord = false
                    gaps.append(String(ch))
                } else {
                    gaps[gaps.count - 1].append(ch)
                }
            } else {
                inWord = true
                current.append(ch)
            }
        }
        if inWord {
            words.append(current)
            gaps.append("")
        }
        // Invariant: gaps.count == words.count + 1, and
        // text == gaps[0] + words[0] + gaps[1] + … + words[n-1] + gaps[n].
        return (words, gaps)
    }

    static func spliceAcceptedReplacements(
        batchText: String,
        rescoredText: String,
        replacements: [ProposedReplacement],
        termByText: [String: CustomVocabularyTerm]
    ) -> (String, [Decision]) {
        let (originalWords, gaps) = tokenizePreservingGaps(batchText)
        let rescoredWords = rescoredText.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        // [CX31] bail out on very long transcripts (quadratic alignment).
        guard originalWords.count <= maxBoostWords, rescoredWords.count <= maxBoostWords else {
            return (batchText, [Decision(
                original: "", replacement: "", similarity: nil, accepted: false,
                reason: "size-cap: \(originalWords.count)/\(rescoredWords.count) words")])
        }

        let regions = diffRegions(originalWords, rescoredWords)

        // Index the rescorer's applied replacements by (normalized original, normalized new).
        var replacementPool: [(key: String, r: ProposedReplacement)] =
            replacements.map { r in
                ("\(normalizePhrase(r.original))→\(normalizePhrase(r.replacement))", r)
            }

        var decisions: [Decision] = []
        // Accepted splices by original-word range.
        var accepted: [(range: Range<Int>, text: String)] = []

        for region in regions {
            let origSpan = Array(originalWords[region.originalRange])
            let newSpan = Array(rescoredWords[region.rescoredRange])
            let key = "\(normalizePhrase(origSpan.joined(separator: " ")))→\(normalizePhrase(newSpan.joined(separator: " ")))"

            // Find the rescorer replacement this region corresponds to.
            guard let poolIdx = replacementPool.firstIndex(where: { $0.key == key }) else {
                // Region not explained by an explicit replacement (reconstruction artifact,
                // merged adjacent replacements, …) → keep the batch words. Anchor property:
                // nothing the rescorer didn't explicitly claim may change.
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
            let termKey = normalizePhrase(replacement.replacement)
            let term = termByText[replacement.replacement.lowercased()]
                ?? termByText.values.first { normalizePhrase($0.text) == termKey }

            let veto: String?
            if let term {
                veto = vetoReason(originalSpan: origSpan, term: term)
            } else {
                veto = "replacement is not a vocabulary term"
            }

            if let veto {
                decisions.append(Decision(
                    original: origSpan.joined(separator: " "),
                    replacement: replacement.replacement,
                    similarity: replacement.score, accepted: false, reason: veto))
            } else {
                // Accept: canonical term casing; re-attach the span's leading and trailing
                // punctuation. [CX3]
                var text = replacement.replacement
                if let last = origSpan.last {
                    let punct = trailingPunctuation(of: last)
                    if !punct.isEmpty, !text.hasSuffix(punct) { text += punct }
                }
                if let first = origSpan.first {
                    let punct = leadingPunctuation(of: first)
                    if !punct.isEmpty, !text.hasPrefix(punct) { text = punct + text }
                }
                accepted.append((region.originalRange, text))
                decisions.append(Decision(
                    original: origSpan.joined(separator: " "),
                    replacement: replacement.replacement,
                    similarity: replacement.score, accepted: true,
                    reason: replacement.reason))
            }
        }

        // Nothing accepted → the batch text passes through byte-identical. [CX1]
        guard !accepted.isEmpty else { return (batchText, decisions) }

        // Reconstruct from the ORIGINAL tokens + gaps, splicing accepted spans in place.
        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out = ""
        var i = 0
        var spliceIdx = 0
        out += gaps[0]
        while i < originalWords.count {
            if spliceIdx < accepted.count, accepted[spliceIdx].range.lowerBound == i {
                let splice = accepted[spliceIdx]
                out += splice.text
                i = splice.range.upperBound
                out += gaps[i]  // gap following the last consumed word
                spliceIdx += 1
            } else {
                out += originalWords[i]
                i += 1
                out += gaps[i]
            }
        }
        return (out, decisions)
    }
}
