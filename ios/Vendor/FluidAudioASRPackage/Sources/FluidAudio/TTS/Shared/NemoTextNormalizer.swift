import Foundation

/// Identity normalizer for SpeakFree's ASR-only FluidAudio package.
///
/// SpeakFree does not ship FluidAudio TTS. Keeping this source-compatible stub
/// lets the upstream source tree compile without the unused CNemoTextProcessing
/// binary, whose generic module map conflicts with ExecuTorch during archiving.
public enum NemoTextNormalizer {

    /// BCP-47-ish language codes the FST engine supports.
    public enum Language: String {
        case english = "en"
        case mandarin = "zh"
        case japanese = "ja"
        case french = "fr"
        case spanish = "es"
        case german = "de"
        case hindi = "hi"
    }

    public static func normalize(_ text: String, language: Language) -> String {
        _ = language
        return text
    }
}
