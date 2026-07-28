// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RenderCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RenderCore", targets: ["RenderCore"])],
    targets: [
        .target(name: "RenderCore"),
        .testTarget(name: "RenderCoreTests", dependencies: ["RenderCore"]),
    ]
)
