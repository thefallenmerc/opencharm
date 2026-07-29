// swift-tools-version: 5.10
import Foundation
import PackageDescription

// The RNNoise trained-model weights (~74 MB of generated C) are not vendored
// in git; `Tools/fetch-rnnoise-model.sh` downloads and checksum-verifies them
// (run automatically by `make gen`/`make build`/`make test`). Fail fast with
// an actionable message rather than a confusing link error if someone
// invokes `swift build`/`swift test` directly without having fetched it.
let rnnoiseDataC = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/CRNNoise/rnnoise_data.c")
if !FileManager.default.fileExists(atPath: rnnoiseDataC.path) {
    fatalError("""
        Missing \(rnnoiseDataC.path)
        (RNNoise model weights). Run `make fetch-model` from the repo root \
        to download and verify it, then retry.
        """)
}

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AudioPipeline", targets: ["AudioPipeline"])],
    targets: [
        .target(name: "CRNNoise",
                cSettings: [.unsafeFlags(["-w"])]), // vendored code: silence its warnings
        .target(name: "AudioPipeline", dependencies: ["CRNNoise"]),
        .testTarget(name: "AudioPipelineTests", dependencies: ["AudioPipeline"]),
    ]
)
