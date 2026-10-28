// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PinpageCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PinpageCore", targets: ["PinpageCore"]),
    ],
    targets: [
        .target(name: "PinpageCore"),
        .testTarget(name: "PinpageCoreTests", dependencies: ["PinpageCore"]),
    ]
)
