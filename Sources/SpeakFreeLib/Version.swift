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
        menuTitle(bundleID: Bundle.main.bundleIdentifier ?? "",
                  buildChannel: Bundle.main.object(forInfoDictionaryKey: "SFBuildChannel") as? String)
    }

    /// Pure core of `menuTitle`, parameterized on the bundle facts so tests can pin the
    /// variant/channel matrix without a bundle.
    public static func menuTitle(bundleID: String, buildChannel: String?) -> String {
        if bundleID.hasSuffix(".streaming") { return "SpeakFree Streaming \(version) Testing" }
        if bundleID.hasSuffix(".beta") { return "SpeakFree Beta \(version) Testing" }
        return buildChannel == "release" ? "speakfree \(version)" : "speakfree \(version) Testing"
    }
}
