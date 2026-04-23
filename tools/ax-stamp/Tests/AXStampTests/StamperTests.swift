import XCTest
@testable import AXStampKit

final class StamperTests: XCTestCase {
    func testFixtures() throws {
        let fixtures = try FixtureLoader.load()
        for fixture in fixtures {
            let (output, _) = Stamper.rewrite(source: fixture.input)
            XCTAssertEqual(
                output,
                fixture.expected,
                "fixture \(fixture.name) did not match expected output\n\nGOT:\n\(output)\n\nEXPECTED:\n\(fixture.expected)"
            )
        }
    }

    func testIdempotence() throws {
        let fixtures = try FixtureLoader.load()
        for fixture in fixtures {
            let (pass1, stamps1) = Stamper.rewrite(source: fixture.input)
            let (pass2, stamps2) = Stamper.rewrite(source: pass1)
            XCTAssertEqual(pass1, pass2, "fixture \(fixture.name) not idempotent")
            XCTAssertEqual(stamps2, 0, "fixture \(fixture.name) re-stamped on pass 2")
            _ = stamps1
        }
    }

    func testAlreadyStampedIsUnchanged() throws {
        let src = """
        import SwiftUI
        struct X: View {
            var body: some View {
                Text("a").inspectable()
            }
        }
        """
        let (out, stamps) = Stamper.rewrite(source: src)
        XCTAssertEqual(out, src)
        XCTAssertEqual(stamps, 0)
    }
}

enum FixtureLoader {
    struct Fixture {
        let name: String
        let input: String
        let expected: String
    }

    static func load() throws -> [Fixture] {
        let fm = FileManager.default
        let base = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let inputDir = base.appendingPathComponent("input")
        let expectedDir = base.appendingPathComponent("expected")
        let inputs = try fm.contentsOfDirectory(atPath: inputDir.path).sorted()
        return try inputs.map { filename in
            let input = try String(contentsOf: inputDir.appendingPathComponent(filename), encoding: .utf8)
            let expected = try String(contentsOf: expectedDir.appendingPathComponent(filename), encoding: .utf8)
            return Fixture(name: filename, input: input, expected: expected)
        }
    }
}
