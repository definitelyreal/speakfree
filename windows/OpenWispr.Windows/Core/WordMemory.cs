namespace OpenWispr.Windows.Core;

public static class WordMemory
{
    public static string? LoadVocabulary(string path)
    {
        if (!File.Exists(path)) return null;
        var words = File.ReadAllLines(path)
            .Select(line =>
            {
                var l = line.Trim();
                var autoIdx = l.IndexOf(" # auto", StringComparison.OrdinalIgnoreCase);
                if (autoIdx >= 0) l = l[..autoIdx].Trim();
                return l;
            })
            .Where(l => !string.IsNullOrEmpty(l) && !l.StartsWith('#'))
            .ToList();
        return words.Count > 0 ? string.Join(", ", words) : null;
    }

    public static void LearnWord(string word, string path)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        File.AppendAllText(path, $"{word} # auto{Environment.NewLine}");
    }
}
