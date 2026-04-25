import Foundation

/// Resolves an AX hit chain (leaf → root) into a ranked list of
/// `AXSourceHint`. Pipeline, in order of decreasing confidence:
///   1. **Direct hit** — the leaf carries an `.inspectable()` identifier
///      (`#fileID:#line[|module]`). Confidence ≈ 0.98.
///   2. **Ancestor hit** — the first non-leaf ancestor with an
///      `.inspectable()` identifier wins. Confidence ≈ 0.82.
/// No source hint is returned unless it came from the live hit chain.
public struct ResolvedSource: Equatable, Sendable {
    public let hints: [AXSourceHint]
    public let strategy: Strategy

    public enum Strategy: String, Codable, Sendable {
        case direct
        case ancestor
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
}
