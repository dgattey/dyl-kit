import SwiftSyntax

/// Protocols whose conformers SwiftUI and AppKit/UIKit isolate to the main actor.
let mainActorProtocols: Set<String> = [
    "View", "App", "Scene", "ViewModifier", "ButtonStyle", "PrimitiveButtonStyle", "Commands", "ToolbarContent",
    "LabelStyle", "ToggleStyle", "NSViewRepresentable", "UIViewRepresentable", "NSApplicationDelegate",
    "UIApplicationDelegate", "UIWindowSceneDelegate", "NSWindowDelegate", "NSViewController", "UIViewController",
    "NSWindowController", "NSView", "UIView",
]

/// Higher-order functions that run their closure argument before returning, so work inside it counts toward the
/// caller. Every other closure is assumed to run later (gesture handlers, completions, stored callbacks).
let synchronousClosureCallees: Set<String> = [
    "map", "compactMap", "flatMap", "filter", "forEach", "reduce", "first", "firstIndex", "last", "lastIndex",
    "contains", "allSatisfy", "sorted", "sort", "min", "max", "partition", "removeAll", "drop", "prefix",
    "withLock", "withUnsafeBytes", "withUnsafeMutableBytes", "autoreleasepool", "assumeIsolated",
    "withExtendedLifetime",
]

func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
    attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
}

func hasAttribute(_ attributes: AttributeListSyntax, _ name: String) -> Bool {
    attributeNames(attributes).contains(name)
}

func hasModifier(_ modifiers: DeclModifierListSyntax, _ name: String) -> Bool {
    modifiers.contains { $0.name.text == name }
}

func inheritedNames(_ clause: InheritanceClauseSyntax?) -> [String] {
    clause?.inheritedTypes.map { String($0.type.trimmedDescription.split(separator: ".").last ?? "") } ?? []
}

func inherits(_ clause: InheritanceClauseSyntax?, fromAnyOf names: Set<String>) -> Bool {
    inheritedNames(clause).contains { names.contains($0) }
}

/// The call a closure is an argument (or trailing closure) of.
func enclosingCall(of closure: ClosureExprSyntax) -> FunctionCallExprSyntax? {
    var node = Syntax(closure).parent
    while let current = node {
        if let call = current.as(FunctionCallExprSyntax.self) { return call }
        if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) { return nil }
        node = current.parent
    }
    return nil
}

func calleeName(_ call: FunctionCallExprSyntax) -> String {
    call.calledExpression.trimmedDescription.filter { !$0.isWhitespace }
}

func lastComponent(_ callee: String) -> String {
    String(callee.split(separator: ".").last ?? Substring(callee))
}

/// Isolation a closure introduces: `true` for main, `false` for a background context, nil when it inherits.
func closureIsolation(_ closure: ClosureExprSyntax) -> Bool? {
    if let attributes = closure.signature?.attributes, hasAttribute(attributes, "MainActor") { return true }
    guard let call = enclosingCall(of: closure) else { return nil }
    let callee = calleeName(call)
    if callee == "Task.detached" || callee.contains("DispatchQueue.global") || callee.hasSuffix("addTask")
        || callee.hasSuffix("addTaskUnlessCancelled") || callee == "Thread" || callee.hasSuffix("performBackgroundTask")
    {
        return false
    }
    if callee == "MainActor.run" || callee == "MainActor.assumeIsolated" || callee.hasPrefix("DispatchQueue.main") {
        return true
    }
    return nil
}

/// True when the closure runs before its enclosing call returns.
func runsSynchronously(_ closure: ClosureExprSyntax) -> Bool {
    guard let call = enclosingCall(of: closure) else { return false }
    return synchronousClosureCallees.contains(lastComponent(calleeName(call)))
}

func isAwaited(_ node: some SyntaxProtocol) -> Bool {
    var current = node.parent
    while let node = current {
        if node.is(AwaitExprSyntax.self) { return true }
        if node.is(CodeBlockItemSyntax.self) || node.is(ClosureExprSyntax.self) || node.is(MemberBlockItemSyntax.self) {
            return false
        }
        current = node.parent
    }
    return false
}

/// Doc comments carrying `- Blocking` mark a function as blocking even when its body hides the I/O.
func hasBlockingMarker(_ node: some SyntaxProtocol) -> Bool {
    node.leadingTrivia.contains { piece in
        switch piece {
        case .docLineComment(let text), .docBlockComment(let text):
            text.contains("- Blocking")
        default:
            false
        }
    }
}
