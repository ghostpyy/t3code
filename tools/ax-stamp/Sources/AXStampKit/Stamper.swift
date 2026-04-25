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

    /// Names of functions in this file that take a `@ViewBuilder` parameter.
    /// Populated by a pre-pass over the source file so call sites of
    /// user-defined builder helpers (e.g. `segmentedBar { ... }`) recurse the
    /// same way as SwiftUI primitives — without per-name registration.
    fileprivate var userBuilderFunctions: Set<String> = []

    /// Names of user `struct`/`class` types in this file whose
    /// memberwise-init trailing parameter is a non-`@ViewBuilder` closure
    /// (an action callback like `let action: () -> Void`). At call sites,
    /// the trailing closure fills that parameter and is therefore a Void
    /// action — never a `@ViewBuilder`. Populated by the same pre-pass.
    fileprivate var userActionTrailingTypes: Set<String> = []

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let scanner = ViewBuilderParameterScanner(viewMode: .all)
        scanner.walk(node)
        userBuilderFunctions = scanner.builderFunctionNames
        userActionTrailingTypes = scanner.userActionTrailingTypes
        return super.visit(node)
    }

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
        /// SwiftUI's public surface for view-builder modifiers — the lowercase
        /// methods on `View` whose trailing closure is a `@ViewBuilder` (per
        /// Apple's documentation). This is *Apple's* vocabulary, not Satira's
        /// codebase. The capitalized-initializer rule below catches every
        /// container type (VStack, NavigationStack, ForEach, …) including any
        /// future SwiftUI containers and any user-defined `View` types, so no
        /// container list is needed.
        ///
        /// Action-closure modifiers (`.task`, `.onAppear`, `.onChange`,
        /// `.onTapGesture`, `.gesture`, `.refreshable`, …) deliberately stay
        /// out: their closures return Void, and recursing them would try to
        /// stamp a Void expression which fails to compile loudly.
        ///
        /// Update only when a new SwiftUI release adds a new view-builder
        /// modifier (rare — 1–2 per WWDC).
        ///
        /// `.toolbar` is deliberately excluded: its closure is a
        /// `@ToolbarContentBuilder`, not a `@ViewBuilder`. ToolbarItem and
        /// friends conform to `ToolbarContent`, not `View`, so wrapping
        /// them with `.inspectable()` (a `View` extension) doesn't
        /// compile. Inner ViewBuilder content (the body of each
        /// `ToolbarItem`) is still recursed because `super.visit` walks
        /// into the closure regardless and `ToolbarItem`'s capitalized
        /// initializer rule handles its own `@ViewBuilder` content
        /// closure.
        private static let swiftUIBuilderModifiers: Set<String> = [
            // Layered content
            "background",
            "overlay",
            "safeAreaInset",
            // Modal presentations
            "alert",
            "confirmationDialog",
            "fullScreenCover",
            "popover",
            "sheet",
            // Menus & contextual UI
            "contextMenu",
            "swipeActions",
            // Navigation
            "navigationDestination",
            // Search
            "searchable",
            "searchSuggestions",
        ]

        /// Apple's capitalized initializers whose first closure parameter is
        /// an action (`@escaping () -> Void`) rather than a `@ViewBuilder`.
        /// Curated alongside `swiftUIBuilderModifiers` because the
        /// SwiftSyntax-only pipeline has no type info to read attributes off
        /// the SDK declarations.
        ///
        /// The two-trailing-closure form is structurally indistinguishable
        /// between action-first and builder-first types:
        ///
        ///     Button { action }       label: { content }    // first is action
        ///     NavigationLink { dest } label: { content }    // first is builder
        ///
        /// For the listed types the first trailing closure is treated as an
        /// action: not recursed for stamping, and any pre-existing stale
        /// stamps inside it are stripped (self-healing for files written by
        /// older builds that recursed action closures and produced
        /// `text.inspectable()` chains parsed against operator precedence).
        ///
        /// Update only when a new SwiftUI release adds a new action-first
        /// capitalized initializer (rare).
        private static let actionFirstInitializers: Set<String> = [
            "Button",
        ]

        /// Apple's capitalized initializers whose trailing closures are NOT
        /// `@ViewBuilder` content — every closure is an action / Void
        /// callback / non-View body. Curated alongside
        /// `actionFirstInitializers` because the SwiftSyntax-only pipeline
        /// has no type info to read attributes off the SDK.
        ///
        /// Examples:
        /// - `Canvas { ctx, size in … }` — renderer is
        ///   `(inout GraphicsContext, CGSize) -> Void`. Body draws via
        ///   `ctx.fill(...)` etc., all of which return Void.
        /// - `SignInWithAppleButton { request in … } onCompletion: { … }`
        ///   — both `onRequest` and `onCompletion` are Void callbacks.
        ///
        /// For these, every trailing closure (the unlabeled
        /// `trailingClosure` AND every labelled
        /// `additionalTrailingClosures`) is skipped from stamping
        /// recursion, with stale stamps from older builds stripped in
        /// place for self-healing.
        ///
        /// Update when a new SwiftUI release adds a new capitalized
        /// initializer whose closure is not a `@ViewBuilder`.
        private static let nonViewBuilderInitializers: Set<String> = [
            "Canvas",
            "SignInWithAppleButton",
        ]

        /// SwiftUI modifiers whose trailing closure is a NON-`@ViewBuilder`
        /// result builder — its top-level expressions are not Views, but
        /// nested expressions (the result builder's children) typically
        /// contain `@ViewBuilder` content closures that DO need stamping.
        ///
        /// Example: `.toolbar { ToolbarItem { Button(...) } }`. The
        /// `.toolbar` closure is `@ToolbarContentBuilder`, so `ToolbarItem`
        /// itself must NOT be wrapped with `.inspectable()` (a `View`
        /// extension that doesn't apply to `ToolbarContent`). But the
        /// `ToolbarItem`'s own trailing closure IS `@ViewBuilder`, so its
        /// inner `Button` does need stamping.
        ///
        /// Strategy: descend into the closure body and recurse nested
        /// function calls, but do NOT stamp the closure's top-level
        /// expressions (since they're non-View result-builder content).
        ///
        /// Update when a new SwiftUI release adds a new modifier whose
        /// closure is a non-`@ViewBuilder` result builder (rare).
        private static let nonViewBuilderModifiers: Set<String> = [
            "toolbar",
        ]

        /// Semantic interpretation of a closure attached to a function
        /// call. Drives whether/how to recurse into its body.
        private enum ClosureSemantic {
            /// `@ViewBuilder` content. Stamp top-level expressions, recurse
            /// into nested calls. Used for SwiftUI containers (VStack, …),
            /// view-builder modifiers (`.background`, `.overlay`, …), and
            /// the labelled `label:` closure of action-first initializers
            /// like `Button`.
            case viewBuilder
            /// Non-`@ViewBuilder` result-builder content (ToolbarContent,
            /// etc.). Walk the closure body to recurse into nested calls
            /// (which themselves may have `@ViewBuilder` content), but do
            /// NOT stamp top-level expressions — they're not Views.
            case contentBuilder
            /// Void / action / non-builder closure (`.onAppear`, `.task`,
            /// `Button` action, gesture handlers, `Task { … }`, etc.).
            /// Strip stale `.inspectable()` calls from prior buggy runs
            /// for self-healing, but do NOT recurse for new stamping.
            case action
        }

        private unowned let owner: InspectableRewriter

        init(owner: InspectableRewriter) {
            self.owner = owner
        }

        /// Manual recursion: do NOT call `super.visit(node)`. The default
        /// SyntaxRewriter traversal walks every child unconditionally,
        /// including the bodies of action closures (`.onAppear { … }`,
        /// `.task { … }`, `Button` action, gesture handlers). Inside those
        /// bodies, the capitalized-init rule fires on identifiers like
        /// `Task`, `URLSession`, `withAnimation`, etc. — recursively
        /// invoking this same visit, which then treats those non-View
        /// inits as builders and stamps Void / assignment expressions
        /// inside their closures. The string-interpolation reparse of
        /// `"\(expr).inspectable()"` rebinds `.inspectable()` against
        /// Swift's operator precedence, producing chains like
        /// `showSheet = true.inspectable().inspectable()` that fail to
        /// compile.
        ///
        /// Instead, descent into closures is gated on the closure's
        /// semantic role (see `ClosureSemantic`), determined from the
        /// enclosing call's name. Closures that aren't `@ViewBuilder` or
        /// a non-View result builder are stripped (self-healing) and
        /// left otherwise untouched.
        override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
            var call = node

            // Walk the modifier chain. Recursing the calledExpression
            // ensures nested calls in chains like
            // `Image().resizable().background { … }` get their builder
            // modifiers processed.
            call = call.with(\.calledExpression, recurseExpr(call.calledExpression))

            let name = Self.callName(call)

            // Self-heal `.toolbar`'s closure: previous builds incorrectly
            // wrapped each top-level ToolbarItem with `.inspectable()` —
            // a `View` extension that doesn't apply to `ToolbarContent`.
            // Strip those stale top-level stamps; new runs won't produce
            // them because `.toolbar` is `.contentBuilder` semantic.
            if name == "toolbar", let closure = call.trailingClosure {
                let healed = closure.with(
                    \.statements,
                    Self.stripTopLevelInspectable(in: closure.statements)
                )
                call = call.with(\.trailingClosure, healed)
            }

            let trailingSemantic = closureSemantic(for: name, isFirstTrailing: true, in: call)

            if let closure = call.trailingClosure {
                call = call.with(\.trailingClosure, processClosure(closure, semantic: trailingSemantic))
            }

            // Additional trailing closures appear only on builder calls
            // with multiple trailing closures (e.g. `Button { } label: { }`,
            // `SignInWithAppleButton { } onCompletion: { }`). For builder
            // initializers (`isViewBuilderCall`), the additional closures
            // are `@ViewBuilder` — except for `nonViewBuilderInitializers`
            // where every closure is Void.
            let isNonBuilderInit = Self.nonViewBuilderInitializers.contains(name)
            let additionalSemantic: ClosureSemantic = isNonBuilderInit ? .action : .viewBuilder
            let extras = MultipleTrailingClosureElementListSyntax(call.additionalTrailingClosures.map {
                $0.with(\.closure, processClosure($0.closure, semantic: additionalSemantic))
            })
            call = call.with(\.additionalTrailingClosures, extras)

            return ExprSyntax(call)
        }

        /// Recursively visit an expression sub-tree to descend modifier
        /// chains and find nested builder calls. Only handles the shapes
        /// that appear in calledExpression positions (function calls and
        /// member access on function calls).
        private func recurseExpr(_ expr: ExprSyntax) -> ExprSyntax {
            if let call = expr.as(FunctionCallExprSyntax.self) {
                return visit(call)
            }
            if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
                return ExprSyntax(member.with(\.base, recurseExpr(base)))
            }
            return expr
        }

        /// Determine the semantic role of a call's trailing closure.
        private func closureSemantic(
            for name: String,
            isFirstTrailing: Bool,
            in call: FunctionCallExprSyntax
        ) -> ClosureSemantic {
            if Self.nonViewBuilderModifiers.contains(name) {
                return .contentBuilder
            }
            if Self.nonViewBuilderInitializers.contains(name) {
                return .action
            }
            // User-defined types whose memberwise-init trailing parameter
            // is an action callback (`let action: () -> Void`, etc.).
            // Single-trailing-closure form fills that parameter, so the
            // closure is Void.
            if owner.userActionTrailingTypes.contains(name)
                && isFirstTrailing
                && call.additionalTrailingClosures.isEmpty
            {
                return .action
            }
            if Self.actionFirstInitializers.contains(name)
                && isFirstTrailing
                && Self.firstTrailingIsAction(in: call)
            {
                return .action
            }
            if isViewBuilderCall(name: name) {
                return .viewBuilder
            }
            // Unknown call: lowercase non-builder modifier (`.onAppear`,
            // `.task`, `.onChange`, `.onTapGesture`, gesture handlers) or
            // lowercase function call. Treat closure as action — strip
            // stale stamps for self-healing, don't recurse for new ones.
            return .action
        }

        private func processClosure(
            _ closure: ClosureExprSyntax,
            semantic: ClosureSemantic
        ) -> ClosureExprSyntax {
            switch semantic {
            case .viewBuilder:
                return rewriteBuilderClosure(closure)
            case .contentBuilder:
                let stmts = CodeBlockItemListSyntax(closure.statements.map { item -> CodeBlockItemSyntax in
                    switch item.item {
                    case .expr(let expr):
                        return item.with(\.item, .expr(recurseExpr(expr)))
                    case .stmt(let stmt):
                        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
                            let visited = recurseExpr(exprStmt.expression)
                            let new = exprStmt.with(\.expression, visited)
                            return item.with(\.item, .stmt(StmtSyntax(new)))
                        }
                        return item
                    case .decl:
                        return item
                    }
                })
                return closure.with(\.statements, stmts)
            case .action:
                return InspectableStripper()
                    .rewrite(Syntax(closure))
                    .as(ClosureExprSyntax.self) ?? closure
            }
        }

        /// Decide whether a call expression's trailing closure should be
        /// recursed into for stamping. Three structural signals:
        ///
        /// 1. **Capitalized initializer** — `VStack { … }`, `MyCard { … }`,
        ///    `ForEach { … }`. Any UpperCamelCase identifier is a type init,
        ///    so its trailing closure is the type's `@ViewBuilder` content
        ///    parameter. Catches all SwiftUI containers and every user-defined
        ///    `View` type without enumeration.
        /// 2. **User `@ViewBuilder` helper** — `segmentedBar { … }` etc. The
        ///    pre-pass scan in `InspectableRewriter` collected the names of
        ///    every function in this file declaring a `@ViewBuilder`-attributed
        ///    parameter, so call sites of those helpers stamp identically to
        ///    SwiftUI primitives.
        /// 3. **SwiftUI builder modifier** — `.background { … }`, `.overlay`,
        ///    `.toolbar`, … See `swiftUIBuilderModifiers` above.
        private func isViewBuilderCall(name: String) -> Bool {
            if Self.isCapitalizedInitializer(name) { return true }
            if owner.userBuilderFunctions.contains(name) { return true }
            if Self.swiftUIBuilderModifiers.contains(name) { return true }
            return false
        }

        private func rewriteBuilderClosure(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
            closure.with(\.statements, CodeBlockItemListSyntax(closure.statements.map(owner.stampTopLevelItem)))
        }

        private static func callName(_ call: FunctionCallExprSyntax) -> String {
            let raw = call.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let member = raw.split(separator: ".").last.map(String.init) ?? raw
            return member.split(separator: "<").first.map(String.init) ?? member
        }

        private static func isCapitalizedInitializer(_ name: String) -> Bool {
            guard let first = name.unicodeScalars.first else { return false }
            return first >= "A" && first <= "Z"
        }

        /// Whether the call's first trailing closure should be treated as an
        /// action (Void-returning) for an action-first initializer. Two
        /// structural signals:
        ///
        /// 1. Two trailing closures present — by SwiftUI convention the
        ///    first is the action, the labelled additional is the builder
        ///    (`Button { action } label: { content }`).
        /// 2. Single trailing closure with no `action:` argument — the
        ///    trailing closure is filling the `action:` parameter
        ///    (`Button("Tap") { dismiss() }`).
        ///
        /// If the call has an explicit `action:` argument label, the
        /// trailing closure is the builder label and should recurse
        /// (`Button(action: { ... }) { Image(...) }`).
        private static func firstTrailingIsAction(in call: FunctionCallExprSyntax) -> Bool {
            if !call.additionalTrailingClosures.isEmpty { return true }
            let hasActionArg = call.arguments.contains { $0.label?.text == "action" }
            return !hasActionArg
        }

        /// Strip the immediate trailing `.inspectable()` from each
        /// top-level expression statement in a closure body, leaving
        /// nested stamps inside untouched. Used to self-heal `.toolbar`'s
        /// closure where prior buggy runs stamped `ToolbarContent`
        /// expressions.
        private static func stripTopLevelInspectable(
            in items: CodeBlockItemListSyntax
        ) -> CodeBlockItemListSyntax {
            CodeBlockItemListSyntax(items.map { item -> CodeBlockItemSyntax in
                guard case .expr(let expr) = item.item else { return item }
                return item.with(\.item, .expr(stripTrailingInspectable(expr)))
            })
        }

        private static func stripTrailingInspectable(_ expr: ExprSyntax) -> ExprSyntax {
            guard let call = expr.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "inspectable",
                  let base = member.base
            else {
                return expr
            }
            let stripped = ExprSyntax(base)
                .with(\.leadingTrivia, call.leadingTrivia)
                .with(\.trailingTrivia, call.trailingTrivia)
            return stripTrailingInspectable(stripped)
        }
    }
}

