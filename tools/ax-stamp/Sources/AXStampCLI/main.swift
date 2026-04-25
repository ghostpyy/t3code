import ArgumentParser
import Foundation
import AXStampKit

@main
struct AXStampCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax-stamp",
        abstract: "Stamp SwiftUI views with .inspectable() modifiers.",
        discussion: """
        Walks every *.swift file under --project recursively, finds SwiftUI
        declarations that return `some View`, and wraps each terminal view
        expression with a trailing .inspectable() call (which depends on a
        `View.inspectable(...)` extension at the call site that captures
        #fileID and #line as an accessibilityIdentifier).

        Idempotent: running twice on the same input produces byte-identical
        output. Trivia-preserving: comments, spacing, and blank lines stay
        exactly where they were.

        Pass --strip to remove generated .inspectable(...) calls instead.
        """
    )

    @Option(name: .long, help: "Root directory to scan (recursive).")
    var project: String

    @Flag(name: .long, help: "Exit 1 if any file would change; don't write anything.")
    var check: Bool = false

    @Flag(name: .long, help: "Remove .inspectable(...) modifiers instead of adding them.")
    var strip: Bool = false

    @Flag(name: .long, help: "Print one line per stamped file.")
    var verbose: Bool = false

    mutating func run() throws {
        let root = URL(fileURLWithPath: project, isDirectory: true)
        let files = try enumerateSwiftFiles(under: root)

        var rewrittenCount = 0
        var stampTotal = 0
        var wouldChange: [String] = []

        for url in files {
            if check {
                let unchanged = try strip ? Stamper.checkStripFile(at: url) : Stamper.checkFile(at: url)
                if !unchanged { wouldChange.append(url.path) }
                continue
            }

            let outcome = try strip ? Stamper.stripFile(at: url) : Stamper.rewriteFile(at: url)
            switch outcome {
            case .unchanged: break
            case .rewrote(let count):
                rewrittenCount += 1
                stampTotal += count
                if verbose {
                    let sign = strip ? "-" : "+"
                    FileHandle.standardError.write(Data("ax-stamp: \(sign)\(count) \(url.path)\n".utf8))
                }
            }
        }

        if check {
            if !wouldChange.isEmpty {
                for p in wouldChange {
                    FileHandle.standardError.write(Data("ax-stamp: would rewrite \(p)\n".utf8))
                }
                throw ExitCode(1)
            }
            return
        }

        if verbose || rewrittenCount > 0 {
            let action = strip ? "removed" : "added"
            FileHandle.standardError.write(Data(
                "ax-stamp: rewrote \(rewrittenCount) file(s) · \(action) \(stampTotal) stamp(s)\n".utf8
            ))
        }
    }

    private func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/.build/") || path.contains("/DerivedData/")
                || path.contains("/Pods/") || path.contains("/xcuserdata/")
                || path.hasSuffix("+Generated.swift") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                results.append(url)
            }
        }
        return results
    }
}
