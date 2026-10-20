import SwiftSyntax

let reactiveWrappers: Set<String> = ["State", "Binding", "AppStorage", "SceneStorage", "Published", "FocusState"]
let mutatingMembers: Set<String> = [
    "toggle", "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "formUnion", "subtract",
]

final class StateTypeInfo {
    let name: String
    var reactive: Set<String> = []
    var published: Set<String> = []
    var isMainActor = false
    var isObservableObject = false
    var declaration: (path: String, line: Int)?
    /// Method name to the @Published properties it writes directly.
    var directWrites: [String: Set<String>] = [:]
    /// Method name to the same-type methods it calls synchronously.
    var calls: [String: Set<String>] = [:]

    init(name: String) { self.name = name }

    func transitiveWrites(_ method: String) -> Set<String> {
        var seen: Set<String> = []
        var stack = [method]
        var result: Set<String> = []
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            result.formUnion(directWrites[next] ?? [])
            stack.append(contentsOf: calls[next] ?? [])
        }
        return result
    }
}

struct Write {
    let name: String
    let base: String?
    let node: Syntax
    /// The assigned expression, for plain and compound assignments.
    var value: ExprSyntax? = nil
}

/// The property an assignment or mutating call targets: `x`, `self.x`, `self?.x`, `$x.wrappedValue`, or `other.x`
/// when `allowOtherBase` is set.
func writtenName(_ expr: ExprSyntax, allowOtherBase: Bool = false) -> (name: String, base: String?)? {
    if let reference = expr.as(DeclReferenceExprSyntax.self) { return (reference.baseName.text, nil) }
    if let member = expr.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        guard let base = member.base?.trimmedDescription else { return nil }
        if base == "self" || base == "self?" { return (name, nil) }
        if name == "wrappedValue", base.hasPrefix("$") { return (String(base.dropFirst()), nil) }
        if allowOtherBase, !base.contains("(") { return (name, base) }
        if let inner = member.base, let nested = writtenName(inner) { return nested }
    }
    if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) { return writtenName(subscriptCall.calledExpression) }
    if let optional = expr.as(OptionalChainingExprSyntax.self) { return writtenName(optional.expression) }
    return nil
}

private final class WriteCollector: SyntaxVisitor {
    var found: [Write] = []
    let allowOtherBase: Bool

