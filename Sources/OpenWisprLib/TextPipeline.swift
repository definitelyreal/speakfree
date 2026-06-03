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
        public init(raw: String,
                    cursorContextText: String?,
                    screenContextText: String?,
                    punctuationMode: PunctuationMode,
                    styleMode: TextPostProcessor.StyleMode,
                    glossaryWords: String?) {
            self.raw = raw
            self.cursorContextText = cursorContextText
            self.screenContextText = screenContextText
            self.punctuationMode = punctuationMode
            self.styleMode = styleMode
            self.glossaryWords = glossaryWords
        }
    }

    public struct Result {
        public let promptHints: String?    // what would be sent to Whisper's prompt
        public let processedText: String   // after TextPostProcessor.process
        public let finalText: String       // after applyStyle
    }

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
    public static func assemblePromptHints(input: Input) -> String? {
        var parts: [String] = []
        // Instructions first (furthest from end = least style influence)
        if input.punctuationMode == .spoken || input.punctuationMode == .hybrid {
            // Avoid commas in the instruction — whisper mimics prompt style,
            // and comma-heavy prompts cause comma spam in output.
            parts.append("Spoken punctuation: say the word \"period\" or \"comma\" or \"question mark\" to insert punctuation.")
        }
        if let vocab = input.glossaryWords, !vocab.isEmpty {
            parts.append("Glossary: \(vocab).")
        }
        // Screen context: extract only unique words as vocabulary hints.
        // Don't pass raw text — whisper parrots it instead of transcribing.
        // Strip terminal punctuation from tokens so embedded commas (e.g. "hello,")
        // don't survive into the prompt and amplify comma output.
        if let screen = input.screenContextText {
            let words = Set(screen.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 3 })
                .prefix(20)
                .joined(separator: ", ")
            if !words.isEmpty {
                parts.append("Context words: \(words).")
            }
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
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static func run(_ input: Input) -> Result {
        let prompt = assemblePromptHints(input: input)
        let sanitized = sanitize(input.raw)
        let stripped = stripWhisperBracketMarkers(sanitized)
        let hybrid = input.punctuationMode == .hybrid
        let processed = (input.punctuationMode == .off)
            ? stripped
            : TextPostProcessor.process(stripped, hybrid: hybrid)
        let final = TextPostProcessor.applyStyle(processed, mode: input.styleMode)
        return Result(promptHints: prompt, processedText: processed, finalText: final)
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
