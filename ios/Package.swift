// swift-tools-version: 5.9
// ai-suggestion:unverified · session:unknown · 2026-08-16

import PackageDescription

let package = Package(
    name: "SpeakFreeKeyboardCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SpeakFreeKeyboardCore", targets: ["SpeakFreeKeyboardCore"]),
    ],
    targets: [
        .target(name: "SpeakFreeKeyboardCore"),
        .testTarget(
            name: "SpeakFreeKeyboardCoreTests",
            dependencies: ["SpeakFreeKeyboardCore"]
        ),
    ]
)
