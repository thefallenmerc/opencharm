// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AudioPipeline", targets: ["AudioPipeline"])],
    targets: [
        .target(name: "AudioPipeline"),
        .testTarget(name: "AudioPipelineTests", dependencies: ["AudioPipeline"]),
    ]
)
