// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marple",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MarpleKit", targets: ["MarpleKit"]),
        .executable(name: "Marple", targets: ["Marple"]),
    ],
    dependencies: [
        // swift-markdown ships via branch, not tagged release. If `main` fails to
        // resolve against the local toolchain, pin to the matching `release/x.y`.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // Capped to 1.0.x to share a single resolution with mlx-swift-examples
        // 2.29.1 (which pins swift-transformers 1.0.0..<1.1.0). The tokenizer API
        // we use (AutoTokenizer.from(modelFolder:), encode(addSpecialTokens:)) is
        // identical in 1.0.0, so no code changes — just a version cap.
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.0.0")),
        // Pinned to a tag: `main` is mid-refactor and stopped vending MLXEmbedders
        // as an SPM product. 2.29.1 ships Libraries/Embedders with native Qwen3.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.29.1"),
        // CLI subcommand router for marple-cli (QUA-107).
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "MarpleKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        // Concrete embedding runtime (MLX). Kept in its own target so the heavy
        // MLX/Metal dependency stays out of core MarpleKit — the TextEmbedder
        // protocol seam lets the app depend on this only at the assembly point.
        .target(
            name: "MarpleEmbeddings",
            dependencies: [
                "MarpleKit",
                .product(name: "MLXEmbedders", package: "mlx-swift-examples"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "Marple",
            dependencies: [
                "MarpleKit",
                "MarpleEmbeddings",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),   // app icon catalog (from main)
            ]
        ),
        // Standalone semantic-search CLI (build/query the vector index without the
        // GUI). Run from the package root so MLX finds default.metallib.
        .executableTarget(
            name: "semantic-tool",
            dependencies: ["MarpleKit", "MarpleEmbeddings"]
        ),
        // AI-agent-facing remote-control CLI (QUA-107). Pure client — talks over
        // a Unix socket to the running Marple process; never touches the vault
        // directly. Depends on MarpleKit only for the shared wire protocol.
        .executableTarget(
            name: "marple-cli",
            dependencies: [
                "MarpleKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MarpleKitTests",
            dependencies: [
                "Marple",
                "MarpleKit",
                "MarpleEmbeddings",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // CLT-only workaround: Testing.framework lives outside the default
            // SDK search paths; these flags point the linker at it so the
            // test bundle can load at runtime.
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ]
)
