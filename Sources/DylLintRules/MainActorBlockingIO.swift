import SwiftSyntax

/// `main_actor_blocking_io`: synchronous file I/O, Keychain IPC, CryptoKit sealing or key derivation, sleeps and
/// process waits that run on the main actor, directly or through same-module sync helpers. Each blocking chain is
/// reported once, at its outermost main-actor call site.
enum MainActorBlockingIO {
    static let rule = "main_actor_blocking_io"

    static let fileManagerMembers: Set<String> = [
        "moveItem", "copyItem", "removeItem", "createDirectory", "contentsOfDirectory", "attributesOfItem",
        "setAttributes", "replaceItemAt", "subpathsOfDirectory", "enumerator", "createFile", "contents",
    ]

    /// Member names too common to resolve by name alone to a same-module helper.
    static let ambiguousMemberNames: Set<String> = [
        "append", "insert", "remove", "removeAll", "contains", "first", "last", "map", "filter", "reduce", "sorted",
        "sort", "min", "max", "index", "firstIndex", "update", "merge", "joined", "split", "write", "read", "send",
        "load", "save", "start", "stop", "cancel", "reset", "toggle", "set", "get", "apply", "run", "callAsFunction",
    ]

    static func primitive(_ call: FunctionCallExprSyntax) -> String? {
        let callee = calleeName(call)
        let first = call.arguments.first.map { $0.label?.text ?? "_" }
        let last = lastComponent(callee)
        let receiver = callee.split(separator: ".").dropLast().joined(separator: ".")

        switch callee {
        case "Data", "String", "NSString", "NSImage", "UIImage", "NSDictionary", "NSArray",
            "CGImageSourceCreateWithURL":
            if let first, first.hasPrefix("contentsOf") { return "\(callee)(\(first):)" }
        case "FileHandle":
            if let first, first.hasPrefix("for") { return "FileHandle(\(first):)" }
        case "usleep", "sleep", "Thread.sleep", "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete":
            return callee
        default:
            break
        }
        if fileManagerMembers.contains(last),
            receiver.contains("FileManager") || receiver == "fm" || receiver == "fileManager"
        {
            return "FileManager.\(last)"
        }
        if last == "write", let first, ["to", "toFile", "contentsOf"].contains(first) { return ".write(\(first):)" }
        if ["readDataToEndOfFile", "readToEnd", "waitUntilExit"].contains(last) { return ".\(last)()" }
        if receiver.hasSuffix("AES.GCM") || receiver.hasSuffix("ChaChaPoly"), last == "seal" || last == "open" {
            return "\(receiver).\(last)"
        }
        if receiver.hasPrefix("HKDF"), last == "deriveKey" { return "HKDF.deriveKey" }
        return nil
    }

