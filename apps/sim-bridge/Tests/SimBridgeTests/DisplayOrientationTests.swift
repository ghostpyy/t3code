import XCTest
@testable import SimBridge

final class DisplayOrientationTests: XCTestCase {
    func testLandscapeSurfaceOverridesStalePortraitRequest() {
        let info = Display.Info(pixelWidth: 2556, pixelHeight: 1179, scale: 3)
        XCTAssertEqual(Coordinator.displayOrientation(requested: 1, info: info), 4)
    }

    func testPortraitSurfaceRestoresPortraitRequest() {
        let info = Display.Info(pixelWidth: 1179, pixelHeight: 2556, scale: 3)
        XCTAssertEqual(Coordinator.displayOrientation(requested: 1, info: info), 1)
    }

    func testExplicitLandscapeRequestSurvivesPortraitSurface() {
        let info = Display.Info(pixelWidth: 1179, pixelHeight: 2556, scale: 3)
        XCTAssertEqual(Coordinator.displayOrientation(requested: 4, info: info), 4)
    }

    func testDisplayBoundsUseEffectiveLandscapeOrientation() {
        let info = Display.Info(pixelWidth: 1170, pixelHeight: 2532, scale: 3)
        let bounds = Coordinator.displayBounds(info, orientation: 4)
        XCTAssertEqual(bounds?.width, 844)
        XCTAssertEqual(bounds?.height, 390)
    }

    func testDisplayBoundsInferLandscapeSurfaceWhenOrientationMissing() {
        let info = Display.Info(pixelWidth: 2532, pixelHeight: 1170, scale: 3)
        let bounds = Coordinator.displayBounds(info)
        XCTAssertEqual(bounds?.width, 844)
        XCTAssertEqual(bounds?.height, 390)
    }
}
