// swift-tools-version: 5.10
import PackageDescription

// Note: the RNNoise trained-model weights (Sources/CRNNoise/rnnoise_data.c,
// ~74 MB, not committed — see .gitignore) are fetched at build time by
// Tools/fetch-rnnoise-model.sh (`make fetch-model`, a dependency of
// `make gen`/`build`/`test`). If it's missing, CRNNoise/opencharm_model_guard.c
// fails compilation with a clear `#error` rather than failing manifest
// evaluation here — a manifest-level guard would crash package-graph
// resolution (and thus Xcode, SourceKit, `swift package describe/resolve`,
// and any sibling package that merely depends on AudioPipeline by path) for
// the whole graph, not just an actual attempt to build this target.

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