/// Pre-pass visitor: collects names of functions and user types in a source
/// file whose call-site trailing closure has known semantics, so call sites
/// of user-defined helpers don't have to be enumerated.
///
/// Two collections, both keyed by simple call-site name:
///
/// 1. `builderFunctionNames` — function/method names declaring a
///    `@ViewBuilder` parameter. Their trailing closure is `@ViewBuilder`
///    content, so the call site recurses identically to SwiftUI primitives
///    (e.g. `segmentedBar { Text("x") }`).
///
/// 2. `userActionTrailingTypes` — `struct`/`class` types whose
///    memberwise-init trailing parameter is a non-`@ViewBuilder` closure
///    (typically `action: () -> Void`, `onSelect: (T) -> Void`, …). The
///    Swift compiler synthesizes the memberwise initializer in declaration
///    order of stored properties, so a trailing closure at the call site
///    fills the type's last stored property. If that property is a
///    function-typed value without `@ViewBuilder`, the trailing closure is
///    an action callback — recursing it would over-stamp Void/non-View
///    expressions.
///
/// Walks every nesting level (free functions, methods, methods inside
/// extensions, nested types).
final class ViewBuilderParameterScanner: SyntaxVisitor {
    private(set) var builderFunctionNames: Set<String> = []
    private(set) var userActionTrailingTypes: Set<String> = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.hasViewBuilderParameter(node.signature.parameterClause.parameters) {
            builderFunctionNames.insert(node.name.text)
        }
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        classifyType(name: node.name.text, members: node.memberBlock.members)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        classifyType(name: node.name.text, members: node.memberBlock.members)
        return .visitChildren
    }

    private func classifyType(name: String, members: MemberBlockItemListSyntax) {
        guard let lastStored = Self.lastStoredVariable(in: members),
              let lastBinding = lastStored.bindings.last,
              let typeAnnotation = lastBinding.typeAnnotation,
              Self.isFunctionType(typeAnnotation.type)
        else { return }

        if !Self.hasViewBuilderAttribute(lastStored.attributes) {
            userActionTrailingTypes.insert(name)
        }
    }

    private static func lastStoredVariable(
        in members: MemberBlockItemListSyntax
    ) -> VariableDeclSyntax? {
        var last: VariableDeclSyntax?
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            // Skip computed properties — the synthesized memberwise init
            // only includes stored properties.
            let isStored = varDecl.bindings.allSatisfy { $0.accessorBlock == nil }
            guard isStored else { continue }
            // Skip property-wrapper-decorated properties (`@State`,
            // `@Environment`, `@Binding`, `@StateObject`,
            // `@EnvironmentObject`, `@AppStorage`, etc.) — these are not
            // part of the synthesized memberwise initializer's parameter
            // list and therefore can't be the trailing init parameter.
            // Detected structurally as any property with at least one
            // attached attribute, except `@ViewBuilder` itself (which
            // signals a builder closure and should be considered).
            if !varDecl.attributes.isEmpty
                && !hasViewBuilderAttribute(varDecl.attributes)
            {
                continue
            }
            last = varDecl
        }
        return last
    }

    private static func isFunctionType(_ type: TypeSyntax) -> Bool {
        if type.is(FunctionTypeSyntax.self) { return true }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return isFunctionType(optional.wrappedType)
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return isFunctionType(attributed.baseType)
        }
        if let some = type.as(SomeOrAnyTypeSyntax.self) {
            return isFunctionType(some.constraint)
        }
        return false
    }

    private static func hasViewBuilderAttribute(_ attributes: AttributeListSyntax) -> Bool {
        for element in attributes {
            guard case .attribute(let attr) = element else { continue }
            if attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "ViewBuilder" {
                return true
            }
        }
        return false
    }

    private static func hasViewBuilderParameter(_ params: FunctionParameterListSyntax) -> Bool {
        for param in params {
            if hasViewBuilderAttribute(param.attributes) {
                return true
            }
        }
        return false
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
