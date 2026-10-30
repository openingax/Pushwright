// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pushwright",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PushCore", targets: ["PushCore"]),
        .library(name: "PushwrightCLI", targets: ["PushwrightCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PushCore"),
        .target(
            name: "PushwrightCLI",
            dependencies: [
                "PushCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PushCoreTests", dependencies: ["PushCore"]),
    ]
)
