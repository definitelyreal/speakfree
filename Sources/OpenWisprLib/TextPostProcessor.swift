import Foundation

public struct TextPostProcessor {
    // Boundaries use whitespace OR punctuation (not \b which treats hyphens as boundaries,
    // causing false positives on "comma-separated"). Punctuation in lookahead handles whisper
    // appending periods after spoken words like "Period." or "Exclamation mark."
    private static let ws = "(?<=[\\s.,!?;:]|^)"
    private static let we = "(?=[\\s.,!?;:]|$)"

    private static var replacements: [(pattern: String, replacement: String)] {[
        ("\(ws)period\(we)", "."),
        ("\(ws)full stop\(we)", "."),
        ("\(ws)[ck]omma\(we)", ","),
        ("\(ws)question mark\(we)", "?"),
        ("\(ws)exclamation mark\(we)", "!"),
        ("\(ws)exclamation point\(we)", "!"),
        ("\(ws)colon\(we)", ":"),
        ("\(ws)semicolon\(we)", ";"),
        ("\(ws)semi colon\(we)", ";"),
        ("\(ws)ellipsis\(we)", "..."),
        ("\(ws)dash\(we)", " —"),
        ("\(ws)hyphen\(we)", "-"),
        ("\(ws)open quote\(we)", "\""),
        ("\(ws)close quote\(we)", "\""),
        ("\(ws)open paren\(we)", "("),
        ("\(ws)close paren\(we)", ")"),
        ("\(ws)new line\(we)", "\n"),
        ("\(ws)newline\(we)", "\n"),
        ("\(ws)new paragraph\(we)", "\n\n"),
    ]}

    // Unicode placeholder for real ellipsis (from spoken "ellipsis" word)
    private static let ellipsisPlaceholder = "\u{FFFE}"

    public static func process(_ text: String) -> String {
        var result = text

        // 1. Replace spoken punctuation words with symbols
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2. Protect real ellipsis (from spoken "ellipsis" word) before collapsing
        result = result.replacingOccurrences(of: "...", with: ellipsisPlaceholder)

        // 3. Collapse space-separated same-type punctuation BEFORE fixSpacing
        //    e.g. ". .." → "." (spoken period creating duplicates with whisper period)
        if let regex = try? NSRegularExpression(pattern: "([.,!?;:])(?:\\s*\\1)+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // 4. Fix spacing: remove whitespace before punctuation marks
        result = fixSpacingAroundPunctuation(result)

        // 5. Collapse adjacent different-type punctuation conflicts
        result = collapseAdjacentPunctuation(result)

        // 6. Restore ellipsis
        result = result.replacingOccurrences(of: ellipsisPlaceholder, with: "...")

        // 7. Normalize 4+ dots to ellipsis
        if let regex = try? NSRegularExpression(pattern: "\\.{4,}", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "..."
            )
        }

        // 8. Ensure space after punctuation before next word
        result = ensureSpaceAfterPunctuation(result)

        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "\\s+([.,?!:;\u{FFFE}])", options: []) else { return result }
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
        if let regex = try? NSRegularExpression(pattern: "[,;:]\\s*([.!?\u{FFFE}])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove period before ! or ? or ellipsis: ".!" → "!"
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*([!?\u{FFFE}])", options: []) {
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

        // Remove period before comma: ".," → ","
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ","
            )
        }

        return result
    }

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "([.,?!:;])(\\w)", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1 $2"
        )
        return result
    }
}
