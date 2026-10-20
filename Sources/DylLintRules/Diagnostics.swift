import Foundation
import SwiftSyntax

public enum Severity: String, Comparable, Sendable {
    case warning, error

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs == .warning && rhs == .error }
}

public struct Finding: Hashable, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int
    public let rule: String
    public let severity: Severity
    public let message: String

    /// Compiler diagnostic format, so Xcode and `swift build` show findings inline.
    public var description: String { "\(file):\(line):\(column): \(severity.rawValue): \(message) [\(rule)]" }
}

/// `// lint:allow <rule>: <reason>` on the finding's line or the line above silences that rule there. The reason is
/// required; an allow without one is itself an error.
struct Suppressions {
    struct Allow {
        let line: Int
        let rule: String
        let hasReason: Bool
    }

    let allows: [Allow]

    init(tree: SourceFileSyntax, converter: SourceLocationConverter) {
        var allows: [Allow] = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            for piece in token.leadingTrivia + token.trailingTrivia {
                guard case .lineComment(let text) = piece,
                    let match = text.firstMatch(of: /\/\/\s*lint:allow\s+([a-z_]+)(:\s*(.*))?/)
                else { continue }
                let line = Self.line(of: piece, in: token, converter: converter)
                let reason = match.output.3.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                allows.append(Allow(line: line, rule: String(match.output.1), hasReason: !reason.isEmpty))
            }
        }
        self.allows = allows
    }

    func allows(_ rule: String, at line: Int) -> Bool {
        allows.contains { $0.rule == rule && $0.hasReason && ($0.line == line || $0.line == line - 1) }
    }

    private static func line(of piece: TriviaPiece, in token: TokenSyntax, converter: SourceLocationConverter) -> Int {
        var offset = token.position
        for leading in token.leadingTrivia {
            if leading == piece { return converter.location(for: offset).line }
            offset += leading.sourceLength
        }
        offset = token.endPositionBeforeTrailingTrivia
        for trailing in token.trailingTrivia {
            if trailing == piece { return converter.location(for: offset).line }
            offset += trailing.sourceLength
        }
        return converter.location(for: token.position).line
    }
}
