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
            name: "SpeakFreeLib",
            dependencies: [
                "Sparkle",
                "CWhisper",
                "CTryCatch",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SpeakFreeLib",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "speakfree",
            dependencies: ["SpeakFreeLib"],
            path: "Sources/SpeakFree"
        ),
        // Performance-regression harness (T2.0): benchmarks per-fixture inference time +
        // simulated end-to-end latency over the audio golden fixtures, writes a fingerprinted
        // baseline JSON, and gates regressions (>+15% median) against a matching baseline.
        // `swift run perf-harness run` / `swift run perf-harness compare <candidate> <baseline>`.
        .executableTarget(
            name: "perf-harness",
            dependencies: ["SpeakFreeLib"],
            path: "Sources/PerfHarness"
        ),
        // Offline A/B harness for Parakeet vocabulary boosting (vocab-boost-eval loop).
        // Compares batch TDT, sliding-window, sliding+vocab, and batch+CTC-rescore+guard
        // on corpus wavs. Not shipped; local eval only.
        .executableTarget(
            name: "vocab-eval",
            dependencies: [
                "SpeakFreeLib",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VocabEval"
        ),
        .testTarget(
            name: "SpeakFreeTests",
            dependencies: ["SpeakFreeLib"],
            path: "Tests/SpeakFreeTests",
            resources: [
                .copy("Corpus/cases.json"),
                .copy("AudioFixtures"),
            ]
        ),
    ]
)
