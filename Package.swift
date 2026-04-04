// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iatemplate2pdf",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "iatemplate2pdf",
            path: "Sources"
        )
    ]
)
