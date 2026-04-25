import XCTest
@testable import SimBridge
import CPrivate

final class ServiceContextTests: XCTestCase {
    func testDeviceDescriptorMapping() throws {
        let desc = DeviceInfo(
            udid: "00000000-0000-0000-0000-000000000000",
            name: "iPhone 16 Pro",
            runtime: "iOS 18.2",
            model: "iPhone17,1",
            state: .shutdown
        )
        XCTAssertEqual(desc.summary, "iPhone 16 Pro · iOS 18.2")
        XCTAssertEqual(desc.isBooted, false)
    }

    func testStateMappingFromRaw() {
        XCTAssertEqual(DeviceState.from(raw: 1), .shutdown)
        XCTAssertEqual(DeviceState.from(raw: 2), .booting)
        XCTAssertEqual(DeviceState.from(raw: 3), .booted)
        XCTAssertEqual(DeviceState.from(raw: 4), .shuttingDown)
        XCTAssertEqual(DeviceState.from(raw: 99), .unknown)
    }

    func testStateMappingPrefersStateString() {
        XCTAssertEqual(DeviceState.from(raw: 99, stateString: "Shutdown"), .shutdown)
        XCTAssertEqual(DeviceState.from(raw: 99, stateString: "Booted"), .booted)
    }
}
