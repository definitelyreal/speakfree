import Foundation

public struct TextPostProcessor {
    // Boundaries use whitespace OR punctuation (not \b which treats hyphens as boundaries).
    // Punctuation in lookahead handles whisper appending periods: "Period." "Exclamation mark."
    private static let ws = "(?<=[\\s.,!?;:]|^)"
    private static let we = "(?=[\\s.,!?;:]|$)"

    // Unambiguous: these phrases are almost never used as regular words in speech.
    // Always safe to replace regardless of context.
    private static var alwaysReplace: [(pattern: String, replacement: String)] {[
        ("\(ws)question marks?\(we)", "?"),
        ("\(ws)exclamation marks?\(we)", "!"),
        ("\(ws)exclamation points?\(we)", "!"),
        ("\(ws)semicolon\(we)", ";"),
        ("\(ws)semi colon\(we)", ";"),
        // Ellipsis removed — whisper generates "..." from pauses causing false positives
        ("\(ws)full stop\(we)", "."),
        ("\(ws)open quote\(we)", "\""),
        ("\(ws)close quote\(we)", "\""),
        ("\(ws)open paren\(we)", "("),
        ("\(ws)close paren\(we)", ")"),
        ("\(ws)new line\(we)", "\n"),
        ("\(ws)newline\(we)", "\n"),
        ("\(ws)new paragraph\(we)", "\n\n"),
    ]}

