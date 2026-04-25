import XCTest
@testable import SimBridge

final class AXFullSnapshotTests: XCTestCase {
    func testBFSPreservesParentIds() {
        let grandchild = make(id: "c", frame: frame(10, 10, 20, 20), children: nil)
        let child = make(id: "b", frame: frame(0, 0, 100, 100), children: [grandchild])
        let root = make(id: "a", frame: frame(0, 0, 390, 844), children: [child])

        let nodes = AXFullSnapshot.flatten(tree: root)
        XCTAssertEqual(nodes.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(nodes.map(\.parentId), [nil, "a", "b"])
    }

    func testDropsZeroAreaDescendantsButKeepsRoot() {
        let zero = make(id: "z", frame: frame(0, 0, 0, 0), children: nil)
        let root = make(id: "r", frame: frame(0, 0, 390, 844), children: [zero])
        let nodes = AXFullSnapshot.flatten(tree: root)
        XCTAssertEqual(nodes.map(\.id), ["r"])
    }

    func testOffscreenDescendantIsSkipped() {
        let offscreen = make(id: "o", frame: frame(-500, -500, 20, 20), children: nil)
        let root = make(id: "r", frame: frame(0, 0, 390, 844), children: [offscreen])
        let bounds = AXFrame(x: 0, y: 0, width: 390, height: 844)
        let nodes = AXFullSnapshot.flatten(tree: root, displayBounds: bounds)
        XCTAssertEqual(nodes.map(\.id), ["r"])
    }

    func testPropagatesParentSkipToChildren() {
        let grandchild = make(id: "c", frame: frame(10, 10, 20, 20), children: nil)
        let hiddenChild = make(id: "b", frame: frame(-500, -500, 0, 0), children: [grandchild])
        let root = make(id: "a", frame: frame(0, 0, 390, 844), children: [hiddenChild])
        let bounds = AXFrame(x: 0, y: 0, width: 390, height: 844)
        let nodes = AXFullSnapshot.flatten(tree: root, displayBounds: bounds)
        XCTAssertEqual(nodes.map(\.id), ["a", "c"])
        // grandchild's parent was dropped — it re-parents to "a".
        let grand = nodes.first { $0.id == "c" }
        XCTAssertEqual(grand?.parentId, "a")
    }

    // MARK: helpers

    private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AXFrame {
        AXFrame(x: x, y: y, width: w, height: h)
    }

    private func make(
        id: String,
        frame: AXFrame,
        children: [AXElement]?,
        identifier: String? = nil
    ) -> AXElement {
        AXElement(
            id: id,
            role: "Element",
            label: nil,
            value: nil,
            frame: frame,
            identifier: identifier,
            enabled: true,
            selected: false,
            children: children
        )
    }
}
