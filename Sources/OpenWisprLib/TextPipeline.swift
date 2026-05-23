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
        if let screen = input.screenContextText {
            let words = Set(screen.components(separatedBy: .whitespacesAndNewlines)
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
        let hybrid = input.punctuationMode == .hybrid
        let processed = (input.punctuationMode == .off)
            ? input.raw
            : TextPostProcessor.process(input.raw, hybrid: hybrid)
        let final = TextPostProcessor.applyStyle(processed, mode: input.styleMode)
        return Result(promptHints: prompt, processedText: processed, finalText: final)
    }
}
