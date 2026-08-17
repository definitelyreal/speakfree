// ai-suggestion:unverified · session:unknown · 2026-08-16

public enum TypingAlternates {
    /// Stable ordering is intentional so the UI can position the most common choice nearest the key.
    public static func alternatives(for key: String) -> [String] {
        let alternatives = values[key.lowercased()] ?? []
        if key.first?.isUppercase == true {
            return alternatives.map { $0.uppercased() }
        }
        return alternatives
    }

    private static let values: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "d": ["ð", "ď"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "g": ["ğ"],
        "i": ["ì", "í", "î", "ï", "ī", "į"],
        "l": ["ł"],
        "n": ["ñ", "ń", "ň"],
        "o": ["ò", "ó", "ô", "ö", "œ", "ø", "õ", "ō"],
        "r": ["ř"],
        "s": ["ß", "ś", "š"],
        "t": ["þ", "ť"],
        "u": ["ù", "ú", "û", "ü", "ū"],
        "y": ["ý", "ÿ"],
        "z": ["ź", "ž", "ż"],
        "0": ["°"],
        "-": ["–", "—", "•"],
        ".": ["…"],
        "'": ["’", "‘", "`"],
        "\"": ["”", "“", "«", "»"],
        "$": ["¢", "£", "€", "¥", "₩", "₽"],
        "?": ["¿"],
        "!": ["¡"]
    ]
}
