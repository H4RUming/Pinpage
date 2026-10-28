// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PinpageCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PinpageCore", targets: ["PinpageCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "PinpageCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "PinpageCoreTests",
            dependencies: ["PinpageCore"],
            resources: [.copy("Resources")]
        ),
    ]
)
