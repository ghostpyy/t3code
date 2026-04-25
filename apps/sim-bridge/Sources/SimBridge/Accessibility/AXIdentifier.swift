import Foundation

/// Canonical parser for the accessibility identifier format emitted by the
/// SwiftUI `.inspectable()` extension. The baseline shape is
/// `<#fileID>:<#line>`, with optional pipe-delimited metadata segments —
/// either `key=value` pairs or a single module shortcut:
///
///   HomeView.swift:42
///   Module/Views/HomeView.swift:42|Module
///   Module/Views/HomeView.swift:42|kind=button|name=buyNow
///
/// Returns nil for anything that does not begin with a `.swift:<digits>`
/// locator so callers can safely pass raw AX identifiers from UIKit or
/// UIAccessibility sources and get a fast rejection.
public enum AXIdentifier {
    public struct Location: Equatable, Sendable {
        public let file: String
        public let fileID: String
        public let line: Int
        public let module: String?
        public let kind: String?
        public let name: String?

        public init(
            file: String,
            fileID: String,
            line: Int,
            module: String?,
            kind: String?,
            name: String?
        ) {
            self.file = file
            self.fileID = fileID
            self.line = line
            self.module = module
            self.kind = kind
            self.name = name
        }
    }

    public static func parse(_ identifier: String?) -> Location? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let parts = identifier.split(
            separator: "|", omittingEmptySubsequences: false
        )
        let head = parts.first.map(String.init) ?? ""
        guard head.range(
            of: #".+\.swift:\d+$"#, options: .regularExpression
        ) != nil else { return nil }
        guard let colon = head.lastIndex(of: ":"),
              let line = Int(head[head.index(after: colon)...])
        else { return nil }
        let fileID = String(head[..<colon])
        let filename = (fileID as NSString).lastPathComponent

        var module: String?
        var kind: String?
        var name: String?
        for segment in parts.dropFirst() {
            let text = segment.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let eq = text.firstIndex(of: "=") {
                let key = String(text[..<eq])
                let value = String(text[text.index(after: eq)...])
                switch key {
                case "module": module = value
                case "kind":   kind = value
                case "name":   name = value
                default: break
                }
            } else if module == nil {
                module = text
            }
        }

        let moduleFromFileID: String? = {
            let segments = fileID.split(separator: "/")
            return segments.count >= 2 ? String(segments[0]) : nil
        }()

        return Location(
            file: filename,
            fileID: fileID,
            line: line,
            module: module ?? moduleFromFileID,
            kind: kind,
            name: name
        )
    }
}
