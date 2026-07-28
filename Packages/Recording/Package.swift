// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Recording",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Recording", targets: ["Recording"])],
    targets: [
        .target(name: "Recording"),
        .testTarget(name: "RecordingTests", dependencies: ["Recording"]),
    ]
)
