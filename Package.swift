// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ck-mlx",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ck-mlx", targets: ["CkMLXCLI"]),
        .executable(name: "ck-mlx-mcp", targets: ["CkMLXMCPServer"]),
        .library(name: "CkMLXCore", targets: ["CkMLXCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CkMLXCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "CkMLXCLI",
            dependencies: [
                "CkMLXCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CkMLXMCPServer",
            dependencies: [
                "CkMLXCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CkMLXCoreTests",
            dependencies: ["CkMLXCore"]
        ),
    ]
)
