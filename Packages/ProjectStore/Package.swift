// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProjectStore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProjectStore", targets: ["ProjectStore"])],
    dependencies: [
        .package(path: "../RenderCore"),
        .package(path: "../AudioPipeline"),
    ],
    targets: [
        .target(name: "ProjectStore", dependencies: ["RenderCore", "AudioPipeline"]),
        .testTarget(name: "ProjectStoreTests", dependencies: ["ProjectStore"]),
    ]
)
