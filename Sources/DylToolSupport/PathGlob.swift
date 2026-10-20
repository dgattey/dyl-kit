import Foundation

/// A repo-relative path glob: `**` crosses directories, `*` and `?` stay within one path component.
public struct PathGlob: Sendable, CustomStringConvertible {
    public let pattern: String
    private let expression: String

    public init(_ pattern: String) {
        self.pattern = pattern
        var expression = "^"
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*" where characters.first == "*":
                characters.removeFirst()
                if characters.first == "/" {
                    characters.removeFirst()
                    expression += "(?:.*/)?"
                } else {
                    expression += ".*"
                }
            case "*": expression += "[^/]*"
            case "?": expression += "[^/]"
            default: expression += regexEscaped(String(character))
            }
        }
        self.expression = expression + "$"
    }

    public func matches(_ path: String) -> Bool { path.matches(pattern: expression) }

    public var description: String { pattern }
}
