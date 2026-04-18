// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sim-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sim-bridge", targets: ["SimBridge"])
    ],
    targets: [
        .executableTarget(
            name: "SimBridge",
            path: "Sources/SimBridge"
        )
    ]
)
