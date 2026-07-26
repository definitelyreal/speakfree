import Foundation

/// Pure text pipeline: prompt-assembly hints -> process() -> applyStyle().
/// Same code the app calls at finalizeRecording AND tests call. The extraction
/// is what prevents the inline-closure drift that shipped the comma feedback loop.
public enum TextPipeline {
    public struct Input {
        public let raw: String
        public let cursorContextText: String?
        public let screenContextText: String?
        public let punctuationMode: PunctuationMode
        public let styleMode: TextPostProcessor.StyleMode
        public let glossaryWords: String?
        /// Curated exact garble→correct overrides (lowercased key → replacement).
        public let overrides: [String: String]
        /// Recording length. Chunk-seam artifacts (duplicate recapitalized words) only
        /// exist when FluidAudio actually chunked (>~14.9s), so the seam-dedup pass is
        /// skipped for short dictations — where "mark Mark" is far more likely a real
        /// verb+name pair than a seam dup (adversarial review 2026-07-15, round 2).
        /// nil = unknown duration; dedup stays enabled.
        public let audioDurationSeconds: Double?

        /// `raw` defaults to `""` so callers can construct a context-only Input for prompt
        /// assembly without needing a dummy empty-string placeholder.
        public init(raw: String = "",
                    punctuationMode: PunctuationMode,
                    cursorContextText: String? = nil,
                    screenContextText: String? = nil,
                    styleMode: TextPostProcessor.StyleMode = .none,
                    glossaryWords: String? = nil,
                    overrides: [String: String] = [:],
                    audioDurationSeconds: Double? = nil) {
            self.raw = raw
            self.cursorContextText = cursorContextText
            self.screenContextText = screenContextText
            self.punctuationMode = punctuationMode
            self.styleMode = styleMode
            self.glossaryWords = glossaryWords
            self.overrides = overrides
            self.audioDurationSeconds = audioDurationSeconds
        }
    }

    public struct Result {
        public let promptHints: String?    // what was sent to Whisper's prompt
        public let processedText: String   // after TextPostProcessor.process; exposed for test observation — production reads finalText
        public let finalText: String       // after applyStyle
    }

    /// Maximum byte length of the assembled prompt string sent to Whisper.
    ///
    /// Whisper's `initial_prompt` is limited to 224 tokens. UTF-8 English averages ~3.5
    /// chars per token, so 224 × 3.5 ≈ 784 chars. We cap at 800 to match the whisper.cpp
    /// source comment, erring slightly above rather than cutting real content mid-sentence.
    /// Priority order (most important last, closest to end of prompt): cursor context >
    /// glossary > screen context > instruction line. Truncation drops earlier sections first.
    /// Glossary outranks screen context because user-curated vocabulary terms are high-value
    /// and unbounded; ambient screen context is capped at 20 words and is lower signal.
    public static let promptBudget = 800

