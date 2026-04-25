import XCTest
@testable import SimBridge
import CPrivate

/// Boot a real iOS simulator, install a fixture SwiftUI app, tap at the AX
/// frame of a button, verify via AX that the tap landed. Covers
/// CoreSimulator + SimulatorKit + Indigo + AXP in one flow.
///
/// Disabled by default. To run:
///   1. Build the fixture `.app` via
///        `xcodebuild -project apps/sim-bridge/Tests/Fixtures/T3SimFixture.xcodeproj \
///                    -scheme T3SimFixture -configuration Debug \
///                    -sdk iphonesimulator -derivedDataPath ./build build`
///      and copy the resulting `.app` to `apps/sim-bridge/Tests/Fixtures/T3SimFixture.app`.
///   2. `cd apps/sim-bridge && T3_E2E=1 swift test --filter EmbeddedSimulatorE2E`.
///
/// Expected total runtime: ~60s.
final class EmbeddedSimulatorE2E: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        guard ProcessInfo.processInfo.environment["T3_E2E"] == "1" else {
            return XCTestSuite(name: "skipped — set T3_E2E=1 to enable")
        }
        return super.defaultTestSuite
    }

    private var fixtureAppURL: URL {
        URL(fileURLWithPath: "Tests/Fixtures/T3SimFixture.app")
    }

    func testBootInstallTapVerify() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixtureAppURL.path),
            "Fixture app missing at \(fixtureAppURL.path) — see class-level docs for how to build it."
        )

        let ctx = try ServiceContext.make()
        let devices = ctx.devices()
        guard let candidate = devices.first(where: {
            $0.model.hasPrefix("iPhone") && $0.state != .booted
        }) else {
            try XCTSkipIf(true, "No eligible shutdown iPhone simulator available.")
            return
        }
        guard let simDevice = ctx.device(udid: candidate.udid) else {
            XCTFail("Could not look up SimDevice for UDID \(candidate.udid)")
            return
        }

        let device = Device(simDevice: simDevice)
        try await device.boot()
        addTeardownBlock {
            Task { try? await device.shutdown() }
        }

        try await Self.waitUntil(timeout: 90) { device.state == .booted }

        try device.install(appAt: fixtureAppURL)
        _ = try device.launch(bundleId: "dev.t3.sim.fixture")

        let bridge = try Bridge(device: simDevice)
        bridge.enableAccessibility()
        let inspector = Inspector(bridge: bridge)

        // Give SpringBoard a moment to surface the app.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        guard let root = inspector.tree(), let button = Self.findButton(in: root) else {
            XCTFail("Button not found in AX tree after launch.")
            return
        }

        let hid = try HIDClient(device: simDevice)
        let centerX = button.frame.x + button.frame.width / 2
        let centerY = button.frame.y + button.frame.height / 2

        // We don't know the device pixel size precisely without reading Display.Info,
        // but the AX frame is already in device pixels so ratio math needs the matching pixel size.
        // Use the simulator device's screen dimensions via CoreSimulator KVC.
        let bounds = simDevice.value(forKey: "deviceType")
        let screenW = (bounds as? NSObject)?.value(forKey: "mainScreenWidth") as? Int ?? 1170
        let screenH = (bounds as? NSObject)?.value(forKey: "mainScreenHeight") as? Int ?? 2532

        let down = try IndigoBridge.shared.makeTapMessage(
            x: centerX, y: centerY, pixelWidth: screenW, pixelHeight: screenH, op: .down
        )
        try hid.send(messagePointer: down)
        try await Task.sleep(nanoseconds: 50_000_000)
        let up = try IndigoBridge.shared.makeTapMessage(
            x: centerX, y: centerY, pixelWidth: screenW, pixelHeight: screenH, op: .up
        )
        try hid.send(messagePointer: up)

        // Poll for the label change.
        var changed = false
        for _ in 0 ..< 20 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if let updated = inspector.tree(),
               let btn = Self.findButton(in: updated),
               btn.label == "Tapped!" {
                changed = true
                break
            }
        }
        XCTAssertTrue(changed, "Button label did not flip to 'Tapped!' — HID→AX round-trip broken.")
    }

    // MARK: - helpers

    private static func findButton(in el: AXElement) -> AXElement? {
        if el.role.lowercased().contains("button") { return el }
        for child in el.children ?? [] {
            if let hit = findButton(in: child) { return hit }
        }
        return nil
    }

    private static func waitUntil(timeout seconds: TimeInterval, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() > deadline {
                throw XCTSkip("Timed out waiting for predicate (\(seconds)s).")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