    static func run(_ files: [ParsedFile], mainTypes: Set<String>) -> [Finding] {
        var functions: [FunctionInfo] = []
        for file in files {
            let collector = FunctionCollector(file: file, mainTypes: mainTypes)
            collector.walk(file.tree)
            functions += collector.functions
        }
        let index = Dictionary(grouping: functions, by: \.name)
        propagate(functions, index: index)

        var candidates: [(Finding, FunctionInfo?)] = []
        var calledFromMain: Set<ObjectIdentifier> = []
        let byLocation = Dictionary(functions.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        for file in files {
            let reporter = Reporter(file: file, mainTypes: mainTypes, index: index, byLocation: byLocation)
            reporter.walk(file.tree)
            candidates += reporter.findings
            calledFromMain.formUnion(reporter.calledBlockingHelpers)
        }
        return candidates.compactMap { finding, enclosing in
            if let enclosing, !enclosing.isAsync, calledFromMain.contains(ObjectIdentifier(enclosing)) { return nil }
            return finding
        }
    }

    private static func propagate(_ functions: [FunctionInfo], index: [String: [FunctionInfo]]) {
        for function in functions where !function.isAsync {
            if function.isMarkedBlocking {
                function.blockingReason = "\(function.name) (marked - Blocking)"
            } else if let reason = function.directReasons.first {
                function.blockingReason = reason
            }
        }
        var changed = true
        while changed {
            changed = false
            for function in functions where function.blockingReason == nil && !function.isAsync {
                for call in function.calls {
                    guard let callee = resolve(call, in: index).first(where: { $0.blockingReason != nil }),
                        let reason = callee.blockingReason
                    else { continue }
                    function.blockingReason = "\(call.name) -> \(reason)"
                    changed = true
                    break
                }
            }
        }
    }

    static func resolve(_ key: CallKey, in index: [String: [FunctionInfo]]) -> [FunctionInfo] {
        let all = (index[key.name] ?? []).filter { !$0.isAsync && $0.accepts(key.labels) }
        switch key.receiver {
        case .implicitSelf:
            return all.filter { $0.ownerType == nil || $0.ownerType == key.contextType }
        case .type(let name):
            return all.filter { $0.ownerType == name }
        case .value(let base):
            let leaf = String(base.split(separator: ".").last ?? Substring(base)).lowercased()
            let byName = all.filter { owner in
                guard let type = owner.ownerType?.lowercased(), leaf.count >= 3 else { return false }
                return type.hasSuffix(leaf)
            }
            if !byName.isEmpty { return byName }
            if all.count == 1, !ambiguousMemberNames.contains(key.name) { return all }
            return []
        }
    }
}

enum Receiver {
    case implicitSelf
    case type(String)
    case value(String)
}

struct CallKey {
    let name: String
    let labels: [String]
    let receiver: Receiver
    let contextType: String?

    init?(_ call: FunctionCallExprSyntax, contextType: String?) {
        let labels = call.arguments.map { $0.label?.text ?? "_" }
        self.labels = labels
        self.contextType = contextType
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            guard let base = member.base?.trimmedDescription, base != "self", base != "Self" else {
                self.name = name
                receiver = .implicitSelf
                return
            }
            if let first = base.first, first.isUppercase, !base.contains("("), !base.contains(".") {
                self.name = name == "init" ? "\(base).init" : name
                receiver = .type(base)
            } else {
                self.name = name
                receiver = .value(base)
            }
            return
        }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if let first = name.first, first.isUppercase {
                self.name = "\(name).init"
                receiver = .type(name)
            } else {
                self.name = name
                receiver = .implicitSelf
            }
            return
        }
        return nil
    }
}

final class FunctionInfo {
    struct Parameter {
        let label: String
        let hasDefault: Bool
    }

    let name: String
    let ownerType: String?
    let parameters: [Parameter]
    let isAsync: Bool
    let isMarkedBlocking: Bool
    let location: String
    var directReasons: [String] = []
    var calls: [CallKey] = []
    var blockingReason: String?

    init(
        name: String,
        ownerType: String?,
        parameters: FunctionParameterClauseSyntax,
        isAsync: Bool,
        isMarkedBlocking: Bool,
        location: String
    ) {
        self.name = name
        self.ownerType = ownerType
        self.parameters = parameters.parameters.map {
            Parameter(label: $0.firstName.text, hasDefault: $0.defaultValue != nil)
        }
        self.isAsync = isAsync
        self.isMarkedBlocking = isMarkedBlocking
        self.location = location
    }

    func accepts(_ labels: [String]) -> Bool {
        var index = 0
        for parameter in parameters {
            if index < labels.count, labels[index] == parameter.label {
                index += 1
            } else if !parameter.hasDefault {
                return false
            }
        }
        return index == labels.count
    }
}

private func functionLocation(_ file: ParsedFile, _ node: some SyntaxProtocol, name: String) -> String {
    "\(file.path):\(file.converter.location(for: node.positionAfterSkippingLeadingTrivia).line):\(name)"
}

