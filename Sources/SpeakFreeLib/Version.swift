import Foundation

public enum SpeakFree {
    public static let version = "1.7.1"

    /// Menu-bar title reflecting the build variant and mode, so an experimental/test build is
    /// never mistaken for the dogfood release. (2026-07-02: two builds ran at once, fought the
    /// fn hotkey, and it wasn't obvious which was which — see the project CLAUDE.md convention.)
    ///
    /// - Streaming / Beta variants: always tagged "Testing" (inherently experimental).
    /// - Production: "Testing" for local dev builds; clean ("speakfree X.Y.Z") ONLY for the
    ///   released DMG, which `scripts/build.sh` stamps with Info.plist `SFBuildChannel = release`.
    public static var menuTitle: String {
        let bid = Bundle.main.bundleIdentifier ?? ""
        let isRelease = (Bundle.main.object(forInfoDictionaryKey: "SFBuildChannel") as? String) == "release"
        if bid.hasSuffix(".streaming") { return "SpeakFree Streaming \(version) Testing" }
        if bid.hasSuffix(".beta") { return "SpeakFree Beta \(version) Testing" }
        return isRelease ? "speakfree \(version)" : "speakfree \(version) Testing"
    }
}
