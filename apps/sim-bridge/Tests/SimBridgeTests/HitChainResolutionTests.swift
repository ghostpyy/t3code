import XCTest
@testable import SimBridge

/// Coverage for `Coordinator.resolveHitChain` — the plugin-first picker
/// the bridge uses to merge in-app `InspectableServer` data with runtime AX.
/// The shape of these tests is what guards against the regression where AX
/// failures (Xcode 26.2 unhydrated chains without VoiceOver) caused the
/// bridge to silently discard perfectly-good plugin data and surface a
/// 48×48 "Unverified source" hitpoint.
final class HitChainResolutionTests: XCTestCase {
    private let display = AXFrame(x: 0, y: 0, width: 390, height: 844)

    // MARK: plugin-first regression coverage

    func testUnhydratedAxStillSurfacesPluginChain() {
        let plugin = [
            inspectable(
                id: "plugin-leaf",
                frame: AXFrame(x: 50, y: 200, width: 80, height: 80),
                identifier: "Satira/Views/LibraryView.swift:1117"
            ),
        ]
        let live = [unhydrated(id: "ax-stub")]

        let resolved = Coordinator.resolveHitChain(
            plugin: plugin,
            live: live,
            liveSource: "ax",
            hitX: 90,
            hitY: 240,
            display: display,
            appContext: nil
        )

        XCTAssertEqual(resolved.chain.map(\.id), ["plugin-leaf"])
        XCTAssertEqual(resolved.label, "plugin-over-ax")
    }

    func testEmptyAxStillSurfacesPluginChain() {
        let plugin = [
            inspectable(
                id: "plugin-leaf",
                frame: AXFrame(x: 50, y: 200, width: 80, height: 80),
                identifier: "Satira/Views/LibraryView.swift:1117"
            ),
        ]

        let resolved = Coordinator.resolveHitChain(
            plugin: plugin,
            live: [],
            liveSource: "none",
            hitX: 90,
            hitY: 240,
            display: display,
            appContext: nil
        )

        XCTAssertEqual(resolved.chain.map(\.id), ["plugin-leaf"])
        XCTAssertEqual(resolved.label, "plugin")
    }

    // MARK: AX-still-wins paths

    func testSpecificAxHitGetsPluginSourceAttached() {
        let pluginFrame = AXFrame(x: 50, y: 200, width: 80, height: 80)
        let plugin = [
            inspectable(
                id: "plugin-leaf",
                frame: pluginFrame,
                identifier: "Satira/Views/LibraryView.swift:1117"
            ),
        ]
        let live = [
            element(
                id: "ax-leaf",
                role: "Button",
                label: "Buy",
                frame: pluginFrame
            ),
        ]

        let resolved = Coordinator.resolveHitChain(
            plugin: plugin,
            live: live,
            liveSource: "ax",
            hitX: 90,
            hitY: 240,
            display: display,
            appContext: nil
        )

        XCTAssertEqual(resolved.chain.map(\.id), ["ax-leaf"])
        XCTAssertEqual(resolved.label, "ax+plugin-source")
        // The plugin's source identifier should be merged in via sourceHints.
        let leafHints = resolved.chain.first?.sourceHints ?? []
        XCTAssertEqual(leafHints.first?.line, 1117)
    }

    func testSpecificAxHitWithoutPluginKeepsLiveLabel() {
        let live = [
            element(
                id: "ax-leaf",
                role: "Button",
                label: "Cancel",
                frame: AXFrame(x: 100, y: 200, width: 60, height: 40)
            ),
        ]

        let resolved = Coordinator.resolveHitChain(
            plugin: [],
            live: live,
            liveSource: "ax",
            hitX: 130,
            hitY: 220,
            display: display,
            appContext: nil
        )

        XCTAssertEqual(resolved.chain.map(\.id), ["ax-leaf"])
        XCTAssertEqual(resolved.label, "ax")
    }

    // MARK: degenerate paths

    func testUnhydratedAxAndNoPluginReturnsLiveSoCallSiteCanCoerceHitpoint() {
        let live = [unhydrated(id: "ax-stub")]
        let resolved = Coordinator.resolveHitChain(
            plugin: [],
            live: live,
            liveSource: "ax",
            hitX: 0,
            hitY: 0,
            display: display,
            appContext: nil
        )

        XCTAssertEqual(resolved.chain.map(\.id), ["ax-stub"])
        XCTAssertEqual(resolved.label, "ax")
    }

    func testEverythingEmptyReturnsEmpty() {
        let resolved = Coordinator.resolveHitChain(
            plugin: [],
            live: [],
            liveSource: "none",
            hitX: 0,
            hitY: 0,
            display: display,
            appContext: nil
        )

        XCTAssertTrue(resolved.chain.isEmpty)
        XCTAssertEqual(resolved.label, "empty")
    }

    func testLegacyFallbackPicksUpPluginOver() {
        let plugin = [
            inspectable(
                id: "plugin-leaf",
                frame: AXFrame(x: 50, y: 200, width: 80, height: 80),
                identifier: "Satira/Views/LibraryView.swift:1117"
            ),
        ]
        let live = [unhydrated(id: "legacy-stub")]

        let resolved = Coordinator.resolveHitChain(
            plugin: plugin,
            live: live,
            liveSource: "legacy",
            hitX: 90,
            hitY: 240,
            display: display,
            appContext: nil
        )

        XCTAssertEqual(resolved.chain.map(\.id), ["plugin-leaf"])
        XCTAssertEqual(resolved.label, "plugin-over-legacy")
    }

    // MARK: helpers

    private func inspectable(
        id: String, frame: AXFrame, identifier: String
    ) -> AXElement {
        AXElement(
            id: id,
            role: "Inspectable",
            label: nil,
            value: nil,
            frame: frame,
            identifier: identifier,
            enabled: true,
            selected: false,
            children: nil
        )
    }

    private func element(
        id: String, role: String, label: String?, frame: AXFrame
    ) -> AXElement {
        AXElement(
            id: id,
            role: role,
            label: label,
            value: nil,
            frame: frame,
            identifier: nil,
            enabled: true,
            selected: false,
            children: nil
        )
    }

    private func unhydrated(id: String) -> AXElement {
        AXElement(
            id: id,
            role: "AXUIElement",
            label: nil,
            value: nil,
            frame: AXFrame(x: 0, y: 0, width: 0, height: 0),
            identifier: nil,
            enabled: true,
            selected: false,
            children: nil
        )
    }
}
