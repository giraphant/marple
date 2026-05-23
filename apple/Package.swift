// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarpleKit", targets: ["MarpleKit"]),
        .executable(name: "Marple", targets: ["Marple"]),
    ],
    dependencies: [
        // swift-markdown ships via branch, not tagged release. If `main` fails to
        // resolve against the local toolchain, pin to the matching `release/x.y`.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/ciaranrobrien/SwiftUILazyContainer.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
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
        .executableTarget(
            name: "Marple",
            dependencies: [
                "MarpleKit",
                .product(name: "SwiftUILazyContainer", package: "SwiftUILazyContainer"),
            ]
        ),
        .testTarget(
            name: "MarpleKitTests",
            dependencies: [
                "MarpleKit",
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