    init(allowOtherBase: Bool) {
        self.allowOtherBase = allowOtherBase
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() where index > 0 {
            let isAssignment =
                element.is(AssignmentExprSyntax.self)
                || (element.as(BinaryOperatorExprSyntax.self).map {
                    ["+=", "-=", "*=", "/=", "|=", "&="].contains($0.operator.text)
                } ?? false)
            if isAssignment, let target = writtenName(elements[index - 1], allowOtherBase: allowOtherBase) {
                let value = elements.indices.contains(index + 1) ? elements[index + 1] : nil
                found.append(Write(name: target.name, base: target.base, node: Syntax(node), value: value))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            mutatingMembers.contains(member.declName.baseName.text),
            let base = member.base, let target = writtenName(base, allowOtherBase: allowOtherBase)
        {
            found.append(Write(name: target.name, base: target.base, node: Syntax(node)))
        }
        return .visitChildren
    }
}

func writes(in node: some SyntaxProtocol, allowOtherBase: Bool = false) -> [Write] {
    let collector = WriteCollector(allowOtherBase: allowOtherBase)
    collector.walk(node)
    return collector.found
}

/// Same-type methods called from `node`: `foo()` or `self.foo()`.
func calledMethods(in node: some SyntaxProtocol) -> Set<String> {
    var names: Set<String> = []
    for token in node.tokens(viewMode: .sourceAccurate) {
        guard let call = token.parent?.parent?.as(FunctionCallExprSyntax.self) else { continue }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            names.insert(reference.baseName.text)
        } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base?.trimmedDescription, base == "self" || base == "self?"
        {
            names.insert(member.declName.baseName.text)
        }
    }
    return names
}

/// Why a closure runs off the main thread, or nil when it inherits or is main.
func backgroundContext(of closure: ClosureExprSyntax) -> String? {
    if let attributes = closure.signature?.attributes, hasAttribute(attributes, "MainActor") { return nil }
    guard let call = enclosingCall(of: closure) else { return nil }
    let callee = calleeName(call)
    if callee == "Task.detached" { return "Task.detached" }
    if callee.contains("DispatchQueue.global") { return "DispatchQueue.global" }
    if callee.hasSuffix("performBackgroundTask") { return "performBackgroundTask" }
    if callee.hasSuffix(".perform") || callee.hasSuffix(".performAndWait") {
        return callee.contains("viewContext") ? nil : "NSManagedObjectContext.perform on a background context"
    }
    if callee.hasSuffix("dataTask") || callee.hasSuffix("downloadTask") || callee.hasSuffix("uploadTask") {
        return "a URLSession completion handler"
    }
    if callee.hasSuffix("addObserver"),
        let queue = call.arguments.first(where: { $0.label?.text == "queue" })?.expression.trimmedDescription,
        queue != "OperationQueue.main", queue != ".main"
    {
        return "NotificationCenter.addObserver(queue: \(queue))"
    }
    if callee.hasSuffix(".sink"), callee.contains("NotificationCenter"), !callee.contains("receive(on:") {
        return "a NotificationCenter publisher without receive(on: main)"
    }
    return nil
}

private func isTaskClosure(_ closure: ClosureExprSyntax) -> Bool {
    enclosingCall(of: closure).map { calleeName($0) == "Task" } ?? false
}

private func insideEscapingClosure(_ node: Syntax, stopAt: Syntax) -> Bool {
    var current = node.parent
    while let node = current, node.id != stopAt.id {
        if let closure = node.as(ClosureExprSyntax.self),
            backgroundContext(of: closure) != nil || isTaskClosure(closure)
        {
            return true
        }
        current = node.parent
    }
    return false
}

private final class StateTypeCollector: SyntaxVisitor {
    let file: ParsedFile
    var types: [String: StateTypeInfo]
    private var stack: [StateTypeInfo] = []

    init(file: ParsedFile, types: [String: StateTypeInfo]) {
        self.file = file
        self.types = types
        super.init(viewMode: .sourceAccurate)
    }

    private func push(
        _ name: String, _ attributes: AttributeListSyntax, _ clause: InheritanceClauseSyntax?,
        _ node: some SyntaxProtocol
    ) {
        let info = types[name] ?? StateTypeInfo(name: name)
        let inherited = inheritedNames(clause)
        if hasAttribute(attributes, "MainActor") || inherited.contains(where: mainActorProtocols.contains) {
            info.isMainActor = true
        }
        if inherited.contains("ObservableObject") {
            info.isObservableObject = true
            if info.declaration == nil {
                info.declaration = (
                    file.path, file.converter.location(for: node.positionAfterSkippingLeadingTrivia).line
                )
            }
        }
        types[name] = info
        stack.append(info)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node.attributes, node.inheritanceClause, node)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node.attributes, node.inheritanceClause, node)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.extendedType.trimmedDescription, node.attributes, node.inheritanceClause, node)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let owner = stack.last else { return .visitChildren }
        let wrappers = Set(attributeNames(node.attributes)).intersection(reactiveWrappers)
        guard !wrappers.isEmpty else { return .visitChildren }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            owner.reactive.insert(name)
            if wrappers.contains("Published") { owner.published.insert(name) }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let owner = stack.last, let body = node.body else { return .skipChildren }
        let name = node.name.text
        let direct = writes(in: body).filter { !insideEscapingClosure($0.node, stopAt: Syntax(body)) }.map(\.name)
        owner.directWrites[name, default: []].formUnion(direct)
        owner.calls[name, default: []].formUnion(calledMethods(in: body))
        return .skipChildren
    }
}

func collectStateTypes(_ files: [ParsedFile]) -> [String: StateTypeInfo] {
    var types: [String: StateTypeInfo] = [:]
    for file in files {
        let collector = StateTypeCollector(file: file, types: types)
        collector.walk(file.tree)
        types = collector.types
    }
    return types
}

