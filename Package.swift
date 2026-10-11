// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: ["vendor/LICENSE", "vendor/README.md"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Clio",
            dependencies: ["CZstd"],
            path: "Sources/Clio",
            resources: [.copy("Resources/CodexHelper"), .copy("Resources/Zstandard-LICENSE.txt")]
        ),
        .executableTarget(name: "CodexHelper", path: "Tools/CodexHelper"),
    ]
)
