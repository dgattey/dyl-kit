import SwiftSyntax

/// Names of types isolated to the main actor anywhere in the analyzed sources, including through extensions.
final class MainActorTypeCollector: SyntaxVisitor {
    var mainTypes: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    private func record(_ name: String, _ attributes: AttributeListSyntax, _ clause: InheritanceClauseSyntax?) {
        if hasAttribute(attributes, "MainActor") || inherits(clause, fromAnyOf: mainActorProtocols) {
            mainTypes.insert(name)
        }
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes, node.inheritanceClause)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes, node.inheritanceClause)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes, node.inheritanceClause)
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.extendedType.trimmedDescription, node.attributes, node.inheritanceClause)
        return .visitChildren
    }
}

/// Walks declarations while tracking the enclosing type and whether the current code runs on the main actor.
class IsolationWalker: SyntaxVisitor {
    let mainTypes: Set<String>
    private(set) var isolation: [Bool] = [false]
    private(set) var typeNames: [String] = []

    init(mainTypes: Set<String>) {
        self.mainTypes = mainTypes
        super.init(viewMode: .sourceAccurate)
    }

    var isMain: Bool { isolation.last ?? false }
    var currentType: String? { typeNames.last }

    private func pushType(_ name: String, _ attributes: AttributeListSyntax, _ clause: InheritanceClauseSyntax?) {
        typeNames.append(name)
        isolation.append(
            mainTypes.contains(name) || hasAttribute(attributes, "MainActor")
                || inherits(clause, fromAnyOf: mainActorProtocols)
        )
    }

    private func popType() {
        typeNames.removeLast()
        isolation.removeLast()
    }

    private func memberIsolation(_ attributes: AttributeListSyntax, _ modifiers: DeclModifierListSyntax) -> Bool {
        if hasModifier(modifiers, "nonisolated") { return false }
        if hasAttribute(attributes, "MainActor") { return true }
        return isMain
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node.attributes, node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { popType() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node.attributes, node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { popType() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node.attributes, node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { popType() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.extendedType.trimmedDescription, node.attributes, node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeNames.append(node.name.text)
        isolation.append(hasAttribute(node.attributes, "MainActor"))
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { popType() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        isolation.append(memberIsolation(node.attributes, node.modifiers))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { isolation.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        isolation.append(memberIsolation(node.attributes, node.modifiers))
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { isolation.removeLast() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        isolation.append(memberIsolation(node.attributes, node.modifiers))
        return .visitChildren
    }
    override func visitPost(_ node: VariableDeclSyntax) { isolation.removeLast() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        isolation.append(closureIsolation(node) ?? isMain)
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { isolation.removeLast() }
}
