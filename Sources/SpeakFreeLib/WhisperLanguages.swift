import Foundation

/// A Whisper-supported language with its ISO code and English name.
public struct WhisperLanguage: Identifiable, Hashable {
    public let id: String   // whisper code: "en", "es", "ja"
    public let name: String

    /// All 99 languages supported by Whisper, in canonical order.
    public static let all: [WhisperLanguage] = [
        WhisperLanguage(id: "en", name: "English"),
        WhisperLanguage(id: "zh", name: "Chinese"),
        WhisperLanguage(id: "de", name: "German"),
        WhisperLanguage(id: "es", name: "Spanish"),
        WhisperLanguage(id: "ru", name: "Russian"),
        WhisperLanguage(id: "ko", name: "Korean"),
        WhisperLanguage(id: "fr", name: "French"),
        WhisperLanguage(id: "ja", name: "Japanese"),
        WhisperLanguage(id: "pt", name: "Portuguese"),
        WhisperLanguage(id: "tr", name: "Turkish"),
        WhisperLanguage(id: "pl", name: "Polish"),
        WhisperLanguage(id: "ca", name: "Catalan"),
        WhisperLanguage(id: "nl", name: "Dutch"),
        WhisperLanguage(id: "ar", name: "Arabic"),
        WhisperLanguage(id: "sv", name: "Swedish"),
        WhisperLanguage(id: "it", name: "Italian"),
        WhisperLanguage(id: "id", name: "Indonesian"),
        WhisperLanguage(id: "hi", name: "Hindi"),
        WhisperLanguage(id: "fi", name: "Finnish"),
        WhisperLanguage(id: "vi", name: "Vietnamese"),
        WhisperLanguage(id: "he", name: "Hebrew"),
        WhisperLanguage(id: "uk", name: "Ukrainian"),
        WhisperLanguage(id: "el", name: "Greek"),
        WhisperLanguage(id: "ms", name: "Malay"),
        WhisperLanguage(id: "cs", name: "Czech"),
        WhisperLanguage(id: "ro", name: "Romanian"),
        WhisperLanguage(id: "da", name: "Danish"),
        WhisperLanguage(id: "hu", name: "Hungarian"),
        WhisperLanguage(id: "ta", name: "Tamil"),
        WhisperLanguage(id: "no", name: "Norwegian"),
        WhisperLanguage(id: "th", name: "Thai"),
        WhisperLanguage(id: "ur", name: "Urdu"),
        WhisperLanguage(id: "hr", name: "Croatian"),
        WhisperLanguage(id: "bg", name: "Bulgarian"),
        WhisperLanguage(id: "lt", name: "Lithuanian"),
        WhisperLanguage(id: "la", name: "Latin"),
        WhisperLanguage(id: "mi", name: "Maori"),
        WhisperLanguage(id: "ml", name: "Malayalam"),
        WhisperLanguage(id: "cy", name: "Welsh"),
        WhisperLanguage(id: "sk", name: "Slovak"),
        WhisperLanguage(id: "te", name: "Telugu"),
        WhisperLanguage(id: "fa", name: "Persian"),
        WhisperLanguage(id: "lv", name: "Latvian"),
        WhisperLanguage(id: "bn", name: "Bengali"),
        WhisperLanguage(id: "sr", name: "Serbian"),
        WhisperLanguage(id: "az", name: "Azerbaijani"),
        WhisperLanguage(id: "sl", name: "Slovenian"),
        WhisperLanguage(id: "kn", name: "Kannada"),
        WhisperLanguage(id: "et", name: "Estonian"),
        WhisperLanguage(id: "mk", name: "Macedonian"),
        WhisperLanguage(id: "br", name: "Breton"),
        WhisperLanguage(id: "eu", name: "Basque"),
        WhisperLanguage(id: "is", name: "Icelandic"),
        WhisperLanguage(id: "hy", name: "Armenian"),
        WhisperLanguage(id: "ne", name: "Nepali"),
        WhisperLanguage(id: "mn", name: "Mongolian"),
        WhisperLanguage(id: "bs", name: "Bosnian"),
        WhisperLanguage(id: "kk", name: "Kazakh"),
        WhisperLanguage(id: "sq", name: "Albanian"),
        WhisperLanguage(id: "sw", name: "Swahili"),
        WhisperLanguage(id: "gl", name: "Galician"),
        WhisperLanguage(id: "mr", name: "Marathi"),
        WhisperLanguage(id: "pa", name: "Punjabi"),
        WhisperLanguage(id: "si", name: "Sinhala"),
        WhisperLanguage(id: "km", name: "Khmer"),
        WhisperLanguage(id: "sn", name: "Shona"),
        WhisperLanguage(id: "yo", name: "Yoruba"),
        WhisperLanguage(id: "so", name: "Somali"),
        WhisperLanguage(id: "af", name: "Afrikaans"),
        WhisperLanguage(id: "oc", name: "Occitan"),
        WhisperLanguage(id: "ka", name: "Georgian"),
        WhisperLanguage(id: "be", name: "Belarusian"),
        WhisperLanguage(id: "tg", name: "Tajik"),
        WhisperLanguage(id: "sd", name: "Sindhi"),
        WhisperLanguage(id: "gu", name: "Gujarati"),
        WhisperLanguage(id: "am", name: "Amharic"),
        WhisperLanguage(id: "yi", name: "Yiddish"),
        WhisperLanguage(id: "lo", name: "Lao"),
        WhisperLanguage(id: "uz", name: "Uzbek"),
        WhisperLanguage(id: "fo", name: "Faroese"),
        WhisperLanguage(id: "ht", name: "Haitian Creole"),
        WhisperLanguage(id: "ps", name: "Pashto"),
        WhisperLanguage(id: "tk", name: "Turkmen"),
        WhisperLanguage(id: "nn", name: "Nynorsk"),
        WhisperLanguage(id: "mt", name: "Maltese"),
        WhisperLanguage(id: "sa", name: "Sanskrit"),
        WhisperLanguage(id: "lb", name: "Luxembourgish"),
        WhisperLanguage(id: "my", name: "Myanmar"),
        WhisperLanguage(id: "bo", name: "Tibetan"),
        WhisperLanguage(id: "tl", name: "Tagalog"),
        WhisperLanguage(id: "mg", name: "Malagasy"),
        WhisperLanguage(id: "as", name: "Assamese"),
        WhisperLanguage(id: "tt", name: "Tatar"),
        WhisperLanguage(id: "haw", name: "Hawaiian"),
        WhisperLanguage(id: "ln", name: "Lingala"),
        WhisperLanguage(id: "ha", name: "Hausa"),
        WhisperLanguage(id: "ba", name: "Bashkir"),
        WhisperLanguage(id: "jw", name: "Javanese"),
        WhisperLanguage(id: "su", name: "Sundanese"),
        WhisperLanguage(id: "yue", name: "Cantonese"),
    ]

    /// Lookup table for O(1) find-by-code.
    private static let byCode: [String: WhisperLanguage] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    /// Find a language by its Whisper code.
    public static func find(_ code: String) -> WhisperLanguage? {
        byCode[code.lowercased()]
    }

    /// Search languages by name or code prefix (for autocomplete).
    /// Returns all languages when query is empty.
    public static func search(_ query: String) -> [WhisperLanguage] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return all }
        return all.filter { lang in
            lang.name.lowercased().hasPrefix(q) || lang.id.lowercased().hasPrefix(q)
        }
    }

    /// Convert an English-only model name to its multilingual equivalent.
    /// e.g. "small.en" -> "small", "large-v3" -> "large-v3" (unchanged)
    public static func multilingualModel(for model: String) -> String {
        if model.hasSuffix(".en") {
            return String(model.dropLast(3))
        }
        return model
    }

    /// Whether a model identifier is English-only (has ".en" suffix).
    public static func isEnglishOnly(_ model: String) -> Bool {
        model.hasSuffix(".en")
    }
}
