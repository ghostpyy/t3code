import XCTest
@testable import SimBridge

final class SourceIndexTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-source-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
    }

    func testIndexesSwiftFilesInRoot() throws {
        try write("Views/HomeView.swift", """
        import SwiftUI
        struct HomeView: View { var body: some View { Text("Hello") } }
        """)
        try write("Models/Item.swift", "struct Item {}")

        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let files = SourceIndex.shared.files(in: rootURL.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains { $0.filename == "HomeView.swift" })
        XCTAssertTrue(files.contains { $0.filename == "Item.swift" })
    }

    func testSkipsBuildAndPodsDirectories() throws {
        try write(".build/artifacts/Junk.swift", "// skipped")
        try write("Pods/Dep/Other.swift", "// skipped")
        try write("Good.swift", "// kept")

        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let files = SourceIndex.shared.files(in: rootURL.path)
        XCTAssertEqual(files.map(\.filename).sorted(), ["Good.swift"])
    }

    func testResolveByFilenameSingleMatch() throws {
        try write("Views/Home.swift", "// a")
        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let resolved = SourceIndex.shared.resolveByFilename(
            "Home.swift", module: nil, in: rootURL.path
        )
        XCTAssertEqual(resolved, rootURL.appendingPathComponent("Views/Home.swift")
            .standardized.path)
    }

    func testResolveByFilenamePrefersModuleDirectory() throws {
        try write("SatiraA/Home.swift", "// a")
        try write("SatiraB/Home.swift", "// b")
        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let resolved = SourceIndex.shared.resolveByFilename(
            "Home.swift", module: "SatiraB", in: rootURL.path
        )
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.contains("/SatiraB/"))
    }

    func testSearchFindsSubstring() throws {
        try write("Views/Home.swift", """
        struct Home {
            let title = "Buy now"
        }
        """)
        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let hits = SourceIndex.shared.search(token: "Buy now", in: rootURL.path)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.line, 2)
    }

    func testSnippetReturnsCenteredNeighborhood() throws {
        try write("Views/Home.swift", """
        // 1
        // 2
        // 3
        // 4
        // 5
        struct Home: View {
            var body: some View { Text("Hi") }
        }
        // 9
        // 10
        """)
        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let absolute = rootURL.appendingPathComponent("Views/Home.swift").standardized.path
        let snippet = SourceIndex.shared.snippet(at: absolute, line: 6, context: 2)
        XCTAssertNotNil(snippet)
        XCTAssertEqual(snippet?.startLine, 4)
        XCTAssertEqual(snippet?.text.components(separatedBy: "\n").count, 5)
        XCTAssertTrue(snippet?.text.contains("struct Home: View {") ?? false)
    }

    func testSnippetClampsToFileBounds() throws {
        try write("Views/Top.swift", """
        struct Top {}
        """)
        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let absolute = rootURL.appendingPathComponent("Views/Top.swift").standardized.path
        let snippet = SourceIndex.shared.snippet(at: absolute, line: 1, context: 6)
        XCTAssertEqual(snippet?.startLine, 1)
        XCTAssertEqual(snippet?.text, "struct Top {}")
    }

    func testSnippetReturnsNilForOutOfRangeLine() throws {
        try write("Views/Short.swift", "struct S {}")
        SourceIndex.shared.ensureIndexed(root: rootURL.path)
        let absolute = rootURL.appendingPathComponent("Views/Short.swift").standardized.path
        XCTAssertNil(SourceIndex.shared.snippet(at: absolute, line: 99, context: 3))
    }

    // MARK: helpers

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
