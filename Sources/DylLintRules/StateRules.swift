import SwiftSyntax

let reactiveWrappers: Set<String> = ["State", "Binding", "AppStorage", "SceneStorage", "FocusState"]
let mutatingMembers: Set<String> = [
    "toggle", "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "formUnion", "subtract",
]

struct Write {
    let name: String
    let node: Syntax
    /// The assigned expression, for plain and compound assignments.
    var value: ExprSyntax? = nil
}

/// The property an assignment or mutating call targets: `x`, `self.x`, `self?.x` or `$x.wrappedValue`.
func writtenName(_ expr: ExprSyntax) -> String? {
    if let reference = expr.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
    if let member = expr.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        guard let base = member.base?.trimmedDescription else { return nil }
        if base == "self" || base == "self?" { return name }
        if name == "wrappedValue", base.hasPrefix("$") { return String(base.dropFirst()) }
        if let inner = member.base, let nested = writtenName(inner) { return nested }
    }
    if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) { return writtenName(subscriptCall.calledExpression) }
    if let optional = expr.as(OptionalChainingExprSyntax.self) { return writtenName(optional.expression) }
    return nil
}

private final class WriteCollector: SyntaxVisitor {
    var found: [Write] = []

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() where index > 0 {
            let isAssignment =
                element.is(AssignmentExprSyntax.self)
                || (element.as(BinaryOperatorExprSyntax.self).map {
                    ["+=", "-=", "*=", "/=", "|=", "&="].contains($0.operator.text)
                } ?? false)
            if isAssignment, let target = writtenName(elements[index - 1]) {
                let value = elements.indices.contains(index + 1) ? elements[index + 1] : nil
                found.append(Write(name: target, node: Syntax(node), value: value))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            mutatingMembers.contains(member.declName.baseName.text),
            let base = member.base, let target = writtenName(base)
        {
            found.append(Write(name: target, node: Syntax(node)))
        }
        return .visitChildren
    }
}

func writes(in node: some SyntaxProtocol) -> [Write] {
    let collector = WriteCollector(viewMode: .sourceAccurate)
    collector.walk(node)
    return collector.found
}

/// Each type's `@State`-style properties, keyed by type name, with extensions merged in.
private final class ReactivePropertyCollector: TypeScopeWalker {
    var reactive: [String: Set<String>] = [:]

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let owner = typeName, !Set(attributeNames(node.attributes)).isDisjoint(with: reactiveWrappers) else {
            return .visitChildren
        }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            reactive[owner, default: []].insert(name)
        }
        return .visitChildren
    }
}

func collectReactiveProperties(_ files: [ParsedFile]) -> [String: Set<String>] {
    let collector = ReactivePropertyCollector(viewMode: .sourceAccurate)
    for file in files { collector.walk(file.tree) }
    return collector.reactive
}

/// Walks type declarations with the enclosing type's name on a stack.
class TypeScopeWalker: SyntaxVisitor {
    private var stack: [String] = []

    var typeName: String? { stack.last }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        stack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        stack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        stack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }
}

/// `hot_callback_state_write`: a per-frame SwiftUI callback writes reactive state without checking it changed, so
/// the view graph invalidates every frame.
enum HotCallbackStateWrite {
    static let rule = "hot_callback_state_write"

    static let hotModifiers: Set<String> = [
        "onScrollGeometryChange", "onGeometryChange", "onPreferenceChange", "onContinuousHover", "onChanged",
        "onReceive", "onScrollVisibilityChange",
    ]
    static let coarseValueTypes: Set<String> = ["Bool.self", "Int.self", "String.self"]

    static func run(_ files: [ParsedFile], reactive: [String: Set<String>]) -> [Finding] {
        var findings: [Finding] = []
        for file in files {
            let walker = Walker(file: file, reactive: reactive)
            walker.walk(file.tree)
            findings += walker.findings
        }
        return findings
    }

    private final class Walker: TypeScopeWalker {
        let file: ParsedFile
        let reactive: [String: Set<String>]
        var findings: [Finding] = []

        init(file: ParsedFile, reactive: [String: Set<String>]) {
            self.file = file
            self.reactive = reactive
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let ownReactive = typeName.flatMap({ reactive[$0] }),
                let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                hotModifiers.contains(member.declName.baseName.text)
            else { return .visitChildren }
            let modifier = member.declName.baseName.text
            if modifier == "onReceive",
                !(node.arguments.first?.expression.trimmedDescription.contains("Timer") ?? false)
            {
                return .visitChildren
            }
            if modifier == "onChanged", !(member.base?.trimmedDescription.contains("Gesture") ?? false) {
                return .visitChildren
            }
            if modifier == "onScrollGeometryChange" || modifier == "onGeometryChange",
                let forArgument = node.arguments.first(where: { $0.label?.text == "for" }),
                coarseValueTypes.contains(forArgument.expression.trimmedDescription)
            {
                return .visitChildren
            }
            var actions: [ClosureExprSyntax] = []
            for argument in node.arguments where !["of", "for", "transform"].contains(argument.label?.text ?? "") {
                if let closure = argument.expression.as(ClosureExprSyntax.self) { actions.append(closure) }
            }
            // With several trailing closures the first is the `of`/`transform` builder; with one it is the action.
            if node.additionalTrailingClosures.isEmpty {
                if let trailing = node.trailingClosure { actions.append(trailing) }
            } else {
                for labeled in node.additionalTrailingClosures where !["of", "transform"].contains(labeled.label.text) {
                    actions.append(labeled.closure)
                }
            }

            for closure in actions {
                for write in writes(in: closure) {
                    guard ownReactive.contains(write.name), !guardedByChangeCheck(write, within: closure),
                        !tracksCallbackValue(write, within: closure)
                    else {
                        continue
                    }
                    findings.append(
                        file.finding(
                            write.node,
                            rule: rule,
                            severity: .warning,
                            "\(modifier) writes reactive `\(write.name)` on every callback. Write only when the value "
                                + "changes, or keep per-frame bookkeeping in a non-reactive holder."
                        )
                    )
                }
            }
            return .visitChildren
        }

        /// A write whose value reads the callback's own argument (`dragPoint = value.location`) follows the gesture
        /// or geometry it observes; the value differs on every callback, so a change check would never skip it.
        private func tracksCallbackValue(_ write: Write, within closure: ClosureExprSyntax) -> Bool {
            guard let value = write.value else { return false }
            var parameters: Set<String> = ["$0", "$1"]
            switch closure.signature?.parameterClause {
            case .simpleInput(let shorthand):
                parameters.formUnion(shorthand.map(\.name.text))
            case .parameterClause(let clause):
                parameters.formUnion(clause.parameters.map { ($0.secondName ?? $0.firstName).text })
            case nil:
                break
            }
            return value.tokens(viewMode: .sourceAccurate).contains { parameters.contains($0.text) }
        }

        private func guardedByChangeCheck(_ write: Write, within closure: ClosureExprSyntax) -> Bool {
            var current = write.node.parent
            while let node = current, node.id != Syntax(closure).id {
                if let ifExpr = node.as(IfExprSyntax.self) {
                    let condition = ifExpr.conditions.trimmedDescription
                    if condition.contains(write.name),
                        ["!=", "abs(", ">", "<"].contains(where: condition.contains)
                    {
                        return true
                    }
                }
                current = node.parent
            }
            guard let pattern = try? Regex("guard[^{]*\\b\(write.name)\\b[^{]*(!=|>|<)") else { return false }
            return closure.statements.description.contains(pattern)
        }
    }
}