    /// Build the Whisper prompt-hints string from input context.
    ///
    /// Only the final 224 tokens (~800 chars) matter to Whisper, and Whisper mimics
    /// the style of whatever ENDS the prompt — so put instruction lines first
    /// (furthest from end = least style influence) and context-derived hints later.
    ///
    /// IMPORTANT: cursor and screen context are passed as *words-only* (Set of unique
    /// tokens, length > 3, prefix 20), never raw text. Raw text causes Whisper to
    /// parrot/amplify the surrounding text's punctuation style — exactly how the
    /// comma/apostrophe feedback loop shipped in pre-v1.2.11 builds.
    ///
    /// The assembled prompt is truncated to `promptBudget` chars when it exceeds the
    /// Whisper initial_prompt token limit. Truncation removes from the start (lowest-
    /// priority sections first: instruction line, then screen context, then glossary)
    /// while preserving complete sections where possible. Cursor context is highest-
    /// priority and closest to the end of the prompt.
    public static func assemblePromptHints(input: Input) -> String? {
        var parts: [String] = []
        // Instructions first (furthest from end = least style influence)
        if input.punctuationMode == .spoken || input.punctuationMode == .hybrid {
            // Avoid commas in the instruction — whisper mimics prompt style,
            // and comma-heavy prompts cause comma spam in output.
            parts.append("Spoken punctuation: say the word \"period\" or \"comma\" or \"question mark\" to insert punctuation.")
        }
        // Screen context: extract only unique words as vocabulary hints.
        // Don't pass raw text — whisper parrots it instead of transcribing.
        // Strip terminal punctuation from tokens so embedded commas (e.g. "hello,")
        // don't survive into the prompt and amplify comma output.
        // Space-join (not comma-join) so the hint line itself carries no commas —
        // the same guard applied to cursor context to prevent the v1.2.11 feedback loop.
        // Screen context is placed BEFORE glossary so it is dropped first on budget overflow —
        // user-curated glossary terms are higher-value than ambient screen context words.
        if let screen = input.screenContextText {
            let words = Set(screen.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 3 })
                .prefix(20)
                .joined(separator: " ")
            if !words.isEmpty {
                parts.append("Context words: \(words).")
            }
        }
        // Glossary: placed after screen context so it survives truncation longer.
        // User-curated vocabulary terms are high-value and unbounded — heavy-vocab users
        // must not silently lose their custom terms while ambient screen words survive.
        if let vocab = input.glossaryWords, !vocab.isEmpty {
            parts.append("Glossary: \(vocab).")
        }
        // Cursor context: extract words-only as vocab hints — do NOT pass raw
        // text. Whisper mimics the punctuation style of whatever ENDS the prompt,
        // so feeding raw surrounding text (which is often comma/apostrophe-heavy,
        // e.g. a prior degraded dictation) makes whisper amplify commas and
        // apostrophes — a self-reinforcing spiral. Mirror the screen-context path
        // above. (Sentence-position / formality belongs in the post-pass reasoner,
        // not in whisper's prompt — whisper parrots style, it doesn't reason.)
        if let cursor = input.cursorContextText {
            let words = Set(cursor.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 3 })
                .prefix(20)
                .joined(separator: " ")
            if !words.isEmpty {
                parts.append("Context words: \(words).")
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " ")
        // Enforce the Whisper initial_prompt token budget. Whisper only reads the
        // final 224 tokens of the prompt; leading content beyond the budget is
        // silently ignored — but we truncate explicitly so the caller gets the
        // exact string that will influence the model.
        if joined.count > promptBudget {
            return String(joined.suffix(promptBudget))
        }
        return joined
    }

    /// Run the full text pipeline.
    ///
    /// - Parameters:
    ///   - input: assembled pipeline input; `input.raw` is the transcript to process.
    ///   - precomputedPrompt: when `.some(value)`, places `value` in `Result.promptHints`
    ///     instead of calling `assemblePromptHints` a second time. Pass `.some(prompt)` where
    ///     `prompt` is the result of the `assemblePromptHints` call made before Whisper ran —
    ///     this eliminates the double-assembly at finalizeRecording / FinalizePipeline.
    ///     The outer `.none` default means "compute from input as usual".
    ///     Using `String??` (not `String?`) avoids the nil-sentinel collision: `.some(nil)` means
    ///     "caller computed nil hints", `.none` means "not provided; compute now".
    /// - Parameter isRealWord: passed through to `GlossaryCorrector` — returns true
    ///   for a token that must NOT be treated as a misspelled name (defaults to the
    ///   system spell checker; tests inject a fixture for determinism).
    public static func run(_ input: Input,
                           precomputedPrompt: String?? = .none,
                           isRealWord: (String) -> Bool = GlossaryCorrector.systemIsRealWord) -> Result {
        let prompt: String?
        switch precomputedPrompt {
        case .none:
            prompt = assemblePromptHints(input: input)
        case .some(let provided):
            prompt = provided
        }
        let sanitized = sanitize(input.raw)
        // Seam dedup only where a seam can exist: FluidAudio chunks at ~14.92s, so any
        // dictation at or under 14s is single-window and can't have seam artifacts
        // (round 3: the earlier 12s gate needlessly deduped 12-14s dictations).
        let seamPossible = input.audioDurationSeconds.map { $0 > 14 } ?? true
        let marker = stripWhisperBracketMarkers(sanitized)
        let stripped = seamPossible ? collapseBoundaryDuplicateWord(marker) : marker
        let hybrid = input.punctuationMode == .hybrid
        let processed = (input.punctuationMode == .off)
            ? stripped
            : TextPostProcessor.process(stripped, hybrid: hybrid)
        let styled = TextPostProcessor.applyStyle(processed, mode: input.styleMode)
        // Glossary correction: fix near-miss misspellings of curated proper nouns
        // (makes custom names work on Parakeet, which ignores the glossary prompt).
        // Runs before case-adjust so corrected names feed the keep-capitalized logic.
        var corrected = GlossaryCorrector.correct(styled,
                                                  glossary: glossaryTerms(input.glossaryWords),
                                                  overrides: input.overrides,
                                                  isRealWord: isRealWord)
        // Screen-aware name correction (2026-07-25): when the screen visibly shows a
        // proper noun ("Kris" in the chat being replied to), its spelling beats the
        // ASR's homophone default ("Chris"). Conservative guards live in the
        // corrector; with no screen text this is a no-op.
        corrected = ScreenNameCorrector.correct(corrected,
                                                screenText: input.screenContextText,
                                                isRealWord: isRealWord)
        // Mid-sentence insertion must not start with a capital (Michael 2026-06-11:
        // "I really want it to be lowercase if I'm in the middle of the sentence").
        // Whisper sentence-cases every utterance; when the cursor context shows we're
        // continuing a sentence, undo that leading capital — glossary names, "I",
        // all-caps, and internal-caps words keep their case.
        let final = adjustCaseForInsertion(corrected,
                                           contextBefore: input.cursorContextText,
                                           glossaryWords: input.glossaryWords)
        return Result(promptHints: prompt, processedText: processed, finalText: final)
    }

    /// Split the comma-joined glossary string (as `Config.loadVocabulary()` produces
    /// it) back into individual terms for the corrector.
    static func glossaryTerms(_ glossaryWords: String?) -> [String] {
        guard let g = glossaryWords, !g.isEmpty else { return [] }
        return g.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when the text immediately before the cursor leaves us mid-sentence —
    /// i.e. the next inserted word should NOT be capitalized. Trailing spaces/tabs
    /// are ignored; an empty field, a newline, or a sentence terminator (optionally
    /// wrapped in closing quotes/brackets) means a fresh sentence.
    public static func isMidSentence(contextBefore text: String?) -> Bool {
        guard let text = text else { return false }
        var s = Substring(text)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        guard var last = s.last else { return false }
        if last.isNewline { return false }
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
        // Skip closing quotes/brackets to find the effective terminator: «He said "stop."» ends a sentence.
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
        while closers.contains(last) {
            s = s.dropLast()
            guard let prev = s.last else { return true }  // lone closer — treat as mid-sentence
            last = prev
        }
        return !terminators.contains(last)
    }

    /// Lowercase the first letter of `text` when inserting mid-sentence, unless the
    /// leading word's capitalization is deliberate (glossary term, "I", all-caps,
    /// internal caps).
    public static func adjustCaseForInsertion(_ text: String,
                                              contextBefore: String?,
                                              glossaryWords: String? = nil) -> String {
        guard isMidSentence(contextBefore: contextBefore) else { return text }
        guard let first = text.first, first.isUppercase else { return text }
        // Leading word = letters/digits/apostrophes up to the first other character.
        let firstWord = text.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" })
        if let glossary = glossaryWords, !glossary.isEmpty {
            let glossarySet = Set(glossary.components(separatedBy: ", "))
            if glossarySet.contains(String(firstWord)) { return text }
        }
        let adjusted = lowercaseFirstUnlessDeliberate(String(firstWord))
        guard adjusted != String(firstWord) else { return text }
        return adjusted + text.dropFirst(firstWord.count)
    }

    /// Collapse Whisper's multi-segment line splits into spaces — the Newline Policy 2b / Option B
    /// guarantee that every `\n` reaching insertion is a deliberately-spoken break, never an
    /// acoustic-segment boundary.
    ///
    /// Whisper emits one line per acoustic segment; `WhisperEngine.collectSegments` concatenates
    /// that raw segment text WITHOUT normalization, so a multi-segment partial can carry embedded
    /// `\n`. The FINAL inference path normalizes these away in `Transcriber.transcribeWithEngine`
    /// before `TextPipeline.run`. The T2.3 reuse path (which reuses the streaming partial and SKIPS
    /// that final pass) MUST apply the SAME normalization, or an embedded `\n` survives into
    /// `TextInserter.keystrokeOps` and fires a `.shiftReturn` — the exact send/line-break footgun 2b
    /// was built to prevent (an unspoken segment split would inject a line break).
    ///
    /// `TextPostProcessor`'s spoken-newline substitution still runs downstream, so a genuinely
    /// spoken "new line"/"new paragraph" still produces a `\n`/`\n\n` AFTER this collapse.
    public static func collapseSegmentNewlines(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Remove ANSI escape sequences and NUL bytes that could corrupt keystroke injection.
    /// Preserves \n, \r, \t (legitimate whitespace).
    public static func sanitize(_ text: String) -> String {
        // Strip ANSI CSI sequences: ESC [ ... <final byte 0x40-0x7E>
        var result = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        // Strip other ESC sequences (ESC followed by any non-[ char)
        result = result.replacingOccurrences(
            of: "\u{1B}[^\\[]",
            with: "",
            options: .regularExpression
        )
        // Strip NUL bytes — they terminate C strings and corrupt clipboard content
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    /// Remove Whisper non-speech bracket markers embedded in otherwise-real transcriptions.
    /// All pause ellipses ("..." / "…") are stripped via `stripPauseEllipses` — the user's
    /// directive (2026-06-11) is that dictation output must never contain pause markers.
    /// Collapse a chunk-boundary duplicated word: two adjacent copies of the same word,
    /// equal case-insensitively but NOT identical (they differ only in casing), separated
    /// only by whitespace. Keeps the first copy, drops the second.
    ///
    /// Root cause (Parakeet / FluidAudio 0.15.1): dictations longer than ~14.92s are split
    /// into windows with 2.0s overlap, decoded independently. A word on the seam is emitted
    /// by both windows; window 2 is SOS-primed, so it re-emits the word capitalized
    /// ("should" → "Should"). FluidAudio's overlap deduper matches token IDs, so the case
    /// difference defeats it and both survive: "...parameters should Should be allowed".
    ///
    /// The case-difference is the seam signature. Genuine same-case reduplication ("that that",
    /// "had had") is IDENTICAL, so the "not identical" guard leaves it alone. Only alphabetic
    /// word tokens separated by whitespace-only are considered — never across punctuation.
    ///
    /// Accepted tradeoff: a proper noun landing exactly on the seam ("Steve Steve") is
    /// same-case and intentionally left alone, to avoid touching legitimate reduplication.
    public static func collapseBoundaryDuplicateWord(_ text: String) -> String {
        let ns = text as NSString
        guard let wordRe = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’]*") else { return text }
        let words = wordRe.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard words.count >= 2 else { return text }
        // Scan CONSECUTIVE word tokens (non-overlapping regex-pair matching would skip the
        // seam pair). Drop the second of any adjacent pair that is equal case-insensitively
        // but not identical, separated by whitespace only (space/tab, never a newline or
        // punctuation — that would be a real sentence boundary).
        var dropRanges: [NSRange] = []
        var i = 0
        while i < words.count - 1 {
            let a = words[i].range, b = words[i + 1].range
            let sepStart = a.location + a.length
            let sepLen = b.location - sepStart
            let sep = ns.substring(with: NSRange(location: sepStart, length: sepLen))
            let wa = ns.substring(with: a), wb = ns.substring(with: b)
            // Seam signature is DIRECTIONAL: window 1 emits the word in natural (lowercase)
            // case, the SOS-primed window 2 re-emits it Capitalized — "should Should".
            // Requiring lowercase→Capitalized plus ≥3 letters spares legitimate adjacent
            // case-variants: capitonyms ("May may work", "the Polish polish"), emphasis
            // restarts ("no No, keep it"), and acronym pairs ("send it IT") — all of which
            // this collapse used to eat (adversarial review 2026-07-15, round 1).
            if sepLen > 0, sep.allSatisfy({ $0 == " " || $0 == "\t" }),
               wa.lowercased() == wb.lowercased(), wa != wb,
               wa.count >= 3,
               wa.first?.isLowercase == true, wb.first?.isUppercase == true {
                dropRanges.append(NSRange(location: sepStart, length: sepLen + b.length))
                i += 2   // consume the dropped copy so chains don't cascade
            } else {
                i += 1
            }
        }
        guard !dropRanges.isEmpty else { return text }
        let m = NSMutableString(string: text)
        for r in dropRanges.reversed() { m.deleteCharacters(in: r) }
        return m as String
    }

    public static func stripWhisperBracketMarkers(_ text: String) -> String {
        var result = text
        // Known Whisper hallucination markers
        let markers = [
            "[BLANK_AUDIO]", "[BLANK AUDIO]", "(silence)", "[SILENCE]",
            "(noise)", "[NOISE]", "[MUSIC]", "(music)",
        ]
        for marker in markers {
            result = result.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        result = stripPauseEllipses(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip Whisper's pause ellipses. Whisper renders hesitation pauses as "..." (or "…")
    /// attached to the preceding word — "make it, and... If you think" — and capitalizes the
    /// word that follows. The old standalone-only rule (`(?:^|\s)\.\.\.(?:\s|$)`) required
    /// whitespace BEFORE the dots, so it never fired on real output.
    ///
    /// Transform order matters:
    /// 1. "…" → "..." so one set of rules covers both.
    /// 2. Dots after real punctuation are redundant: "right?..." → "right?".
    /// 3. A word restarted across the pause is deduped: "there are... Are other" → "there are other".
    /// 4. Mid-text pause joins with a space, lowercasing the capitalized restart (pronoun "I"
    ///    and deliberate-caps words like "AirPods"/"OK" keep their case). A pause that truly
    ///    ended a sentence joins as a run-on — accepted tradeoff: Whisper emits "." for
    ///    confident sentence ends, "..." only for trail-offs.
    /// 5. A trailing pause ends the utterance: "a lot of..." → "a lot of."
    public static func stripPauseEllipses(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{2026}", with: "...")
        guard result.contains("...") else { return result }
        result = result.replacingOccurrences(
            of: #"([.!?,;:])\s*\.{3,}"#, with: "$1", options: .regularExpression)
        // Restarted words across the pause — two-word restarts first, then single-word.
        result = result.replacingOccurrences(
            of: #"(?i)\b(\w+\s\w+)\.{3,}\s+\1\b"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)\b(\w+)\.{3,}\s+\1\b"#, with: "$1", options: .regularExpression)
        // Mid-text pause → single space + lowercased continuation.
        if let regex = try? NSRegularExpression(pattern: #"\.{3,}\s*(\S+)"#) {
            let ns = result as NSString
            for m in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = (result as NSString).substring(with: m.range(at: 1))
                let joined = " " + lowercaseFirstUnlessDeliberate(word)
                result = (result as NSString).replacingCharacters(in: m.range, with: joined)
            }
        }
        result = result.replacingOccurrences(
            of: #"\.{3,}\s*$"#, with: ".", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"^\s*\.{3,}\s*"#, with: "", options: .regularExpression)
        return result
    }

    /// Lowercase a word's first letter unless the capitalization is deliberate:
    /// the pronoun "I" (and contractions), all-caps ("OK"), or internal caps ("AirPods").
    private static func lowercaseFirstUnlessDeliberate(_ word: String) -> String {
        guard let first = word.first, first.isUppercase else { return word }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}") { return word }
        let rest = word.dropFirst()
        guard !rest.contains(where: { $0.isUppercase }) else { return word }
        return first.lowercased() + rest
    }
}
