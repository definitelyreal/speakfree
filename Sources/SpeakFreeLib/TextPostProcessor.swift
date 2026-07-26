import Foundation

public struct TextPostProcessor {
    // Boundaries use whitespace OR punctuation (not \b which treats hyphens as boundaries).
    // Punctuation in lookahead handles whisper appending periods: "Period." "Exclamation mark."
    private static let ws = "(?<=[\\s.,!?;:]|^)"
    private static let we = "(?=[\\s.,!?;:]|$)"

    // A negation/auxiliary directly before a command word is never a command: "didn't new
    // line that" is a garble ("didn't realize that", 2026-07-03 recording FD2F92D7), and
    // converting it eats the garbled word AND inserts fake punctuation. Bounded-alternation
    // lookbehind (ICU requires bounded length).
    private static let notAfterNegation =
        "(?<!\\b(?:didn['’]t|don['’]t|doesn['’]t|can['’]t|cannot|couldn['’]t|won['’]t|wouldn['’]t"
        + "|shouldn['’]t|hasn['’]t|haven['’]t|isn['’]t|wasn['’]t|weren['’]t|not|never)\\s)"

    // Unambiguous: these phrases are almost never used as regular words in speech.
    // Always safe to replace regardless of context (except right after a negation).
    private static var alwaysReplace: [(pattern: String, replacement: String)] {[
        ("\(ws)\(notAfterNegation)question marks?\(we)", "?"),
        ("\(ws)\(notAfterNegation)exclamation marks?\(we)", "!"),
        ("\(ws)\(notAfterNegation)exclamation points?\(we)", "!"),
        ("\(ws)\(notAfterNegation)semicolon\(we)", ";"),
        ("\(ws)\(notAfterNegation)semi colon\(we)", ";"),
        // Ellipsis removed — whisper generates "..." from pauses causing false positives
        ("\(ws)\(notAfterNegation)full stop\(we)", "."),
        ("\(ws)\(notAfterNegation)open quote\(we)", "\""),
        ("\(ws)\(notAfterNegation)close quote\(we)", "\""),
        ("\(ws)\(notAfterNegation)open paren\(we)", "("),
        ("\(ws)\(notAfterNegation)close paren\(we)", ")"),
        ("\(ws)\(notAfterNegation)new line\(we)", "\n"),
        ("\(ws)\(notAfterNegation)newline\(we)", "\n"),
        ("\(ws)\(notAfterNegation)new paragraph\(we)", "\n\n"),
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
        // Sentence-punct BEFORE the comma garble is CONSUMED (not just required): the
        // user's spoken comma outranks the engine's auto-period on both sides, so
        // "unreal. Kama have" → "unreal, have" — not "unreal. Have" (2026-07-14: the
        // period used to win the collision and turn a spoken comma into a fake
        // sentence break).
        // kamala/karma are REAL words that legitimately start sentences ("…ended. Kamala won."),
        // so for them the punctuation break must appear on BOTH sides (". Kamala," — the
        // dogfood 2026-07-02 garble shape). A following word instead of punctuation means a
        // real sentence-initial use, and converting would delete the word (adversarial
        // review 2026-07-15, round 1). The non-word family keeps the loose tail.
        // Each real-word rule carries a negative lookahead mirroring the word's skipBefore
        // list from convertStandaloneAmbiguous — these rules run FIRST and used to bypass
        // those guards entirely ("…punctuation. Comma usage varies." lost the word "Comma";
        // ". Colon cancer screening" lost "Colon" — adversarial review 2026-07-15, round 2).
        // The skip-ahead guard applies ONLY to the real word "comma" — the non-word garble
        // family (komma/kana/kanna/kama) can never be legitimate prose, so guarding them
        // would just leave visible garbles ("…note. Kama usage varies" — round 3).
        ("[.;]\\s*comma\(commaSkipAhead)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("[.;]\\s*(?:komma|kana|kanna|kama)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("[.;]\\s*(?:kamala|karma)[.,!?;:]", ","),
        ("(?<=[,!?:])\\s*comma\(commaSkipAhead)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("(?<=[,!?:])\\s*(?:komma|kana|kanna|kama)(?:[.,!?;:]|(?=\\s|$))", ","),
        ("(?<=[,!?:])\\s*(?:kamala|karma)[.,!?;:]", ","),
        ("(?<=[.,!?;:])\\s*period(?!\\s+(?:of|piece)\\b)(?:[.,!?;:]|(?=\\s|$))", "."),
        ("(?<=[.,!?;:])\\s*colon(?!\\s+(?:cancer|surgery|cleanse|polyps?)\\b)(?:[.,!?;:]|(?=\\s|$))", ":"),
        ("(?<=[.,!?;:])\\s*dash(?!\\s+(?:of|board|cam)\\b)(?:[.,!?;:]|(?=\\s|$))", " —"),
        ("(?<=[.,!?;:])\\s*hyphen(?:[.,!?;:]|(?=\\s|$))", "-"),
    ]}

    /// Negative lookahead mirroring `comma`'s skipBefore list ("comma separated values",
    /// "Comma usage varies") for the punctuation-preceded rules above.
    private static let commaSkipAhead =
        "(?!\\s+(?:separated|delimited|splices?|operator|issues?|problems?|key|questions?|"
        + "things?|usage|placement|rules?|characters?)\\b)"

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

        // 2b. Collapse the engine's HALF-converted "question mark": Parakeet sometimes
        // converts the spoken word "mark" into "?" itself, leaving "question?" in the
        // text (2026-07-14: "…as they get shot at question?"). Guarded by the same
        // noun-context rule as the standalone converter ("What is the question?" stays).
        result = collapseHalfConvertedQuestionMark(result)

        // 2c. Command-word garbles that arrive as their own one-word sentence
        // (2026-07-14 glowing-line dictation, MacBook mic — engine garbles, not audio).
        result = collapseCommandWordGarbles(result)

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
        // Corpus H3/H9 (2026-07-25, 7 instances): Parakeet splits/mangles spoken
        // "exclamation mark" into "Exclamation. Mark." / "exclamation marker" /
        // "Exclamation Market". Collapse the variants to "!" attached to the
        // preceding word, mirroring the single-token spoken-punctuation handling.
        // Guard shape: the mark-word is REQUIRED mid-text ("what an exclamation
        // that was" must survive); a bare "Exclamation." converts only when it is
        // the dictation's final token (the observed split-mangle position).
        if let re = try? NSRegularExpression(
            pattern: "[ ,.]*\\bexclamation[ .]+mark(?:er|et)?\\b[.!]*|[ ,.]*\\bexclamation\\.?\\s*$",
            options: [.caseInsensitive]) {
            let ns = NSMutableString(string: result)
            let matches = re.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                ns.replaceCharacters(in: m.range, with: "! ")
            }
            result = (ns as String).replacingOccurrences(of: "! $", with: "!",
                                                         options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
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

    /// Words that mark an ambiguous punctuation word as a NOUN phrase rather than a command:
    /// a pure article or possessive directly before it ("like a colon", "add the comma",
    /// "their period") means the user is talking *about* the thing. Deliberately excludes
    /// demonstratives ("I like that comma and then…" is a plausible genuine command).
    /// Root cause of the 2026-07-03 login→colon incident: Parakeet garbled "login" into
    /// "colon" inside "like a colon where", and the unguarded standalone rule converted one
    /// recognition error into fake punctuation.
    private static let nounDeterminers: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "its", "our", "their",
    ]

    /// Words that mark "question?" as a real noun phrase rather than a half-converted
    /// spoken "question mark": determiners/possessives plus the "in question" idiom.
    private static let questionNounContext: Set<String> =
        nounDeterminers.union(["that", "this", "these", "those", "in", "no", "any", "another", "one"])

    /// Collapse "…question?" → "…?" when the engine itself converted the spoken word
    /// "mark" into "?" (leaving the word "question" behind). Skips noun usage:
    /// "What is the question?", "the person in question?".
    static func collapseHalfConvertedQuestionMark(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)(?:^|\\s+)question\\?(?=\\s|$)", options: []) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let before = result[..<range.lowerBound]
            // Scan accepts hyphens and BOTH apostrophe forms so "follow-up" and "student’s"
            // are single tokens (round 2: the curly ’ and the hyphen used to stop the scan,
            // defeating the guards below).
            let isWordChar: (Character) -> Bool = { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            let precedingWord = String(
                before.reversed().prefix(while: isWordChar).reversed()
            ).lowercased()
            if questionNounContext.contains(precedingWord) { continue }
            if precedingWord.isEmpty { continue }  // "Question?" alone — leave it
            // A possessive directly before "question" is always a real noun phrase
            // ("What was John's question?") — round 2.
            if precedingWord.hasSuffix("'s") || precedingWord.hasSuffix("’s")
                || precedingWord.hasSuffix("'") || precedingWord.hasSuffix("’") { continue }
            // Look one word further back: "a quick question?" / "a follow-up question?"
            // put an adjective between the determiner and the noun, and collapsing there
            // deletes a real word (adversarial review 2026-07-15, round 1).
            let beforeRest = before.dropLast(precedingWord.count)
            let secondPreceding = String(
                beforeRest.reversed().drop(while: { $0.isWhitespace })
                    .prefix(while: isWordChar).reversed()
            ).lowercased()
            if questionNounContext.contains(secondPreceding) { continue }
            result.replaceSubrange(range, with: "?")
        }
        return result
    }

    /// Command-word garbles observed 2026-07-14 (glowing-line dictation, MacBook mic —
    /// recognition garbles, not Bluetooth audio):
    /// - "…? Quark." — spoken "question mark" where the engine already emitted the "?"
    ///   and rendered the leftover as "Quark". Strip the stray word ("quark" as a real
    ///   word directly after a question mark is essentially nonexistent in dictation).
    /// - "…. Comment. X" — spoken "comma" rendered as a one-word sentence between two
    ///   engine periods. Join the clauses with the comma the user actually said. The
    ///   one-word-sentence signature (period on BOTH sides) is what protects genuine
    ///   uses like "leave a comment on the PR".
    static func collapseCommandWordGarbles(_ text: String) -> String {
        var result = text
        if let quark = try? NSRegularExpression(
            pattern: "(?<=\\?)\\s+[Qq]uark(?:\\.|(?=\\s|$))", options: []) {
            result = quark.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let comment = try? NSRegularExpression(
            pattern: "\\.\\s+[Cc]omment\\.(?=\\s|$)", options: []) {
            result = comment.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ",")
        }
        return result
    }

    /// In hybrid mode, convert ambiguous punctuation words when they appear as standalone
    /// words between phrases. "things like comma San Francisco" → "things like, San Francisco".
    /// Skips conversion when the word is part of a compound like "comma separated", when a
    /// real-word command follows an article/possessive (noun usage), or when a real-word
    /// command opens a multi-word utterance (punctuation with nothing before it is the garble
    /// signature — see the ": what about…" false conversion, recording 2026-07-03-010745).
    private static func convertStandaloneAmbiguous(_ text: String) -> String {
        var result = text
        // `guarded` = the word is a real English word, so position guards apply. The comma
        // garble family (komma/kana/kanna) are non-words and always convert.
        // `literalPreceders` = words that mark the command word as a real noun regardless of
        // position ("the Oxford comma.", "a transition period.") — the determiner guard can't
        // see them because an adjective sits between the determiner and the noun.
        let ambiguousWords: [(word: String, replacement: String, skipBefore: Set<String>,
                              literalPreceders: Set<String>, guarded: Bool)] = [
            ("comma", ",", ["separated", "delimited", "splice", "operator", "issue", "issues", "problem", "problems", "key", "question", "thing", "things", "usage", "placement", "rule", "rules", "character"],
             ["oxford", "serial", "trailing", "inverted"], true),
            ("komma", ",", [], [], false),
            ("kana", ",", [], [], false),
            ("kanna", ",", [], [], false),
            ("period", ".", ["of", "piece"],
             ["transition", "grace", "grading", "trial", "notice", "probationary", "probation",
              "incubation", "menstrual", "cooling-off", "billing", "waiting", "recovery"], true),
            ("colon", ":", ["cancer", "surgery", "cleanse", "polyp"],
             ["sigmoid", "transverse", "ascending", "descending"], true),
            ("dash", " —", ["of", "board", "cam"], [], true),
            ("hyphen", "-", ["ated", "ation"], [], true),
        ]

        for (word, replacement, skipBefore, literalPreceders, guarded) in ambiguousWords {
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

                // Position guards for real-word commands. Utterance-final means nothing
                // follows but one optional auto-punct char and whitespace — a digit or a
                // following sentence does NOT count ("talk about your period. It hurts" is
                // mid-utterance noun usage). Trailing commands are the most common
                // spoken-punctuation use ("…went to the store period"), so utterance-final
                // still converts by default — but the determiner and literal-preceder guards
                // apply in EVERY position: "I need to track my period." and "we discussed
                // the Oxford comma." end utterances too, and converting there deletes a real
                // word (adversarial review 2026-07-15, round 1).
                let isUtteranceFinal: Bool = {
                    var rest = afterMatch
                    if let first = rest.first, ".,!?;:".contains(first) { rest = rest.dropFirst() }
                    return rest.allSatisfy { $0.isWhitespace }
                }()
                if guarded {
                    let before = result[..<range.lowerBound]
                    let beforeTrimmed = before.reversed().drop(while: { $0.isWhitespace }).reversed()
                    if beforeTrimmed.isEmpty && !isUtteranceFinal {
                        // Utterance-opening command with more words after it: garble signature
                        // (": what about…", recording 2026-07-03-010745).
                        continue
                    }
                    // Accept hyphens and both apostrophe forms so "cooling-off" is one
                    // token — the hyphen used to stop this scan, making the hyphenated
                    // literalPreceders unreachable (round 2).
                    let precedingWord = String(
                        beforeTrimmed.reversed()
                            .prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
                            .reversed()
                    ).lowercased()
                    // Utterance-final articles stay convertible: the live capture
                    // "…and end with a comma." (recording 2026-04-29-022224) is a spoken
                    // command demo, and "a/an <command>" at the very end reads as command
                    // far more often than noun. Possessives and "the" read as noun
                    // ("track my period.") in every position.
                    let finalGuard: Set<String> = isUtteranceFinal
                        ? nounDeterminers.subtracting(["a", "an"])
                        : nounDeterminers
                    if finalGuard.contains(precedingWord) { continue }
                    if literalPreceders.contains(precedingWord) { continue }
                }

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
