import XCTest
@testable import SimBridge

final class HitChainNormalizationTests: XCTestCase {
    func testPluginDisplayPointChainIsNotLocalized() {
        let info = Display.Info(pixelWidth: 1206, pixelHeight: 2622, scale: 3)
        let chain = [
            make(
                id: "cover",
                frame: AXFrame(x: 126, y: 224, width: 150, height: 218),
                identifier: "Satira/LibraryView.swift:435"
            ),
            make(
                id: "root",
                frame: AXFrame(x: 0, y: 62, width: 402, height: 1466),
                identifier: "Satira/LibraryView.swift:76"
            ),
        ]

        let normalized = Coordinator.normalizeHitChain(
            chain,
            hitX: 200,
            hitY: 335,
            info: info,
            alreadyDisplayPoints: true
        )

        XCTAssertEqual(normalized.first?.frame.y, 224)
    }

    func testUnknownCoordinateChainMayBeLocalized() {
        let info = Display.Info(pixelWidth: 1206, pixelHeight: 2622, scale: 3)
        let chain = [
            make(
                id: "cover",
                frame: AXFrame(x: 126, y: 224, width: 150, height: 218),
                identifier: "Satira/LibraryView.swift:435"
            ),
            make(
                id: "root",
                frame: AXFrame(x: 0, y: 62, width: 402, height: 1466),
                identifier: "Satira/LibraryView.swift:76"
            ),
        ]

        let normalized = Coordinator.normalizeHitChain(
            chain,
            hitX: 200,
            hitY: 335,
            info: info
        )

        XCTAssertEqual(normalized.first?.frame.y, 162)
    }

    private func make(id: String, frame: AXFrame, identifier: String) -> AXElement {
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
}
