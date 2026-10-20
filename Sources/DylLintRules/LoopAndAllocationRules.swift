import SwiftSyntax

/// `cancellation_blind_poll`: an unbounded or deadline loop that sleeps with `try? await Task.sleep` and never checks
/// cancellation. Once the task is cancelled the sleep throws at once, `try?` swallows it, and the loop spins hot.
enum CancellationBlindPoll {
    static let rule = "cancellation_blind_poll"

    static func run(_ file: ParsedFile) -> [Finding] {
        let visitor = Visitor(file: file)
        visitor.walk(file.tree)
        return visitor.findings
    }

    private final class Visitor: SyntaxVisitor {
        let file: ParsedFile
        var findings: [Finding] = []

        init(file: ParsedFile) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
            check(node, condition: node.conditions.trimmedDescription, body: node.body)
            return .visitChildren
        }

        override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
            check(node, condition: node.condition.trimmedDescription, body: node.body)
            return .visitChildren
        }

        private func check(_ loop: some SyntaxProtocol, condition: String, body: CodeBlockSyntax) {
            let isUnbounded = condition == "true"
            let isDeadline =
                condition.contains("<") || condition.contains(">")
                ? condition.contains("now") || condition.contains("deadline") || condition.contains("Date()")
                : false
            guard isUnbounded || isDeadline else { return }
            let bodyText = body.description
            guard !(condition + bodyText).contains("isCancelled"), !bodyText.contains("checkCancellation") else {
                return
            }
            let swallowsSleep = body.tokens(viewMode: .sourceAccurate).contains { token in
                guard token.tokenKind == .postfixQuestionMark, let tryExpr = token.parent?.as(TryExprSyntax.self) else {
                    return false
                }
                return tryExpr.expression.description.contains("Task.sleep")
            }
            guard swallowsSleep else { return }
            findings.append(
                file.finding(
                    loop,
                    rule: rule,
                    severity: .error,
                    "Loop sleeps with `try? await Task.sleep` but never checks cancellation, so it spins once cancelled. "
                        + "Use `try await Task.sleep` or check `Task.isCancelled`."
                )
            )
        }
    }
}

/// `formatter_alloc`: a Foundation formatter or `CIContext` created per call. Formatters are expensive; keep them in
/// a `static let`, a stored property, or use `FormatStyle`.
enum FormatterAlloc {
    static let rule = "formatter_alloc"

    static let expensiveTypes: Set<String> = [
        "ISO8601DateFormatter", "DateFormatter", "NumberFormatter", "ByteCountFormatter", "RelativeDateTimeFormatter",
        "DateComponentsFormatter", "MeasurementFormatter", "ListFormatter", "PersonNameComponentsFormatter",
        "CIContext",
    ]

    static func run(_ file: ParsedFile) -> [Finding] {
        let visitor = Visitor(file: file)
        visitor.walk(file.tree)
        return visitor.findings
    }

    /// True when the allocation runs once: a `static`/global `let`, a stored property initializer, or a `lazy var`.
    static func isHoisted(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let node = current {
            if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self)
                || node.is(AccessorBlockSyntax.self)
                || node.is(SubscriptDeclSyntax.self)
            {
                return false
            }
            if let variable = node.as(VariableDeclSyntax.self) {
                if hasModifier(variable.modifiers, "static") || hasModifier(variable.modifiers, "lazy") { return true }
                let parentIsType = variable.parent?.is(MemberBlockItemSyntax.self) ?? false
                let parentIsFile = variable.parent?.parent?.parent?.is(SourceFileSyntax.self) ?? false
                if parentIsType || parentIsFile { return true }
            }
            current = node.parent
        }
        return true
    }

    private final class Visitor: SyntaxVisitor {
        let file: ParsedFile
        var findings: [Finding] = []

        init(file: ParsedFile) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            let callee = calleeName(node)
            guard expensiveTypes.contains(callee), !isHoisted(node) else { return .visitChildren }
            findings.append(
                file.finding(
                    node,
                    rule: rule,
                    severity: .warning,
                    "\(callee)() is allocated on every call. Hoist it to a static let or use FormatStyle (.formatted())."
                )
            )
            return .visitChildren
        }
    }
}

/// `session_alloc`: `URLSession.bounded(...)` built per call. Each session opens its own connection pool and never
/// shares it; keep one per app or service in a `static let` (Gattey Photos #15).
enum SessionAlloc {
    static let rule = "session_alloc"

    static func run(_ file: ParsedFile) -> [Finding] {
        let visitor = Visitor(file: file)
        visitor.walk(file.tree)
        return visitor.findings
    }

    private final class Visitor: SyntaxVisitor {
        let file: ParsedFile
        var findings: [Finding] = []

        init(file: ParsedFile) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard calleeName(node) == "URLSession.bounded", !FormatterAlloc.isHoisted(node) else {
                return .visitChildren
            }
            findings.append(
                file.finding(
                    node,
                    rule: rule,
                    severity: .warning,
                    "URLSession.bounded() builds a session, and its connection pool, on every call. Use "
                        + "URLSession.boundedShared with URLRequest.timeoutInterval, or hoist it to a static let."
                )
            )
            return .visitChildren
        }
    }
}

/// `delegate_mainactor_hop`: `Task { @MainActor in … }` directly inside a delegate callback. The hop runs later and
/// races the next callback; Sconeos PR #6 removed six. Use `MainActor.assumeIsolated` when the callback arrives on
/// main, or make the conformance `@MainActor`.
enum DelegateMainActorHop {
    static let rule = "delegate_mainactor_hop"

    static func run(_ file: ParsedFile) -> [Finding] {
        let visitor = Visitor(file: file)
        visitor.walk(file.tree)
        return visitor.findings
    }

    private final class Visitor: SyntaxVisitor {
        let file: ParsedFile
        var findings: [Finding] = []
        private var delegateTypes: [Bool] = [false]

        init(file: ParsedFile) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        private func isDelegate(_ clause: InheritanceClauseSyntax?) -> Bool {
            inheritedNames(clause).contains { $0.hasSuffix("Delegate") || $0.hasSuffix("DataSource") }
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            delegateTypes.append(isDelegate(node.inheritanceClause))
            return .visitChildren
        }
        override func visitPost(_ node: ClassDeclSyntax) { delegateTypes.removeLast() }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            delegateTypes.append(isDelegate(node.inheritanceClause))
            return .visitChildren
        }
        override func visitPost(_ node: ExtensionDeclSyntax) { delegateTypes.removeLast() }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard delegateTypes.last == true, let body = node.body else { return .visitChildren }
            for item in body.statements {
                guard
                    let call = item.item.as(FunctionCallExprSyntax.self)
                        ?? item.item.as(ExprSyntax.self)?
                        .as(FunctionCallExprSyntax.self),
                    calleeName(call) == "Task",
                    let closure = call.trailingClosure ?? call.arguments.last?.expression.as(ClosureExprSyntax.self),
                    let attributes = closure.signature?.attributes, hasAttribute(attributes, "MainActor")
                else { continue }
                findings.append(
                    file.finding(
                        call,
                        rule: rule,
                        severity: .warning,
                        "Task { @MainActor in } in a delegate callback runs later and races the next callback. "
                            + "Use MainActor.assumeIsolated or a @MainActor conformance."
                    )
                )
            }
            return .visitChildren
        }
    }
}
