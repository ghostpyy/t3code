import XCTest
@testable import SimBridge

/// Coverage for `Coordinator.resolveSnapshotNodes` — the plugin-first picker
/// behind `emitSnapshot`. Mirrors the regression already guarded for hits in
/// `HitChainResolutionTests`: on Xcode 26.2 without VoiceOver, AX returns a
/// single unhydrated root, and the snapshot must fall through to the plugin
/// nodes so `refreshPinFrames` can keep the user's pinned selection alive.
final class SnapshotResolutionTests: XCTestCase {
    private let bounds = AXFrame(x: 0, y: 0, width: 390, height: 844)

    // MARK: plugin-first regression coverage

    func testUnhydratedAxFallsThroughToPlugin() {
        let ax = [unhydrated(id: "ax-root")]
        let plugin = [
            root(id: "plugin-root"),
            inspectable(
                id: "plugin-leaf",
                frame: AXFrame(x: 50, y: 200, width: 80, height: 80),
                identifier: "Satira/Views/LibraryView.swift:1117"
            ),
        ]

        let resolved = Coordinator.resolveSnapshotNodes(ax: ax, plugin: plugin)

        XCTAssertEqual(resolved.nodes.map(\.id), ["plugin-root", "plugin-leaf"])
        XCTAssertEqual(resolved.label, "plugin-over-ax")
    }

    func testEmptyAxFallsThroughToPlugin() {
        let plugin = [
            root(id: "plugin-root"),
            inspectable(
                id: "plugin-leaf",
                frame: AXFrame(x: 50, y: 200, width: 80, height: 80),
                identifier: "Satira/Views/LibraryView.swift:1117"
            ),
        ]

        let resolved = Coordinator.resolveSnapshotNodes(ax: [], plugin: plugin)

        XCTAssertEqual(resolved.nodes.map(\.id), ["plugin-root", "plugin-leaf"])
        XCTAssertEqual(resolved.label, "plugin")
    }

    // MARK: AX-still-wins paths

    func testHydratedAxBeatsPlugin() {
        let ax = [
            element(id: "ax-leaf", role: "Button", label: "Buy",
                    frame: AXFrame(x: 50, y: 200, width: 80, height: 80)),
        ]
        let plugin = [
            inspectable(id: "plugin-leaf",
                        frame: AXFrame(x: 50, y: 200, width: 80, height: 80),
                        identifier: "Satira/Views/LibraryView.swift:1117"),
        ]

        let resolved = Coordinator.resolveSnapshotNodes(ax: ax, plugin: plugin)

        XCTAssertEqual(resolved.nodes.map(\.id), ["ax-leaf"])
        XCTAssertEqual(resolved.label, "ax")
    }

    func testHydratedAxWithoutPluginStaysAx() {
        let ax = [
            element(id: "ax-leaf", role: "Button", label: "Cancel",
                    frame: AXFrame(x: 50, y: 200, width: 60, height: 40)),
        ]

        let resolved = Coordinator.resolveSnapshotNodes(ax: ax, plugin: nil)

        XCTAssertEqual(resolved.nodes.map(\.id), ["ax-leaf"])
        XCTAssertEqual(resolved.label, "ax")
    }

    // MARK: degenerate paths

    func testUnhydratedAxAndNoPluginKeepsAxSoCallSiteCanCoerce() {
        let ax = [unhydrated(id: "ax-root")]

        let resolved = Coordinator.resolveSnapshotNodes(ax: ax, plugin: nil)

        XCTAssertEqual(resolved.nodes.map(\.id), ["ax-root"])
        XCTAssertEqual(resolved.label, "ax")
    }

    func testUnhydratedAxAndEmptyPluginArrayKeepsAx() {
        let ax = [unhydrated(id: "ax-root")]

        let resolved = Coordinator.resolveSnapshotNodes(ax: ax, plugin: [])

        XCTAssertEqual(resolved.nodes.map(\.id), ["ax-root"])
        XCTAssertEqual(resolved.label, "ax")
    }

    func testEverythingEmptyReturnsEmpty() {
        let resolved = Coordinator.resolveSnapshotNodes(ax: [], plugin: nil)

        XCTAssertTrue(resolved.nodes.isEmpty)
        XCTAssertEqual(resolved.label, "empty")
    }

    func testEmptyAxAndEmptyPluginReturnsEmpty() {
        let resolved = Coordinator.resolveSnapshotNodes(ax: [], plugin: [])

        XCTAssertTrue(resolved.nodes.isEmpty)
        XCTAssertEqual(resolved.label, "empty")
    }

    // MARK: helpers

    private func inspectable(
        id: String, frame: AXFrame, identifier: String
    ) -> AXNode {
        AXNode(
            id: id,
            parentId: "plugin-root",
            role: "Inspectable",
            label: nil,
            value: nil,
            identifier: identifier,
            frame: frame,
            enabled: true,
            selected: false
        )
    }

    private func root(id: String) -> AXNode {
        AXNode(
            id: id,
            parentId: nil,
            role: "Application",
            label: "Satira",
            value: nil,
            identifier: "com.example.satira",
            frame: bounds,
            enabled: true,
            selected: false
        )
    }

    private func element(
        id: String, role: String, label: String?, frame: AXFrame
    ) -> AXNode {
        AXNode(
            id: id,
            parentId: nil,
            role: role,
            label: label,
            value: nil,
            identifier: nil,
            frame: frame,
            enabled: true,
            selected: false
        )
    }

    private func unhydrated(id: String) -> AXNode {
        AXNode(
            id: id,
            parentId: nil,
            role: "AXUIElement",
            label: nil,
            value: nil,
            identifier: nil,
            frame: AXFrame(x: 0, y: 0, width: 0, height: 0),
            enabled: true,
            selected: false
        )
    }
}
