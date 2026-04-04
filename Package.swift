// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iatemplate2pdf",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/brokenhandsio/cmark-gfm.git", from: "2.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "CMarkBridge",
            dependencies: [
                .product(name: "cmark", package: "cmark-gfm"),
            ],
            path: "Sources/CMarkBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "iatemplate2pdf",
            dependencies: [
                .product(name: "cmark", package: "cmark-gfm"),
                .product(name: "MCP", package: "swift-sdk"),
                "CMarkBridge",
            ],
            path: "Sources",
            exclude: ["CMarkBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
