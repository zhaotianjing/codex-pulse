// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageFloat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageFloat", targets: ["CodexUsageFloat"])
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageFloat",
            path: "Sources/CodexUsageFloat"
        )
    ]
)
