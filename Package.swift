// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "continuo",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ContinuoCore"),
        .executableTarget(name: "continuo", dependencies: ["ContinuoCore"]),
        .testTarget(name: "ContinuoCoreTests", dependencies: ["ContinuoCore"]),
    ]
)
