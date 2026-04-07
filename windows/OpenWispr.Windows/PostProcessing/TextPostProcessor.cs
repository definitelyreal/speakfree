using System.Text.RegularExpressions;

namespace OpenWispr.Windows.PostProcessing;

public static class TextPostProcessor
{
    public enum StyleMode { Texting, Slack, Email, None }

    private const string Ws = @"(?<=[\s.,!?;:]|^)";
    private const string We = @"(?=[\s.,!?;:]|$)";

    private static readonly (Regex re, string replacement)[] AlwaysReplace =
    [
        (R($@"{Ws}question marks?{We}"), "?"),
        (R($@"{Ws}exclamation marks?{We}"), "!"),
        (R($@"{Ws}exclamation points?{We}"), "!"),
        (R($@"{Ws}semicolon{We}"), ";"),
        (R($@"{Ws}semi colon{We}"), ";"),
        (R($@"{Ws}full stop{We}"), "."),
        (R($@"{Ws}open quote{We}"), "\""),
        (R($@"{Ws}close quote{We}"), "\""),
        (R($@"{Ws}open paren{We}"), "("),
        (R($@"{Ws}close paren{We}"), ")"),
        (R($@"{Ws}new line{We}"), "\n"),
        (R($@"{Ws}newline{We}"), "\n"),
        (R($@"{Ws}new paragraph{We}"), "\n\n"),
    ];

    private static readonly (Regex re, string replacement)[] ContextReplace =
    [
        (R($@"(?<=[.,!?;:])\s*(?:[ck]omma|kana|kanna){We}"), ","),
        (R($@"(?<=[.,!?;:])\s*period{We}"), "."),
        (R($@"(?<=[.,!?;:])\s*colon{We}"), ":"),
        (R($@"(?<=[.,!?;:])\s*dash{We}"), " \u2014"),
        (R($@"(?<=[.,!?;:])\s*hyphen{We}"), "-"),
    ];

    private static readonly (Regex re, string replacement)[] SpokenFallback =
    [
        (R($@"{Ws}(?:[ck]omma|kana|kanna){We}"), ","),
        (R($@"{Ws}period{We}"), "."),
        (R($@"{Ws}colon{We}"), ":"),
        (R($@"{Ws}dash{We}"), " \u2014"),
        (R($@"{Ws}hyphen{We}"), "-"),
    ];

    private static Regex R(string pattern) =>
        new(pattern, RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static string Process(string text, bool hybrid = false)
    {
        var result = text;

        foreach (var (re, rep) in AlwaysReplace)
            result = re.Replace(result, rep);

        var ambiguous = hybrid ? ContextReplace : SpokenFallback;
        foreach (var (re, rep) in ambiguous)
            result = re.Replace(result, rep);

        if (hybrid)
            result = ConvertStandaloneAmbiguous(result);

        result = Regex.Replace(result, @"\.{2,}", "");
        result = result.Replace("\u2026", "");
        result = Regex.Replace(result, @"([.,!?;:])(?:\s*\1)+", "$1");
        result = StripSpacesAroundDelimiters(result);
        result = FixSpacingAroundPunctuation(result);
        result = CollapseAdjacentPunctuation(result);
        result = EnsureSpaceAfterPunctuation(result);
        result = CommaBeforeCapitalToPeriod(result);
        result = CapitalizeAfterSentenceEnd(result);

        return result;
    }

    public static StyleMode DetectStyleMode(string? appName)
    {
        if (appName is null) return StyleMode.None;
        var id = appName.ToLowerInvariant();
        if (id.Contains("signal") || id.Contains("imessage") || id.Contains("messages")
            || id.Contains("whatsapp") || id.Contains("telegram") || id.Contains("sms"))
            return StyleMode.Texting;
        if (id.Contains("slack") || id.Contains("discord") || id.Contains("teams"))
            return StyleMode.Slack;
        if (id.Contains("gmail") || id.Contains("mail") || id.Contains("outlook")
            || id.Contains("superhuman") || id.Contains("spark"))
            return StyleMode.Email;
        return StyleMode.None;
    }

    public static string ApplyStyle(string text, StyleMode mode)
    {
        if (mode != StyleMode.Texting && mode != StyleMode.Slack) return text;
        var result = text.Trim();
        if (result.Length == 0) return result;

        if (result.EndsWith('.') && !result.EndsWith(".."))
        {
            var beforeDot = result[..^1];
            if (beforeDot.Length > 0)
            {
                var lastWord = beforeDot.Split(' ').Last();
                if (lastWord.Length > 2)
                    result = beforeDot;
            }
        }

        if (char.IsLower(result[0]))
            result = char.ToUpper(result[0]) + result[1..];

        return result;
    }

    private static string ConvertStandaloneAmbiguous(string text)
    {
        var replacements = new[]
        {
            ("comma", ",", new HashSet<string> { "separated", "delimited", "splice", "operator" }),
            ("komma", ",", new HashSet<string>()),
            ("period", ".", new HashSet<string> { "of", "piece" }),
            ("colon", ":", new HashSet<string> { "cancer", "surgery", "cleanse", "polyp" }),
            ("dash", " \u2014", new HashSet<string> { "of", "board", "cam" }),
            ("hyphen", "-", new HashSet<string>()),
        };

        var result = text;
        foreach (var (word, rep, skip) in replacements)
        {
            var re = new Regex($@"(?i)(?<=\s|^){word}(?=\s|$|[.,!?;:])", RegexOptions.Compiled);
            result = re.Replace(result, m =>
            {
                var after = result[(m.Index + m.Length)..].TrimStart();
                var next = Regex.Match(after, @"^\w+").Value.ToLowerInvariant();
                return skip.Contains(next) ? m.Value : rep;
            });
        }
        return result;
    }

    private static string StripSpacesAroundDelimiters(string text)
    {
        text = Regex.Replace(text, "([\"(])\\s+", "$1");
        text = Regex.Replace(text, "\\s+([\"\\)])", "$1");
        text = Regex.Replace(text, @"\s*\n\s*", "\n");
        return text;
    }

    private static string FixSpacingAroundPunctuation(string text)
        => Regex.Replace(text, @"\s+([.,?!:;])", "$1");

    private static string EnsureSpaceAfterPunctuation(string text)
        => Regex.Replace(text, @"([.,?!:;])(\w)", "$1 $2");

    private static string CollapseAdjacentPunctuation(string text)
    {
        text = Regex.Replace(text, @"[,;:]\s*([.!?])", "$1");
        text = Regex.Replace(text, @"\.\s*([!?])", "$1");
        text = Regex.Replace(text, @"([!?])\s*\.", "$1");
        text = Regex.Replace(text, @"([!?])\s*,", "$1");
        text = Regex.Replace(text, @"\.\s*,", ".");
        return text;
    }

    private static string CommaBeforeCapitalToPeriod(string text)
    {
        var starters = new HashSet<string>
        {
            "There", "Then", "This", "That", "They", "The",
            "So", "What", "When", "Where", "Which", "While", "Who", "Why",
            "Also", "After", "Before",
        };
        return Regex.Replace(text, @",\s+([A-Z][a-z]+)", m =>
        {
            var word = m.Groups[1].Value;
            return starters.Contains(word) ? ". " + word : m.Value;
        });
    }

    private static string CapitalizeAfterSentenceEnd(string text)
        => Regex.Replace(text, @"([.!?])\s+(\w)", m =>
            m.Groups[1].Value + " " + m.Groups[2].Value.ToUpperInvariant());
}
