// swift-tools-version:6.0
import PackageDescription

// The query assistant's generation half (docs/nl-query-assistant.md, phase
// 3): a local MLX model, JSON-Schema-guided decoding, and the
// generate → repair → validate → retry loop around KorporaAssistant's
// prompt, schema and serializer.
//
// A separate package from KorporaAssistant because MLX's Metal shaders
// only build under Xcode's build system: build and test this one with
// xcodebuild (see korpora-generate's header), while KorporaAssistant stays
// plain `swift test`.
//
// mlx-swift-lm is pinned to a main-branch commit: MLXGuidedGeneration
// isn't in a tagged release yet (latest tag 3.31.4 predates it). Only the
// products below are linked - not MLXHuggingFace, whose swift-syntax macro
// plugin Xcode would ask to trust.
let package = Package(
    name: "KorporaGeneration",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KorporaGeneration", targets: ["KorporaGeneration"]),
        .executable(name: "korpora-generate", targets: ["korpora-generate"]),
    ],
    dependencies: [
        .package(path: "../KorporaAssistant"),
        .package(path: "../ManateeKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",
                 revision: "c043fb3b1ccf00f54ef8882a1e8da45c6e32e6f8"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "KorporaGeneration",
            dependencies: [
                .product(name: "KorporaAssistant", package: "KorporaAssistant"),
                .product(name: "ManateeKit", package: "ManateeKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
        .executableTarget(
            name: "korpora-generate",
            dependencies: [
                "KorporaGeneration",
                .product(name: "KorporaAssistant", package: "KorporaAssistant"),
                .product(name: "ManateeKit", package: "ManateeKit"),
            ]),
    ],
    // Swift 5 mode: MLX's model and tokenizer types aren't Sendable, and
    // they're only ever touched inside ModelContainer.perform anyway.
    swiftLanguageModes: [.v5]
)