    // Ambiguous: these words are commonly used as regular words ("comma separating",
    // "period of time", "colon cancer", "dash of salt"). Only replace when whisper
    // signaled a break before the word (preceded by punctuation), indicating the speaker
    // paused — meaning they intended a punctuation command, not a regular word.
    // The trailing `(?:[.,!?;:]|(?=\\s|$))` *consumes* a trailing punctuation char
    // when there is one, so that whisper's auto-punct adjacent to the user's spoken
    // word ("comma?" / "period.") does not survive into the cleanup steps and override
    // the user's stated intent. Spoken-word substitution always wins over auto-punct.
    private static var contextReplace: [(pattern: String, replacement: String)] {[
        // Require punctuation immediately before (after optional whitespace):
        // "hello, comma how" → replace ("," before "comma" = whisper saw a break)
        // "comma separating" → skip (no punctuation before = regular word)
        // Comma-homophone family: Parakeet mishears the spoken word "comma" as a small,
        // bounded set of /kVmV/ non-words. Mined from Michael's corpus 2026-07-02:
        // kama(29), kana(4), karma(3), kamala(1). All are handled here, gated on a
        // preceding punctuation break — that break is the garble signature (Parakeet
        // emits its own period/comma, then the mis-heard command). The gate is what keeps
        // a real "Kamala" or "good karma" in plain prose from being turned into a comma;
        // only the punctuation-preceded position converts. Runs BEFORE GlossaryCorrector.
        ("(?<=[.,!?;:])\\s*(?:kamala|[ck]omma|kana|kanna|kama|karma)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("(?<=[.,!?;:])\\s*period(?:[.,!?;:]|(?=\\s|$))", "."),
        ("(?<=[.,!?;:])\\s*colon(?:[.,!?;:]|(?=\\s|$))", ":"),
        ("(?<=[.,!?;:])\\s*dash(?:[.,!?;:]|(?=\\s|$))", " —"),
        ("(?<=[.,!?;:])\\s*hyphen(?:[.,!?;:]|(?=\\s|$))", "-"),
    ]}

    // Ellipsis support removed — whisper generates "..." from pauses, causing false positives.
    // All multi-dot sequences are now stripped unconditionally.

    // Fallback replacements for spoken mode (no whisper auto-punct, so no context to read).
    // These use the same boundaries as alwaysReplace — replace regardless of surrounding punct.
    private static var spokenFallback: [(pattern: String, replacement: String)] {[
        // NOTE: kamala/karma are deliberately NOT here. This is the SPOKEN-mode always-replace
        // fallback; kamala/karma are real words, so they only convert in the position-gated hybrid
        // rule above (preceded by a punctuation break = the garble signature). kama/kana/kanna are
        // non-words, safe to always-replace.
        ("\(ws)(?:[ck]omma|kana|kanna|kama)\(we)", ","),
        ("\(ws)period\(we)", "."),
        ("\(ws)colon\(we)", ":"),
        ("\(ws)dash\(we)", " —"),
        ("\(ws)hyphen\(we)", "-"),
    ]}

    /// Process spoken punctuation words into symbols.
    /// - Parameter hybrid: true for hybrid mode (context-aware replacement for ambiguous words),
    ///                     false for spoken mode (always replace everything).
    public static func process(_ text: String, hybrid: Bool = false) -> String {
        var result = text

        // 0.4. Strip surrounding quotes around spoken-command words. Whisper sometimes
        // wraps emphasized speech in quotes — `publish "Question mark"?` or `etc. "period."`
        // — so the unquoted-form rules below never see "comma"/"period"/etc. Strip the
        // quotes first; the existing rules then handle the now-unquoted command.
        result = stripQuotesAroundCommandWords(result)

        // 0.5. Collapse whisper's comma spam FIRST. If we let comma→period run first,
        // any capitalized word inside the spam ("I'd", "Claude") becomes a sentence
        // break, leaving "Hey hey. I'd. Claude do some research..." instead of
        // "Hey hey I'd Claude do some research...". Detect the run before reinterpreting
        // individual commas.
        result = collapseCommaSpam(result)

        // 0.6. Trailing comma → period for whisper-trailing-off cases. Run BEFORE
        // spoken punctuation substitution so a user-said "comma" at the end of an
        // utterance (which becomes "," after substitution) is not undone.
        result = trailingCommaToPeriod(result)

        // 1. Convert whisper's auto-commas before capitals to periods,
        // before spoken punctuation replaces words like "comma" with literal commas.
        // This way, user-intentional commas (from saying "comma") won't be overridden.
        result = commaBeforeCapitalToPeriod(result)

        // 2. Replace unambiguous spoken punctuation words (always safe)
        for (pattern, replacement) in alwaysReplace {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2a. Trim spaces adjacent to spoken line-breaks (audit M2).
        // The alwaysReplace lookbehind/lookahead for "new line"/"new paragraph" are
        // non-consuming: they match on a word boundary but leave the adjacent spaces in place,
        // producing " \n " (trailing space on the prior word, leading space on the next).
        // Trim those artifact spaces so the break is clean: "hello \n world" → "hello\nworld".
        // This runs after alwaysReplace so it only touches \n characters that arrived from
        // spoken-command substitution (Whisper multi-segment \n are already space-joined
        // upstream in Transcriber before the text reaches TextPostProcessor).
        result = trimSpacesAroundNewlines(result)

        // 2. Replace ambiguous words — strategy depends on mode
        let ambiguous = hybrid ? contextReplace : spokenFallback
        for (pattern, replacement) in ambiguous {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2.5. In hybrid mode, catch ambiguous words the context-aware regex missed.
        // The context regex requires preceding punctuation, but users often say
        // "word comma word" without whisper adding a comma first.
        if hybrid {
            result = convertStandaloneAmbiguous(result)
        }

        // 3. Collapse exactly-two-dots (from substitution duplicates) to a single dot.
        // The lookbehind+lookahead together ensure we don't touch any pair that's part
        // of a 3+ dot ellipsis run ("So... You"). Strip unicode ellipsis (whisper
        // occasionally emits it).
        if let dotsRegex = try? NSRegularExpression(pattern: "(?<!\\.)\\.\\.(?!\\.)", options: []) {
            result = dotsRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ".")
        }
        result = result.replacingOccurrences(of: "\u{2026}", with: "")

        // 4. Collapse space-separated same-type punctuation BEFORE fixSpacing.
        // Excludes "." so 3+ dot ellipses ("So...") survive — double-dots from
        // substitution duplicates are already handled by the dot-collapse above.
        if let regex = try? NSRegularExpression(pattern: "([,!?;:])(?:\\s*\\1)+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // 5. Fix spacing: remove whitespace before punctuation marks
        result = fixSpacingAroundPunctuation(result)

        // 6. Collapse adjacent different-type punctuation conflicts
        result = collapseAdjacentPunctuation(result)

        // 6.5. Re-collapse two-dot duplicates that only became ADJACENT after fixSpacing
        // removed the separating space (". ." → ".."). Step 3 ran BEFORE spacing, so it
        // missed the space-separated form — the case Parakeet produces when its own
        // sentence period collides with a spoken/stray one ("looking for. ." → "for.."
        // → "for."). Preserves 3+ dot ellipses via the same lookarounds.
        if let dotsRegex = try? NSRegularExpression(pattern: "(?<!\\.)\\.\\.(?!\\.)", options: []) {
            result = dotsRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "."
            )
        }

        // 7. Ensure space after punctuation before next word
        result = ensureSpaceAfterPunctuation(result)

        // 8. Capitalize first letter after sentence-ending punctuation (. ! ?)
        result = capitalizeAfterSentenceEnd(result)

        return result
    }

    /// Replace a trailing comma (ignoring trailing whitespace) with a period.
    /// "Hello there," → "Hello there." / "Done, " → "Done. "
    private static func trailingCommaToPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(",") else { return text }
        // Find the last comma in the original text and swap it for a period,
        // preserving any trailing whitespace exactly.
        guard let lastComma = text.lastIndex(of: ",") else { return text }
        // Confirm that everything after the comma is whitespace (so it really is trailing).
        let afterComma = text[text.index(after: lastComma)...]
        guard afterComma.allSatisfy({ $0.isWhitespace }) else { return text }
        return text.replacingCharacters(in: lastComma...lastComma, with: ".")
    }

    /// Find runs of 5+ consecutive "word, word, " patterns and strip the commas.
    /// Whisper's comma-at-every-pause pattern. A run of 5+ means commas are noise;
    /// 1-4 is normal English ("First, ..." / "Okay, yeah, I think you can ..." /
    /// "apples, oranges, bananas, and pears"). Threshold tuned from real failures
    /// where 3-rep collapse ate legitimate speech-pause commas at the start of
    /// thoughts ("Okay, yeah, I think").
    /// Strip surrounding quotes (straight or curly) around recognized spoken-command words.
    /// Whisper sometimes wraps emphasized speech in quotes, e.g. `"Question mark"` instead of
    /// the literal phrase. Stripping the quotes first lets the existing spoken-punct rules
    /// match the unquoted form. Multi-word commands ("question mark", "exclamation mark",
    /// "new paragraph") are included. Match is case-insensitive.
    private static func stripQuotesAroundCommandWords(_ text: String) -> String {
        let commands = "comma|period|question marks?|exclamation marks?|exclamation points?|semicolon|semi colon|colon|dash|hyphen|full stop|new line|newline|new paragraph|open quote|close quote|open paren|close paren"
        // Match: opening quote + command (case-insens) + optional trailing punct + closing quote.
        // Capture group 1 is the command word; we substitute back without the surrounding quotes
        // (and without the trailing punct inside the quotes — the downstream spoken-punct rules
        // produce the correct symbol from the now-unquoted command word).
        let pattern = "(?i)[\"\u{201C}\u{201D}](\(commands))[.,!?;:]*[\"\u{201C}\u{201D}]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1"
        )
    }

