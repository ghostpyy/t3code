import Foundation

/// Resolves an AX hit chain (leaf → root) into a ranked list of
/// `AXSourceHint`. Pipeline, in order of decreasing confidence:
///   1. **Direct hit** — the leaf carries an `.inspectable()` identifier
///      (`#fileID:#line[|module]`). Confidence ≈ 0.98.
///   2. **Ancestor hit** — the first non-leaf ancestor with an
///      `.inspectable()` identifier wins. Confidence ≈ 0.82.
///   3. **Semantic fallback** — grep visible labels/values across the
///      indexed project sources, score each file, return top-N.
///      Capped at 0.55 confidence so the UI can visually distinguish
///      "we guessed" from "we know".
public struct ResolvedSource: Equatable, Sendable {
    public let hints: [AXSourceHint]
    public let strategy: Strategy

    public enum Strategy: String, Codable, Sendable {
        case direct
        case ancestor
        case semantic
        case empty
    }
}

enum SourceResolver {
    static func resolve(
        chain: [AXElement],
        appContext: SimAppInfo?
    ) -> ResolvedSource {
        if let direct = directHit(chain: chain, appContext: appContext) {
            return ResolvedSource(hints: [direct], strategy: .direct)
        }
        if let ancestor = ancestorHit(chain: chain, appContext: appContext) {
            return ResolvedSource(hints: [ancestor], strategy: .ancestor)
        }
        let semantic = semanticHits(chain: chain, appContext: appContext)
        if !semantic.isEmpty {
            return ResolvedSource(hints: semantic, strategy: .semantic)
        }
        return ResolvedSource(hints: [], strategy: .empty)
    }

    // MARK: - inspectable-identifier path

    private static func directHit(
        chain: [AXElement], appContext: SimAppInfo?
    ) -> AXSourceHint? {
        guard let leaf = chain.first,
              let parsed = AXIdentifier.parse(leaf.identifier) else { return nil }
        return hint(
            for: parsed,
            appContext: appContext,
            confidence: 0.98,
            reason: ".inspectable() — direct hit"
        )
    }

    private static func ancestorHit(
        chain: [AXElement], appContext: SimAppInfo?
    ) -> AXSourceHint? {
        for (index, element) in chain.enumerated() where index > 0 {
            guard let parsed = AXIdentifier.parse(element.identifier) else { continue }
            return hint(
                for: parsed,
                appContext: appContext,
                confidence: 0.82,
                reason: ".inspectable() — ancestor (\(element.role))"
            )
        }
        return nil
    }

    private static func hint(
        for parsed: AXIdentifier.Location,
        appContext: SimAppInfo?,
        confidence: Double,
        reason: String
    ) -> AXSourceHint {
        let resolved = resolveAbsolute(parsed: parsed, appContext: appContext)
        let absolute = resolved ?? parsed.fileID
        let snippet = resolved.flatMap {
            SourceIndex.shared.snippet(at: $0, line: parsed.line)
        }
        return AXSourceHint(
            absolutePath: absolute,
            line: parsed.line,
            reason: reason,
            confidence: confidence,
            snippet: snippet?.text,
            snippetStartLine: snippet?.startLine
        )
    }

    private static func resolveAbsolute(
        parsed: AXIdentifier.Location, appContext: SimAppInfo?
    ) -> String? {
        guard let appContext, let root = appContext.projectPath else { return nil }
        SourceIndex.shared.ensureIndexed(root: root)
        return SourceIndex.shared.resolveByFilename(
            parsed.file, module: parsed.module, in: root
        )
    }

    // MARK: - semantic fallback

    private struct Evidence {
        let text: String
        let lowercased: String
        let weight: Double
    }

    private struct FileScore {
        let path: String
        let line: Int
        let score: Double
        let matched: [String]
    }

    private static func semanticHits(
        chain: [AXElement], appContext: SimAppInfo?
    ) -> [AXSourceHint] {
        guard let appContext, let root = appContext.projectPath else { return [] }
        SourceIndex.shared.ensureIndexed(root: root)
        let evidence = buildEvidence(chain: chain)
        guard !evidence.isEmpty else { return [] }
        let entries = SourceIndex.shared.files(in: root)
        guard !entries.isEmpty else { return [] }

        let preferredModules = preferredModuleNames(
            chain: chain, appContext: appContext
        )
        let scored = entries.compactMap {
            score(file: $0, evidence: evidence, preferredModules: preferredModules)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.path < rhs.path }
            return lhs.score > rhs.score
        }

