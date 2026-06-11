// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speakfree",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.1"),
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
        // Tiny Objective-C bridge so Swift can catch NSException from AVAudioEngine
        // (e.g. installTap on a transient Bluetooth-handoff format). See CTryCatch.h.
        .target(
            name: "CTryCatch",
            path: "Sources/CTryCatch",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OpenWisprLib",
            dependencies: [
                "Sparkle",
                "CWhisper",
                "CTryCatch",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
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
        // Performance-regression harness (T2.0): benchmarks per-fixture inference time +
        // simulated end-to-end latency over the audio golden fixtures, writes a fingerprinted
        // baseline JSON, and gates regressions (>+15% median) against a matching baseline.
        // `swift run perf-harness run` / `swift run perf-harness compare <candidate> <baseline>`.
        .executableTarget(
            name: "perf-harness",
            dependencies: ["OpenWisprLib"],
            path: "Sources/PerfHarness"
        ),
        .testTarget(
            name: "OpenWisprTests",
            dependencies: ["OpenWisprLib"],
            path: "Tests/OpenWisprTests",
            resources: [
                .copy("Corpus/cases.json"),
                .copy("AudioFixtures"),
            ]
        ),
    ]
)
