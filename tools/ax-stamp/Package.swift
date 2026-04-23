// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ax-stamp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ax-stamp", targets: ["AXStampCLI"]),
        .library(name: "AXStampKit", targets: ["AXStampKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AXStampKit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "AXStampCLI",
            dependencies: [
                "AXStampKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AXStampTests",
            dependencies: ["AXStampKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