        guard let bestScore = scored.first?.score, bestScore > 0 else { return [] }
        return scored.prefix(3).map { hit in
            let ratio = hit.score / (bestScore + 1)
            let confidence = min(0.55, max(0.2, ratio * 0.55))
            let snippet = SourceIndex.shared.snippet(at: hit.path, line: hit.line)
            return AXSourceHint(
                absolutePath: hit.path,
                line: hit.line,
                reason: "semantic: \(hit.matched.prefix(3).joined(separator: ", "))",
                confidence: confidence,
                snippet: snippet?.text,
                snippetStartLine: snippet?.startLine
            )
        }
    }

    private static func buildEvidence(chain: [AXElement]) -> [Evidence] {
        var seen = Set<String>()
        var out: [Evidence] = []
        for (index, element) in chain.enumerated() {
            let base = max(3.0, 11.0 - Double(index) * 1.7)
            for candidate in [element.label, element.value] {
                guard let text = normalize(candidate) else { continue }
                let lower = text.lowercased()
                guard seen.insert(lower).inserted else { continue }
                out.append(Evidence(
                    text: text,
                    lowercased: lower,
                    weight: base + min(Double(text.count) / 12.0, 4.0)
                ))
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.weight == rhs.weight { return lhs.text < rhs.text }
            return lhs.weight > rhs.weight
        }
    }

    private static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(
                of: #"\s+"#, with: " ", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count >= 2, collapsed.count <= 80 else { return nil }
        let lowered = collapsed.lowercased()
        let rejected = [
            "axuielement", "element", "button", "image", "text", "view", "group"
        ]
        if rejected.contains(lowered) { return nil }
        guard collapsed.rangeOfCharacter(from: .letters) != nil else { return nil }
        return collapsed
    }

    private static func score(
        file: SourceIndex.FileEntry,
        evidence: [Evidence],
        preferredModules: [String]
    ) -> FileScore? {
        var total = 0.0
        var lineScores: [Int: Double] = [:]
        var matched: [String] = []

        for item in evidence {
            var hit = false
            for (idx, line) in file.lowercasedLines.enumerated()
            where line.contains(item.lowercased) {
                lineScores[idx + 1, default: 0] += item.weight
                hit = true
            }
            if hit {
                matched.append(item.text)
                total += item.weight
            }
        }

        guard !matched.isEmpty, let line = bestLine(lineScores) else { return nil }

        if file.path.contains("/Views/") { total += 10 }
        if file.path.contains("/Views/Components/") { total += 6 }
        if file.path.contains("/Models/") {
            total -= matched.count > 1 ? 8 : 16
        }
        if file.path.contains("/Preview") || file.path.contains("/Previews/") {
            total -= 18
        }
        for module in preferredModules {
            if file.path.contains("/Sources/\(module)/Views/") {
                total += 18; break
            }
            if file.path.contains("/\(module)/Views/") {
                total += 14; break
            }
            if file.path.contains("/Sources/\(module)/")
                || file.path.contains("/\(module)/") {
                total += 8; break
            }
        }
        if matched.count > 1 { total += Double(matched.count * 5) }

        return FileScore(
            path: file.path, line: line, score: total, matched: matched
        )
    }

    private static func bestLine(_ scores: [Int: Double]) -> Int? {
        scores.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
    }

    private static func preferredModuleNames(
        chain: [AXElement], appContext: SimAppInfo
    ) -> [String] {
        var ordered: [String] = []
        func push(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ordered.contains(trimmed) else { return }
            ordered.append(trimmed)
        }
        for element in chain {
            push(AXIdentifier.parse(element.identifier)?.module)
        }
        push(appContext.bundleId.split(separator: ".").last
            .map(String.init)
            .map(capitalizeModule))
        push(appContext.name.map(capitalizeModule))
        push(capitalizeModule(URL(
            fileURLWithPath: appContext.projectPath ?? ""
        ).lastPathComponent))
        return ordered
    }

    private static func capitalizeModule(_ value: String) -> String {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { segment in
                let lower = segment.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined()
    }
}
