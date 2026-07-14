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
                  buildChannel: Bundle.main.object(forInfoDictionaryKey: "SFBuildChannel") as? String,
                  devMode: DevMode.isActive)
    }

    /// Pure core of `menuTitle`, parameterized on the bundle facts so tests can pin the
    /// variant/channel matrix without a bundle. Dev-mode machines get a " Dev" tag so a
    /// forced-dev instance is never mistaken for stock behavior.
    public static func menuTitle(bundleID: String, buildChannel: String?, devMode: Bool = false) -> String {
        let base: String
        if bundleID.hasSuffix(".streaming") { base = "SpeakFree Streaming \(version) Testing" }
        else if bundleID.hasSuffix(".beta") { base = "SpeakFree Beta \(version) Testing" }
        else { base = buildChannel == "release" ? "speakfree \(version)" : "speakfree \(version) Testing" }
        return devMode ? base + " Dev" : base
    }
}
