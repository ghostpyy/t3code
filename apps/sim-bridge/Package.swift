// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "sim-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sim-bridge", targets: ["SimBridge"])
    ],
    targets: [
        .systemLibrary(
            name: "CPrivate",
            path: "PrivateHeaders"
        ),
        .target(
            name: "CSupport",
            path: "Sources/CSupport",
            publicHeadersPath: "include",
            cSettings: [
                // Needed for the Indigo wire-format structs used by
                // T3BuildIndigoTouchMessage. We intentionally live outside
                // SimBridge so the ObjC code can use @try/@catch (Swift cannot).
                .headerSearchPath("../../PrivateHeaders"),
            ]
        ),
        .executableTarget(
            name: "SimBridge",
            dependencies: ["CPrivate", "CSupport"],
            path: "Sources/SimBridge",
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-IPrivateHeaders",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F",
                    "-Xlinker", "/Library/Developer/PrivateFrameworks",
                    "-Xlinker", "-F",
                    "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks",
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "CoreSimulator",
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "SimulatorKit",
                ])
            ]
        ),
        .testTarget(
            name: "SimBridgeTests",
            dependencies: ["SimBridge", "CPrivate"],
            path: "Tests/SimBridgeTests",
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-IPrivateHeaders",
                ])
            ]
        ),
    ],
    swiftLanguageVersions: [.v6]
)
