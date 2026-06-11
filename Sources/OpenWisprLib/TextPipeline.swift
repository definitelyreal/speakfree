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

        /// `raw` defaults to `""` so callers can construct a context-only Input for prompt
        /// assembly without needing a dummy empty-string placeholder.
        public init(raw: String = "",
                    punctuationMode: PunctuationMode,
                    cursorContextText: String? = nil,
                    screenContextText: String? = nil,
                    styleMode: TextPostProcessor.StyleMode = .none,
                    glossaryWords: String? = nil) {
            self.raw = raw
            self.cursorContextText = cursorContextText
            self.screenContextText = screenContextText
            self.punctuationMode = punctuationMode
            self.styleMode = styleMode
            self.glossaryWords = glossaryWords
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
    public static func run(_ input: Input, precomputedPrompt: String?? = .none) -> Result {
        let prompt: String?
        switch precomputedPrompt {
        case .none:
            prompt = assemblePromptHints(input: input)
        case .some(let provided):
            prompt = provided
        }
        let sanitized = sanitize(input.raw)
        let stripped = stripWhisperBracketMarkers(sanitized)
        let hybrid = input.punctuationMode == .hybrid
        let processed = (input.punctuationMode == .off)
            ? stripped
            : TextPostProcessor.process(stripped, hybrid: hybrid)
        let final = TextPostProcessor.applyStyle(processed, mode: input.styleMode)
        return Result(promptHints: prompt, processedText: processed, finalText: final)
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
    /// Standalone "..." or "…" are also stripped. Preserves ellipsis mid-sentence.
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
        // Standalone "..." or "…" at start, end, or surrounded by whitespace
        result = result.replacingOccurrences(
            of: #"(?:^|\s)\.\.\.(?:\s|$)"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?:^|\s)…(?:\s|$)"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
