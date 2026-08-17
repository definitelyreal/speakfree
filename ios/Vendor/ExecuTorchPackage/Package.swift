// swift-tools-version: 5.9
// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
// Minimal local manifest for the official ExecuTorch 1.2.0 binary artifacts.
import PackageDescription

let package = Package(
    name: "ExecuTorch",
    platforms: [.iOS(.v17), .macOS(.v12)],
    products: [
        .library(
            name: "SpeakFreeExecuTorch",
            targets: ["executorch", "backend_xnnpack", "kernels_optimized", "threadpool"]
        ),
        .library(name: "executorch", targets: ["executorch"]),
        .library(name: "backend_xnnpack", targets: ["backend_xnnpack", "threadpool"]),
        .library(name: "kernels_optimized", targets: ["kernels_optimized", "threadpool"]),
    ],
    targets: [
        .binaryTarget(
            name: "executorch",
            url: "https://ossci-ios.s3.amazonaws.com/executorch/executorch-1.2.0.zip",
            checksum: "14ee5df4b64984a4b834cfd92234b96222f483b4f19f6d193b45301d8c8b4527"
        ),
        .binaryTarget(
            name: "backend_xnnpack",
            url: "https://ossci-ios.s3.amazonaws.com/executorch/backend_xnnpack-1.2.0.zip",
            checksum: "e676641b8ce773dbafc575d68626c7f710fdc898b5bc5749a77270bc3fae2bd1"
        ),
        .binaryTarget(
            name: "kernels_optimized",
            url: "https://ossci-ios.s3.amazonaws.com/executorch/kernels_optimized-1.2.0.zip",
            checksum: "d4a7252a82ff744f43861cde69202ec250ebab67fc11101ba791f5c8f0fb8735"
        ),
        .binaryTarget(
            name: "threadpool",
            url: "https://ossci-ios.s3.amazonaws.com/executorch/threadpool-1.2.0.zip",
            checksum: "bff9ceee8e022498160ad733abbaa4ab8e1d87bf636ca46ce5880cb17b9661de"
        ),
    ]
)