/// Pass 1: each function's direct blocking primitives and its synchronous same-module calls. Calls inside closures
/// that run later (gesture handlers, `Task`, completions) don't count toward the declaring function.
private final class FunctionCollector: IsolationWalker {
    let file: ParsedFile
    var functions: [FunctionInfo] = []
    private var stack: [FunctionInfo?] = []
    private var deferred: [Bool] = [false]

    init(file: ParsedFile, mainTypes: Set<String>) {
        self.file = file
        super.init(mainTypes: mainTypes)
    }

    private func begin(
        _ name: String, _ clause: FunctionParameterClauseSyntax, isAsync: Bool, node: some SyntaxProtocol
    ) {
        let info = FunctionInfo(
            name: name,
            ownerType: currentType,
            parameters: clause,
            isAsync: isAsync,
            isMarkedBlocking: hasBlockingMarker(node),
            location: functionLocation(file, node, name: name)
        )
        functions.append(info)
        stack.append(info)
        deferred.append(false)
    }

    private func end() {
        stack.removeLast()
        deferred.removeLast()
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = super.visit(node)
        begin(
            node.name.text,
            node.signature.parameterClause,
            isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
            node: node
        )
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        end()
        super.visitPost(node)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = super.visit(node)
        begin(
            "\(currentType ?? "?").init",
            node.signature.parameterClause,
            isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
            node: node
        )
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        end()
        super.visitPost(node)
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        _ = super.visit(node)
        deferred.append((deferred.last ?? false) || !runsSynchronously(node))
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) {
        deferred.removeLast()
        super.visitPost(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let current = stack.last ?? nil, !(deferred.last ?? false) else { return .visitChildren }
        if let primitive = MainActorBlockingIO.primitive(node) {
            current.directReasons.append(primitive)
        } else if !isAwaited(node), let key = CallKey(node, contextType: currentType) {
            current.calls.append(key)
        }
        return .visitChildren
    }
}

/// Pass 2: blocking call sites in main-actor contexts.
private final class Reporter: IsolationWalker {
    let file: ParsedFile
    let index: [String: [FunctionInfo]]
    let byLocation: [String: FunctionInfo]
    var findings: [(Finding, FunctionInfo?)] = []
    var calledBlockingHelpers: Set<ObjectIdentifier> = []
    private var enclosing: [FunctionInfo?] = []

    init(file: ParsedFile, mainTypes: Set<String>, index: [String: [FunctionInfo]], byLocation: [String: FunctionInfo])
    {
        self.file = file
        self.index = index
        self.byLocation = byLocation
        super.init(mainTypes: mainTypes)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = super.visit(node)
        enclosing.append(byLocation[functionLocation(file, node, name: node.name.text)])
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        enclosing.removeLast()
        super.visitPost(node)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = super.visit(node)
        enclosing.append(byLocation[functionLocation(file, node, name: "\(currentType ?? "?").init")])
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        enclosing.removeLast()
        super.visitPost(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isMain else { return .visitChildren }
        let message: String
        if let primitive = MainActorBlockingIO.primitive(node) {
            message = "\(primitive) blocks the main actor; move it off main (Task.detached or an actor)"
        } else if !isAwaited(node), let key = CallKey(node, contextType: currentType),
            case let candidates = MainActorBlockingIO.resolve(key, in: index),
            let hit = candidates.first(where: { $0.blockingReason != nil }), let reason = hit.blockingReason
        {
            calledBlockingHelpers.insert(ObjectIdentifier(hit))
            let labels = key.labels.map { "\($0):" }.joined()
            message = "\(key.name)(\(labels)) blocks the main actor via \(reason) [\(hit.location)]"
        } else {
            return .visitChildren
        }
        findings.append(
            (file.finding(node, rule: MainActorBlockingIO.rule, severity: .error, message), enclosing.last ?? nil))
        return .visitChildren
    }
}
