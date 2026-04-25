import XCTest
@testable import SimBridge

final class AXIdentifierParseTests: XCTestCase {
    func testSimple() {
        let loc = AXIdentifier.parse("HomeView.swift:42")
        XCTAssertEqual(loc?.file, "HomeView.swift")
        XCTAssertEqual(loc?.line, 42)
        XCTAssertNil(loc?.kind)
        XCTAssertNil(loc?.name)
    }

    func testPipeDelimited() {
        let loc = AXIdentifier.parse("HomeView.swift:42|kind=button|name=buyNow")
        XCTAssertEqual(loc?.file, "HomeView.swift")
        XCTAssertEqual(loc?.line, 42)
        XCTAssertEqual(loc?.kind, "button")
        XCTAssertEqual(loc?.name, "buyNow")
    }

    func testArbitrary() {
        XCTAssertNil(AXIdentifier.parse("some-other-string"))
        XCTAssertNil(AXIdentifier.parse(""))
        XCTAssertNil(AXIdentifier.parse(nil))
    }
}
