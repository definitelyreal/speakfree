import Foundation

/// Persists file-transcription settings across launches using UserDefaults.
/// Security-scoped bookmark is stored for the save directory so access survives relaunch.
public struct FileTranscriptionSettings {

    // MARK: - Keys

    private enum Key {
        static let engine          = "fileTranscription.engine"
        static let modelSize       = "fileTranscription.modelSize"
        static let parakeetModel   = "fileTranscription.parakeetModel"
        static let language        = "fileTranscription.language"
        static let format          = "fileTranscription.format"
        static let saveDirectoryBookmark = "fileTranscription.saveDirectoryBookmark"
    }

    // MARK: - Properties

    public var engine: String
    public var modelSize: String
    public var parakeetModel: String
    public var language: String
    public var format: OutputFormat
    public var saveDirectoryURL: URL?

    public enum OutputFormat: String, CaseIterable {
        case txt, md
        public var displayName: String { rawValue.uppercased() }
    }

    // MARK: - Defaults

    public static var `default`: FileTranscriptionSettings {
        FileTranscriptionSettings(
            engine: "whisper",
            modelSize: "large-v3-turbo",
            parakeetModel: "parakeet-tdt-0.6b-v2",
            language: "en",
            format: .txt,
            saveDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
        )
    }

    // MARK: - Load / Save

    public static func load() -> FileTranscriptionSettings {
        let defaults = UserDefaults.standard
        var s = FileTranscriptionSettings.default
        if let v = defaults.string(forKey: Key.engine)        { s.engine = v }
        if let v = defaults.string(forKey: Key.modelSize)     { s.modelSize = v }
        if let v = defaults.string(forKey: Key.parakeetModel) { s.parakeetModel = v }
        if let v = defaults.string(forKey: Key.language)      { s.language = v }
        if let v = defaults.string(forKey: Key.format),
           let f = OutputFormat(rawValue: v)                  { s.format = f }

        if let bookmark = defaults.data(forKey: Key.saveDirectoryBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                s.saveDirectoryURL = url
                // Note: caller must call stopAccessingSecurityScopedResource() when done.
                url.stopAccessingSecurityScopedResource()
            }
        }
        return s
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(engine,        forKey: Key.engine)
        defaults.set(modelSize,     forKey: Key.modelSize)
        defaults.set(parakeetModel, forKey: Key.parakeetModel)
        defaults.set(language,      forKey: Key.language)
        defaults.set(format.rawValue, forKey: Key.format)

        if let url = saveDirectoryURL,
           let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            defaults.set(bookmark, forKey: Key.saveDirectoryBookmark)
        }
    }
}
