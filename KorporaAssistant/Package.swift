// swift-tools-version:5.9
import PackageDescription

// The natural-language query assistant's model-independent half
// (docs/nl-query-assistant.md): the QueryPlan the model fills in, its
// per-corpus JSON Schema, CQL serialization, corpus profiling and prompt
// building. Kept out of the app target so it tests with plain `swift test`
// and so `korpora-assistant` (a dev CLI) can print the exact prompt the
// app would build, for the benchmark harness in scripts/nl-spike/.
//
// macOS 14 is mlx-swift-lm's floor, which this package will depend on once
// generation lands here; the app's own floor (15) is above it.
let package = Package(
    name: "KorporaAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KorporaAssistant", targets: ["KorporaAssistant"]),
        .executable(name: "korpora-assistant", targets: ["korpora-assistant"]),
    ],
    dependencies: [
        .package(path: "../ManateeKit"),
    ],
    targets: [
        .target(
            name: "KorporaAssistant",
            dependencies: [.product(name: "ManateeKit", package: "ManateeKit")],
            resources: [.process("Resources")]),
        .executableTarget(
            name: "korpora-assistant",
            dependencies: ["KorporaAssistant", .product(name: "ManateeKit", package: "ManateeKit")]),
        .testTarget(
            name: "KorporaAssistantTests",
            dependencies: ["KorporaAssistant"]),
    ]
)
