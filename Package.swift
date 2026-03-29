// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speakfree",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0"),
    ],
    targets: [
        // C module wrapping whisper.cpp headers — links against the bundled dylib
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lwhisper",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .target(
            name: "OpenWisprLib",
            dependencies: ["Sparkle", "CWhisper"],
            path: "Sources/OpenWisprLib",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "speakfree",
            dependencies: ["OpenWisprLib"],
            path: "Sources/SpeakFree"
        ),
        .testTarget(
            name: "OpenWisprTests",
            dependencies: ["OpenWisprLib"],
            path: "Tests/OpenWisprTests"
        ),
    ]
)
