import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftParser

public enum StampOutcome: Equatable {
    case unchanged
    case rewrote(stampCount: Int)
}

public enum Stamper {
    /// Rewrite the source so every top-level view expression inside a
    /// `var body: some View { ... }` is wrapped with a trailing `.inspectable()`
    /// call. Idempotent: running twice on the same input produces byte-identical
    /// output. Trivia-preserving.
    public static func rewrite(source: String) -> (output: String, stamps: Int) {
        let tree = Parser.parse(source: source)
        let rewriter = InspectableRewriter()
        let newTree = rewriter.rewrite(tree)
        return (newTree.description, rewriter.stampCount)
    }

    public static func rewriteFile(at url: URL) throws -> StampOutcome {
        let data = try Data(contentsOf: url)
        guard let input = String(data: data, encoding: .utf8) else {
            throw StamperError.notUTF8(url.path)
        }
        let (output, stamps) = rewrite(source: input)
        if output == input { return .unchanged }
        try output.data(using: .utf8)!.write(to: url, options: [.atomic])
        return .rewrote(stampCount: stamps)
    }

    public static func checkFile(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard let input = String(data: data, encoding: .utf8) else {
            throw StamperError.notUTF8(url.path)
        }
        let (output, _) = rewrite(source: input)
        return output == input
    }
}

public enum StamperError: Error, CustomStringConvertible {
    case notUTF8(String)
    public var description: String {
        switch self {
        case .notUTF8(let path): return "not UTF-8: \(path)"
        }
    }
}

/// SyntaxRewriter that finds `var body: some View { ... }` properties and wraps
/// every terminal view expression with `.inspectable()`.
final class InspectableRewriter: SyntaxRewriter {
    fileprivate(set) var stampCount: Int = 0

    override func visit(_ node: PatternBindingSyntax) -> PatternBindingSyntax {
        guard
            node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body",
            isSomeView(node.typeAnnotation?.type),
            let accessor = node.accessorBlock
        else {
            return super.visit(node)
        }

        switch accessor.accessors {
        case .getter(let stmts):
            let rewritten = CodeBlockItemListSyntax(stmts.map(stampTopLevelItem))
            let newAccessor = accessor.with(\.accessors, .getter(rewritten))
            return node.with(\.accessorBlock, newAccessor)

        case .accessors(let accessorDeclList):
            // Computed property with explicit `get { ... }` accessor
            let rewrittenAccessors = AccessorDeclListSyntax(accessorDeclList.map { decl -> AccessorDeclSyntax in
                guard decl.accessorSpecifier.tokenKind == .keyword(.get),
                      let body = decl.body
                else { return decl }
                let rewritten = CodeBlockItemListSyntax(body.statements.map(stampTopLevelItem))
                return decl.with(\.body, body.with(\.statements, rewritten))
            })
            let newAccessor = accessor.with(\.accessors, .accessors(rewrittenAccessors))
            return node.with(\.accessorBlock, newAccessor)
        }
    }

    // MARK: internals