/// Walks type declarations with the matching `StateTypeInfo` on a stack.
class StateTypeWalker: SyntaxVisitor {
    let file: ParsedFile
    let types: [String: StateTypeInfo]
    var findings: [Finding] = []
    private var stack: [StateTypeInfo?] = []

    init(file: ParsedFile, types: [String: StateTypeInfo]) {
        self.file = file
        self.types = types
        super.init(viewMode: .sourceAccurate)
    }

    var owner: StateTypeInfo? { stack.last ?? nil }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        stack.append(types[node.name.text])
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        stack.append(types[node.name.text])
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        stack.append(types[node.extendedType.trimmedDescription])
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }
}

/// `published_write_off_main`: an `ObservableObject` that isn't `@MainActor` writes `@Published` state, directly or
/// through its own helpers, from a closure that runs off the main thread. `observable_not_main_actor` flags the
/// type itself; it retires once apps adopt default main-actor isolation.
enum PublishedWriteOffMain {
    static let rule = "published_write_off_main"
    static let transitionalRule = "observable_not_main_actor"

    static func run(_ files: [ParsedFile], types: [String: StateTypeInfo]) -> [Finding] {
        var findings: [Finding] = []
        for file in files {
            let walker = Walker(file: file, types: types)
            walker.walk(file.tree)
            findings += walker.findings
        }
        for info in types.values where info.isObservableObject && !info.isMainActor && !info.published.isEmpty {
            guard let declaration = info.declaration else { continue }
            findings.append(
                Finding(
                    file: declaration.path,
                    line: declaration.line,
                    column: 1,
                    rule: transitionalRule,
                    severity: .warning,
                    message: "\(info.name) publishes \(info.published.sorted().joined(separator: ", ")) but isn't "
                        + "@MainActor. Swift 6 doesn't diagnose this; mark the type @MainActor."
                )
            )
        }
        return findings
    }

    private final class Walker: StateTypeWalker {
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            guard let owner, owner.isObservableObject, !owner.isMainActor, !owner.published.isEmpty,
                let reason = backgroundContext(of: node)
            else { return .visitChildren }
            var hits: Set<String> = []
            for write in writes(in: node) where write.base == nil && owner.published.contains(write.name) {
                hits.insert(write.name)
            }
            for method in calledMethods(in: node) {
                for property in owner.transitiveWrites(method).intersection(owner.published) {
                    hits.insert("\(property) via \(method)()")
                }
            }
            if !hits.isEmpty {
                findings.append(
                    file.finding(
                        node,
                        rule: rule,
                        severity: .error,
                        "\(owner.name) isn't @MainActor and writes @Published \(hits.sorted().joined(separator: ", ")) "
                            + "from \(reason)."
                    )
                )
            }
            return .visitChildren
        }
    }
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

    static func run(_ files: [ParsedFile], types: [String: StateTypeInfo]) -> [Finding] {
        var publishedNames: Set<String> = []
        for info in types.values { publishedNames.formUnion(info.published) }
        var findings: [Finding] = []
        for file in files {
            let walker = Walker(file: file, types: types, publishedNames: publishedNames)
            walker.walk(file.tree)
            findings += walker.findings
        }
        return findings
    }

    private final class Walker: StateTypeWalker {
        let publishedNames: Set<String>

        init(file: ParsedFile, types: [String: StateTypeInfo], publishedNames: Set<String>) {
            self.publishedNames = publishedNames
            super.init(file: file, types: types)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let owner, let member = node.calledExpression.as(MemberAccessExprSyntax.self),
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
                for write in writes(in: closure, allowOtherBase: true) {
                    let ownReactive = write.base == nil && owner.reactive.contains(write.name)
                    let foreignPublished = write.base != nil && publishedNames.contains(write.name)
                    guard ownReactive || foreignPublished, !guardedByChangeCheck(write, within: closure),
                        !tracksCallbackValue(write, within: closure)
                    else {
                        continue
                    }
                    let target = write.base.map { "\($0).\(write.name)" } ?? write.name
                    findings.append(
                        file.finding(
                            write.node,
                            rule: rule,
                            severity: .warning,
                            "\(modifier) writes reactive `\(target)` on every callback. Write only when the value "
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
