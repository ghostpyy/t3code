import XCTest
@testable import SimBridge

final class BootMonitorTests: XCTestCase {
    func testStatusLabelMapping() {
        XCTAssertEqual(BootStatus.from(raw: 0).label, "Booting")
        XCTAssertEqual(BootStatus.from(raw: 1).label, "Waiting on backboard")
        XCTAssertEqual(BootStatus.from(raw: 2).label, "Waiting on data migration")
        XCTAssertEqual(BootStatus.from(raw: 3).label, "Data migration failed")
        XCTAssertEqual(BootStatus.from(raw: 4).label, "Waiting on system app")
        XCTAssertEqual(BootStatus.from(raw: 4_294_967_295).label, "Booted")
        XCTAssertEqual(BootStatus.from(raw: 99).label, "Unknown")
    }

    func testBootedSentinelMatchesCoreSimulatorHeader() {
        // SimDeviceBootInfoStatusFinished = NSUIntegerMax on 64-bit.
        XCTAssertEqual(BootStatus.from(raw: UInt64.max).label, "Unknown")
        XCTAssertEqual(BootStatus.from(raw: 4_294_967_295).label, "Booted")
    }
}
