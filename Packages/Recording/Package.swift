// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Recording",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Recording", targets: ["Recording"])],
    dependencies: [.package(path: "../ProjectStore")],
    targets: [
        .target(name: "Recording", dependencies: ["ProjectStore"]),
        .testTarget(name: "RecordingTests", dependencies: ["Recording"]),
    ]
)
