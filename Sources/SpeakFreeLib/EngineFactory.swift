import Foundation

/// Builds an unloaded transcription engine from config. Honors the `SPEAKFREE_ENGINE`
/// environment override (test hook) ahead of `config.engine`; defaults to "whisper".
public enum EngineFactory {
    public static func make(config: Config) -> any TranscriptionEngine {
        let id = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"] ?? config.engine ?? "whisper"
        if id == "parakeet" {
            return ParakeetEngine()
        } else {
            return WhisperEngine()
        }
    }
}