    private static func collapseCommaSpam(_ text: String) -> String {
        // Word chars including apostrophe + hyphen (so "I'll", "don't", "wee-hours" all count as single words)
        // Match a word, then 4+ repetitions of ", word"
        let pattern = #"\b[\w'-]+(?:,\s+[\w'-]+){4,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let matched = String(text[range])
            // Strip commas between words (but keep the words)
            let fixed = matched.replacingOccurrences(of: ", ", with: " ")
            mutable.replaceCharacters(in: match.range, with: fixed)
        }
        return mutable as String
    }

    // MARK: - Style Modes

    public enum StyleMode {
        case texting    // Signal, iMessage, WhatsApp, SMS
        case slack      // Slack, Discord, Teams
        case email      // Gmail, Outlook, Mail
        case none       // No style processing (default for unknown apps)
    }

    /// Detect style mode from the frontmost app's bundle ID.
    public static func detectStyleMode(bundleID: String?) -> StyleMode {
        guard let id = bundleID?.lowercased() else { return .none }
        // Texting apps
        if id.contains("signal") || id.contains("imessage") || id.contains("messages")
            || id.contains("whatsapp") || id.contains("telegram") || id.contains("sms") {
            return .texting
        }
        // Slack-style work chat
        if id.contains("slack") || id.contains("discord") || id.contains("teams") {
            return .slack
        }
        // Email
        if id.contains("gmail") || id.contains("mail") || id.contains("outlook")
            || id.contains("superhuman") || id.contains("spark") {
            return .email
        }
        return .none
    }

    /// Apply Michael's writing style to transcribed text.
    /// Based on style profiles derived from 172 messages across platforms.
    /// Only modifies text for messaging apps — email and other apps keep normal punctuation.
    public static func applyStyle(_ text: String, mode: StyleMode) -> String {
        // Only apply style processing for messaging apps
        guard mode == .texting || mode == .slack else { return text }

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Strip trailing period only — mid-sentence periods stay for multi-sentence dictations.
        // Michael never ends messages with a period (0% across texting platforms).
        if result.hasSuffix(".") && !result.hasSuffix("..") {
            let beforeDot = result.dropLast()
            if !beforeDot.isEmpty {
                let lastWord = String(beforeDot.split(separator: " ").last ?? "")
                if lastWord.count > 2 { // keep after abbreviations like "U.S."
                    result = String(beforeDot)
                }
            }
        }

        // Capitalize first letter (90%+ across all platforms)
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    /// Convert comma+capital → period+capital. Whisper sometimes punctuates sentence
    /// breaks with comma instead of period.
    /// Skip the standalone pronoun "I": "It's crazy, I don't understand" is almost
    /// always one comma-clause, not two sentences. (If you do want a sentence break
    /// before "I", use the period spoken word.)
    private static func commaBeforeCapitalToPeriod(_ text: String) -> String {
        // Match ", " + capital, but skip standalone "I" (followed by space, apostrophe,
        // or end of string). Other capitals stay aggressive.
        guard let regex = try? NSRegularExpression(
            pattern: ",\\s+(I(?=\\s|'|$)|[A-HJ-Z])",
            options: []) else { return text }
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let captured = (text as NSString).substring(with: match.range(at: 1))
            if captured == "I" { continue } // skip ", I" — see comment above
            mutable.replaceCharacters(in: match.range, with: ". \(captured)")
        }
        return mutable as String
    }

    /// Capitalize the first letter after sentence-ending punctuation.
    /// "hello. would love" → "hello. Would love"
    private static func capitalizeAfterSentenceEnd(_ text: String) -> String {
        // (?<!\.)  — skip the trailing dot of an ellipsis ("..."), so "could... do"
        //            stays lowercase instead of becoming "could... Do".
        // (?<![A-Z]) — skip when the dot follows a single uppercase letter, which is
        //            typically an acronym end ("U.S.A. next" / "Subs.S.A. essay").
        //            Capitalizing would turn the next common word into a fake sentence.
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\.)(?<![A-Z])([.!?])\\s+(\\w)", options: []) else { return text }
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            guard let swiftRange = Range(letterRange, in: text) else { continue }
            let upper = text[swiftRange].uppercased()
            mutable.replaceCharacters(in: letterRange, with: upper)
        }
        return mutable as String
    }

    /// In hybrid mode, convert ambiguous punctuation words when they appear as standalone
    /// words between phrases. "things like comma San Francisco" → "things like, San Francisco".
    /// Only skips conversion when the word is part of a compound like "comma separated".
    private static func convertStandaloneAmbiguous(_ text: String) -> String {
        var result = text
        let ambiguousWords: [(word: String, replacement: String, skipBefore: Set<String>)] = [
            ("comma", ",", ["separated", "delimited", "splice", "operator", "issue", "issues", "problem", "problems", "key", "question", "thing", "things", "usage", "placement", "rule", "rules", "character"]),
            ("komma", ",", []),
            ("kana", ",", []),
            ("kanna", ",", []),
            ("period", ".", ["of", "piece"]),
            ("colon", ":", ["cancer", "surgery", "cleanse", "polyp"]),
            ("dash", " —", ["of", "board", "cam"]),
            ("hyphen", "-", ["ated", "ation"]),
        ]

        for (word, replacement, skipBefore) in ambiguousWords {
            // Match the word as a standalone token (word boundaries on both sides)
            let pattern = "(?i)(?<=\\s|^)\(word)(?=\\s|$|[.,!?;:])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }

            // Process matches in reverse so indices stay valid
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }

                // Check if the next word is in the skip list
                let afterMatch = result[range.upperBound...]
                    .drop(while: { $0.isWhitespace })
                let nextWord = String(afterMatch.prefix(while: { $0.isLetter })).lowercased()
                if skipBefore.contains(nextWord) { continue }

                // If the next non-space character is whisper auto-punct, consume it —
                // user's spoken word wins ("comma." → "," not ",.", "period?" → "." not ".?").
                let trailing = result[range.upperBound...]
                let punctSet: Set<Character> = [".", ",", "!", "?", ";", ":"]
                if let firstNonWS = trailing.first(where: { !$0.isWhitespace }), punctSet.contains(firstNonWS) {
                    let endIdx = trailing.firstIndex(of: firstNonWS)!
                    let extendedRange = range.lowerBound..<result.index(after: endIdx)
                    result.replaceSubrange(extendedRange, with: replacement)
                } else {
                    result.replaceSubrange(range, with: replacement)
                }
            }
        }
        return result
    }

    /// Trim spaces that are immediately adjacent to a newline character (audit M2).
    /// The spoken-command regex for "new line" / "new paragraph" uses non-consuming
    /// lookbehind/lookahead, leaving the surrounding spaces in place: "hello \n world".
    /// This pass collapses those artifact spaces: "hello \n world" → "hello\nworld",
    /// "hello \n\n world" → "hello\n\nworld".
    /// Only spaces (U+0020) directly before or after `\n` are removed — other
    /// whitespace (tabs, multiple spaces from sentence spacing) is left untouched.
    /// `internal` (not `private`) so tests can cover it directly via @testable import.
    static func trimSpacesAroundNewlines(_ text: String) -> String {
        var result = text
        // Strip one or more spaces immediately before each \n.
        if let pre = try? NSRegularExpression(pattern: " +(?=\\n)", options: []) {
            result = pre.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Strip one or more spaces immediately after each \n.
        if let post = try? NSRegularExpression(pattern: "(?<=\\n) +", options: []) {
            result = post.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "\\s+([.,?!:;...])", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1"
        )
        return result
    }

    /// Collapse punctuation conflicts from hybrid mode (whisper auto-punct + spoken punct).
    private static func collapseAdjacentPunctuation(_ text: String) -> String {
        var result = text

        // Remove comma/semicolon/colon before a sentence-ending mark: ",!" → "!", ";." → "."
        if let regex = try? NSRegularExpression(pattern: "[,;:]\\s*([.!?...])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove period before ! or ?: ".!" → "!". Excludes "." in the character
        // class so 3+ dot ellipses ("So...") survive — sentence-end punct trumps
        // period, but a period inside an ellipsis isn't a "weaker" sentence-ender.
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*([!?])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove trailing period after ! or ?: "!." → "!", "?." → "?"
        if let regex = try? NSRegularExpression(pattern: "([!?])\\s*\\.", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove comma after ! or ?: "!," → "!", "?," → "?"
        if let regex = try? NSRegularExpression(pattern: "([!?])\\s*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove comma after period: ".," → "." (period is stronger than comma)
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "."
            )
        }

        return result
    }

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        // (?<!\d) skips a period/comma between digits ("4.30", "30,000") so decimals
        // and thousands separators aren't split into "4. 30".
        // (?![A-Z]\.) skips when the next char is an uppercase letter that's itself
        // followed by another dot — i.e. a single-letter acronym chain ("U.S.A.",
        // "Subs.S.A.I"). Keeps acronyms compact instead of shattering them into
        // "U. S. A.".
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\d)([.,?!:;])(?![A-Z]\\.)(\\w)", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1 $2"
        )
        return result
    }
}
