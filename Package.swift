// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Flyers",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FlyersCore"),
        .executableTarget(name: "Flyers", dependencies: ["FlyersCore"]),
        .executableTarget(name: "flyers-check", dependencies: ["FlyersCore"]),
        .testTarget(name: "FlyersCoreTests", dependencies: ["FlyersCore"]),
    ],
    swiftLanguageModes: [.v5]
)
