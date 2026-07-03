// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "markdownpro-mcp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .executableTarget(
            name: "markdownpro-mcp",
            dependencies: [.product(name: "MarkdownProCore", package: "Core")]
        )
    ]
)