    private func stampTopLevelItem(_ item: CodeBlockItemSyntax) -> CodeBlockItemSyntax {
        switch item.item {
        case .expr(let expr):
            return item.with(\.item, .expr(stamp(expr)))

        case .stmt(let stmt):
            // A statement-position `if`/`switch` appears wrapped as either
            // `ExpressionStmtSyntax(expression: IfExprSyntax|SwitchExprSyntax)`
            // or directly — unwrap to dispatch the per-branch rewriter.
            if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
                let stamped = stamp(exprStmt.expression)
                let newStmt = exprStmt.with(\.expression, stamped)
                return item.with(\.item, .stmt(StmtSyntax(newStmt)))
            }
            if let ret = stmt.as(ReturnStmtSyntax.self), let e = ret.expression {
                let stamped = stamp(e)
                let newReturn = ret.with(\.expression, stamped)
                return item.with(\.item, .stmt(StmtSyntax(newReturn)))
            }
            return item

        case .decl:
            return item
        }
    }

    private func stamp(_ expr: ExprSyntax) -> ExprSyntax {
        // Per-branch stamping for expression-position if/switch keeps SwiftUI
        // type inference happy (each branch returns `some View`).
        if let ifExpr = expr.as(IfExprSyntax.self) {
            return ExprSyntax(rewriteIf(ifExpr))
        }
        if let switchExpr = expr.as(SwitchExprSyntax.self) {
            return ExprSyntax(rewriteSwitch(switchExpr))
        }

        if alreadyStamped(expr) { return expr }

        let leading = expr.leadingTrivia
        let trailing = expr.trailingTrivia
        let bare = expr.with(\.leadingTrivia, []).with(\.trailingTrivia, [])
        stampCount += 1
        let wrapped: ExprSyntax = "\(bare).inspectable()"
        return wrapped
            .with(\.leadingTrivia, leading)
            .with(\.trailingTrivia, trailing)
    }

    private func rewriteIf(_ node: IfExprSyntax) -> IfExprSyntax {
        var rewritten = node
        // then-branch: stamp last statement
        rewritten = rewritten.with(\.body, rewriteBlock(rewritten.body))
        // else-branch: could be another IfExpr (else if) or a CodeBlock
        if let elseBody = rewritten.elseBody {
            switch elseBody {
            case .ifExpr(let nested):
                rewritten = rewritten.with(\.elseBody, .ifExpr(rewriteIf(nested)))
            case .codeBlock(let block):
                rewritten = rewritten.with(\.elseBody, .codeBlock(rewriteBlock(block)))
            }
        }
        return rewritten
    }

    private func rewriteSwitch(_ node: SwitchExprSyntax) -> SwitchExprSyntax {
        var rewritten = node
        let newCases = SwitchCaseListSyntax(rewritten.cases.map { element -> SwitchCaseListSyntax.Element in
            switch element {
            case .switchCase(let sc):
                let rewrittenStmts = rewriteTrailingExpr(in: sc.statements)
                return .switchCase(sc.with(\.statements, rewrittenStmts))
            case .ifConfigDecl:
                return element
            }
        })
        rewritten = rewritten.with(\.cases, newCases)
        return rewritten
    }

    private func rewriteBlock(_ block: CodeBlockSyntax) -> CodeBlockSyntax {
        let rewritten = rewriteTrailingExpr(in: block.statements)
        return block.with(\.statements, rewritten)
    }

    /// Stamp only the trailing expression in a CodeBlockItemList (ViewBuilder
    /// if/switch branch semantics: the last expression is the result).
    private func rewriteTrailingExpr(in list: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        guard !list.isEmpty else { return list }
        var items = Array(list)
        let last = items.removeLast()
        let rewritten: CodeBlockItemSyntax
        switch last.item {
        case .expr(let e):
            rewritten = last.with(\.item, .expr(stamp(e)))
        case .stmt(let s):
            if let ret = s.as(ReturnStmtSyntax.self), let e = ret.expression {
                let stamped = stamp(e)
                let newRet = ret.with(\.expression, stamped)
                rewritten = last.with(\.item, .stmt(StmtSyntax(newRet)))
            } else {
                rewritten = last
            }
        case .decl:
            rewritten = last
        }
        items.append(rewritten)
        return CodeBlockItemListSyntax(items)
    }

    private func alreadyStamped(_ expr: ExprSyntax) -> Bool {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self)
        else { return false }
        let name = member.declName.baseName.text
        return name == "inspectable"
            || name == "accessibilityIdentifier"
            || name == "id"
    }

    private func isSomeView(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        if let some = type.as(SomeOrAnyTypeSyntax.self) {
            return some.constraint.as(IdentifierTypeSyntax.self)?.name.text == "View"
        }
        return false
    }
}
