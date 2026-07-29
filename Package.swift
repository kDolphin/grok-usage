// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrokUsage",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "GrokUsage",
            path: "Sources/GrokUsage"
        )
    ]
)
