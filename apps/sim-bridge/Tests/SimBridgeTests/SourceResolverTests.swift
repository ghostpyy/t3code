import XCTest
@testable import SimBridge

final class SourceResolverTests: XCTestCase {
    func testDirectHitFromInspectableIdentifier() {
        let leaf = make(
            id: "1", role: "Button", label: "Buy",
            identifier: "Satira/Views/Home.swift:42|Satira"
        )
        let resolved = SourceResolver.resolve(chain: [leaf], appContext: nil)
        XCTAssertEqual(resolved.strategy, .direct)
        XCTAssertEqual(resolved.hints.count, 1)
        XCTAssertEqual(resolved.hints.first?.line, 42)
        XCTAssertEqual(resolved.hints.first?.absolutePath, "Satira/Views/Home.swift")
        XCTAssertEqual(resolved.hints.first?.confidence ?? 0, 0.98, accuracy: 0.001)
    }

    func testAncestorHitWhenLeafHasNoIdentifier() {
        let leaf = make(id: "1", role: "Text", identifier: nil)
        let ancestor = make(
            id: "2", role: "VStack",
            identifier: "Satira/Views/Home.swift:10|Satira"
        )
        let resolved = SourceResolver.resolve(
            chain: [leaf, ancestor], appContext: nil
        )
        XCTAssertEqual(resolved.strategy, .ancestor)
        XCTAssertEqual(resolved.hints.first?.line, 10)
        XCTAssertEqual(
            resolved.hints.first?.confidence ?? 0, 0.82, accuracy: 0.001
        )
    }

    func testEmptyWhenNothingToResolve() {
        let leaf = make(id: "1", role: "Element", identifier: nil)
        let resolved = SourceResolver.resolve(chain: [leaf], appContext: nil)
        XCTAssertEqual(resolved.strategy, .empty)
        XCTAssertTrue(resolved.hints.isEmpty)
    }

    func testIdentifierRegexRejectsNonSwiftStrings() {
        let leaf = make(id: "1", role: "Button", identifier: "btn-foo")
        let resolved = SourceResolver.resolve(chain: [leaf], appContext: nil)
        XCTAssertEqual(resolved.strategy, .empty)
    }

    func testDoesNotGuessFromVisibleText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("LibraryView.swift")
        try #"Text("The house")"#.write(to: source, atomically: true, encoding: .utf8)
        let app = SimAppInfo(
            bundleId: "com.example.Satira",
            name: "Satira",
            pid: Int32(99),
            bundlePath: nil,
            dataContainer: nil,
            executablePath: nil,
            projectPath: root.path
        )
        let leaf = make(id: "1", role: "Text", label: "The house", identifier: nil)
        let resolved = SourceResolver.resolve(chain: [leaf], appContext: app)
        XCTAssertEqual(resolved.strategy, .empty)
        XCTAssertTrue(resolved.hints.isEmpty)
    }

    func testDirectHitPopulatesSnippetWhenProjectIsIndexed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let module = root.appendingPathComponent("Satira/Views")
        try FileManager.default.createDirectory(
            at: module, withIntermediateDirectories: true
        )
        let source = module.appendingPathComponent("Home.swift")
        try """
        // 1
        // 2
        // 3
        // 4
        struct Home: View {
            var body: some View { Text("Hello") }
        }
        // 8
        """.write(to: source, atomically: true, encoding: .utf8)

        let app = SimAppInfo(
            bundleId: "com.example.Satira",
            name: "Satira",
            pid: Int32(99),
            bundlePath: nil,
            dataContainer: nil,
            executablePath: nil,
            projectPath: root.path
        )
        let leaf = make(
            id: "1",
            role: "Button",
            identifier: "Satira/Views/Home.swift:5|Satira"
        )
        let resolved = SourceResolver.resolve(chain: [leaf], appContext: app)
        XCTAssertEqual(resolved.strategy, .direct)
        let hint = try XCTUnwrap(resolved.hints.first)
        XCTAssertEqual(hint.line, 5)
        XCTAssertNotNil(hint.snippet)
        XCTAssertEqual(hint.snippetStartLine, 1)
        XCTAssertTrue(hint.snippet?.contains("struct Home: View {") ?? false)
    }

    // MARK: helpers

    private func make(
        id: String,
        role: String,
        label: String? = nil,
        identifier: String?,
        frame: AXFrame = AXFrame(x: 0, y: 0, width: 100, height: 40)
    ) -> AXElement {
        AXElement(
            id: id,
            role: role,
            label: label,
            value: nil,
            frame: frame,
            identifier: identifier,
            enabled: true,
            selected: false,
            children: nil
        )
    }
}
