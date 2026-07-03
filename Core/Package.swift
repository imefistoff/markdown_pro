// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownProCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownProCore", targets: ["MarkdownProCore"])
    ],
    targets: [
        .target(name: "MarkdownProCore")
    ]
)
