// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Drop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Drop",
            path: "Sources/Drop"
        )
    ]
)
