import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftParser

public enum StampOutcome: Equatable {
    case unchanged
    case rewrote(stampCount: Int)
}

public enum Stamper {
    /// Rewrite the source so every top-level expression inside declarations
    /// returning `some View` is wrapped with `.inspectable()`. Idempotent:
    /// running twice on the same input produces byte-identical output.
    public static func rewrite(source: String) -> (output: String, stamps: Int) {
        let tree = Parser.parse(source: source)
        let rewriter = InspectableRewriter()
        let newTree = rewriter.rewrite(tree)
        return (newTree.description, rewriter.stampCount)
    }

    public static func strip(source: String) -> (output: String, removals: Int) {
        let tree = Parser.parse(source: source)
        let rewriter = InspectableStripper()
        let newTree = rewriter.rewrite(tree)
        return (newTree.description, rewriter.removalCount)
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

    public static func stripFile(at url: URL) throws -> StampOutcome {
        let data = try Data(contentsOf: url)
        guard let input = String(data: data, encoding: .utf8) else {
            throw StamperError.notUTF8(url.path)
        }
        let (output, removals) = strip(source: input)
        if output == input { return .unchanged }
        try output.data(using: .utf8)!.write(to: url, options: [.atomic])
        return .rewrote(stampCount: removals)
    }

    public static func checkFile(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard let input = String(data: data, encoding: .utf8) else {
            throw StamperError.notUTF8(url.path)
        }
        let (output, _) = rewrite(source: input)
        return output == input
    }

    public static func checkStripFile(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard let input = String(data: data, encoding: .utf8) else {
            throw StamperError.notUTF8(url.path)
        }
        let (output, _) = strip(source: input)
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

/// SyntaxRewriter that finds SwiftUI declarations returning `some View` and
/// wraps terminal view expressions with `.inspectable()`.
final class InspectableRewriter: SyntaxRewriter {
    fileprivate(set) var stampCount: Int = 0

    override func visit(_ node: PatternBindingSyntax) -> PatternBindingSyntax {
        guard
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

    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        // Functions inside `extension View { ... }` are modifier adapters,
        // not screens — the caller's call-site stamp captures usage. Stamping
        // the helper's terminal expression creates a ghost anchor pinned to
        // the helper's file/line, which appears on every screen that uses
        // the helper (e.g. `.satiraInspector()` shows up everywhere). Same
        // pattern, same risk as `ViewModifier.body`.
        //
        // Self-healing: strip any pre-existing `.inspectable()` calls so
        // stale stamps from older builds disappear on the next run without
        // manual cleanup.
        if isViewExtension(node) {
            let stripped = InspectableStripper()
                .rewrite(Syntax(node))
                .as(ExtensionDeclSyntax.self) ?? node
            return DeclSyntax(stripped)
        }
        return super.visit(node)
    }

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard
            node.name.text != "inspectable",
            isSomeView(node.signature.returnClause?.type),
            let body = node.body
        else {
            return super.visit(node)
        }

        // Skip `ViewModifier.body(content:)` — structurally detected by
        // `func body(...) -> some View` with parameters (computed `var body`
        // on a View has no parameters). Stamping it wraps the returned
        // modifier chain with `.inspectable()`, which re-enters any
        // ViewModifier implementing `.inspectable()` itself (causing
        // infinite recursion), and duplicates anchors at every ViewModifier
        // call site anyway. Anchors already come from the caller's stamping.
        //
        // Self-healing: strip any pre-existing `.inspectable()` calls from
        // prior builds so stale stamps disappear on the next run without
        // manual cleanup.
        if isViewModifierBody(node) {
            let stripped = InspectableStripper()
                .rewrite(Syntax(body))
                .as(CodeBlockSyntax.self) ?? body
            return DeclSyntax(node.with(\.body, stripped))
        }

        let rewritten = CodeBlockItemListSyntax(body.statements.map(stampTopLevelItem))
        return DeclSyntax(node.with(\.body, body.with(\.statements, rewritten)))
    }

    private func isViewModifierBody(_ node: FunctionDeclSyntax) -> Bool {
        guard node.name.text == "body" else { return false }
        let params = node.signature.parameterClause.parameters
        return !params.isEmpty
    }

    private func isViewExtension(_ node: ExtensionDeclSyntax) -> Bool {
        // Match `extension View` (the SwiftUI protocol). Extensions of
        // concrete view types — `extension MyScreen` — are user code and
        // stay eligible for stamping.
        node.extendedType.as(IdentifierTypeSyntax.self)?.name.text == "View"
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

        if containsIfConfig(expr) {
            return expr
        }
        let expr = stampBuilderChildren(in: expr)
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

    private func stampBuilderChildren(in expr: ExprSyntax) -> ExprSyntax {
        BuilderClosureRewriter(owner: self).rewrite(expr).as(ExprSyntax.self) ?? expr
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

    private func containsIfConfig(_ expr: ExprSyntax) -> Bool {
        let source = expr.description
        return source.contains("#if") || source.contains("#elseif")
            || source.contains("#else") || source.contains("#endif")
    }

    private func isSomeView(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        if let some = type.as(SomeOrAnyTypeSyntax.self) {
            return some.constraint.as(IdentifierTypeSyntax.self)?.name.text == "View"
        }
        return false
    }

    private final class BuilderClosureRewriter: SyntaxRewriter {
        private static let containerCalls: Set<String> = [
            "ControlGroup",
            "DisclosureGroup",
            "ForEach",
            "Form",
            "GeometryReader",
            "Grid",
            "GridRow",
            "Group",
            "GroupBox",
            "HStack",
            "LazyHGrid",
            "LazyHStack",
            "LazyVGrid",
            "LazyVStack",
            "List",
            "Menu",
            "NavigationStack",
            "NavigationSplitView",
            "ScrollView",
            "Section",
            "Tab",
            "TabView",
            "VStack",
            "ViewThatFits",
            "ZStack",
        ]

        private static let contentModifiers: Set<String> = [
            "background",
            "contextMenu",
            "fullScreenCover",
            "overlay",
            "popover",
            "safeAreaInset",
            "sheet",
        ]

        private unowned let owner: InspectableRewriter

        init(owner: InspectableRewriter) {
            self.owner = owner
        }

        override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
            var call = super.visit(node).as(FunctionCallExprSyntax.self) ?? node
            let name = Self.callName(call)
            guard Self.containerCalls.contains(name) || Self.contentModifiers.contains(name) else {
                return ExprSyntax(call)
            }

            if let closure = call.trailingClosure {
                call = call.with(\.trailingClosure, rewriteBuilderClosure(closure))
            }

            let trailing = MultipleTrailingClosureElementListSyntax(call.additionalTrailingClosures.map {
                $0.with(\.closure, rewriteBuilderClosure($0.closure))
            })
            call = call.with(\.additionalTrailingClosures, trailing)
            return ExprSyntax(call)
        }

        private func rewriteBuilderClosure(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
            closure.with(\.statements, CodeBlockItemListSyntax(closure.statements.map(owner.stampTopLevelItem)))
        }

        private static func callName(_ call: FunctionCallExprSyntax) -> String {
            let raw = call.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let member = raw.split(separator: ".").last.map(String.init) ?? raw
            return member.split(separator: "<").first.map(String.init) ?? member
        }
    }
}

final class InspectableStripper: SyntaxRewriter {
    fileprivate(set) var removalCount = 0

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        let call = super.visit(node).as(FunctionCallExprSyntax.self) ?? node
        guard
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "inspectable",
            let base = member.base
        else {
            return ExprSyntax(call)
        }

        removalCount += 1
        return ExprSyntax(base)
            .with(\.leadingTrivia, call.leadingTrivia)
            .with(\.trailingTrivia, call.trailingTrivia)
    }
}
