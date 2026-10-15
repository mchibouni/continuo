// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "karmic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KarmicCore"),
        .executableTarget(name: "karmic", dependencies: ["KarmicCore"]),
        .testTarget(name: "KarmicCoreTests", dependencies: ["KarmicCore"]),
    ]
)
