import Foundation

/// A parsed TOML value. Covers the subset `DylApp.toml` uses: tables, dotted keys, inline tables, arrays,
/// basic and literal strings, integers, floats, and booleans.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table(TOMLTable)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Renders the value the way `devkit manifest get` prints it: scalars bare, arrays one item per line.
    public var plainText: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .float(let value): String(value)
        case .boolean(let value): String(value)
        case .array(let items): items.map(\.plainText).joined(separator: "\n")
        case .table(let table): table.keys.sorted().joined(separator: "\n")
        }
    }
}

public struct TOMLTable: Equatable, Sendable {
    public private(set) var entries: [String: TOMLValue] = [:]
    /// 1-based line where each key was defined, keyed by its dotted path from the document root.
    public private(set) var lines: [String: Int] = [:]

    public init() {}

    public var keys: Dictionary<String, TOMLValue>.Keys { entries.keys }

    public subscript(key: String) -> TOMLValue? { entries[key] }

    /// Looks up a dotted path such as `release.site-url`.
    public func value(at path: String) -> TOMLValue? {
        var current: TOMLValue = .table(self)
        for component in path.split(separator: ".").map(String.init) {
            guard case .table(let table) = current, let next = table[component] else { return nil }
            current = next
        }
        return current
    }

    public func line(of path: String) -> Int? { lines[path] }

    fileprivate mutating func set(
        _ value: TOMLValue, at path: [String], line: Int, fullPath: [String]
    ) throws(TOMLError) {
        guard let head = path.first else { return }
        if path.count == 1 {
            if entries[head] != nil {
                throw TOMLError(line: line, message: "duplicate key `\(fullPath.joined(separator: "."))`")
            }
            entries[head] = value
            return
        }
        var child: TOMLTable
        switch entries[head] {
        case nil:
            child = TOMLTable()
        case .table(let existing):
            child = existing
        default:
            throw TOMLError(line: line, message: "`\(head)` is not a table")
        }
        try child.set(value, at: Array(path.dropFirst()), line: line, fullPath: fullPath)
        entries[head] = .table(child)
    }

    fileprivate mutating func ensureTable(at path: [String], line: Int) throws(TOMLError) {
        guard let head = path.first else { return }
        var child: TOMLTable
        switch entries[head] {
        case nil:
            child = TOMLTable()
        case .table(let existing):
            child = existing
        default:
            throw TOMLError(line: line, message: "`\(head)` is already a value, not a table")
        }
        try child.ensureTable(at: Array(path.dropFirst()), line: line)
        entries[head] = .table(child)
    }

    fileprivate mutating func recordLine(_ line: Int, for path: [String]) {
        lines[path.joined(separator: ".")] = line
    }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws(TOMLError) -> TOMLTable {
        var parser = Parser(text)
        return try parser.document()
    }
}

private struct Parser {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func document() throws(TOMLError) -> TOMLTable {
        var root = TOMLTable()
        var currentTable: [String] = []
        while true {
            skipWhitespaceAndComments(newlines: true)
            guard let scalar = peek() else { break }
            if scalar == "[" {
                advance()
                if peek() == "[" {
                    throw TOMLError(line: line, message: "arrays of tables are not supported")
                }
                skipWhitespaceAndComments(newlines: false)
                let headerLine = line
                currentTable = try key()
                skipWhitespaceAndComments(newlines: false)
                try expect("]")
                try root.ensureTable(at: currentTable, line: headerLine)
                root.recordLine(headerLine, for: currentTable)
            } else {
                let keyLine = line
                let path = try key()
                skipWhitespaceAndComments(newlines: false)
                try expect("=")
                skipWhitespaceAndComments(newlines: false)
                let parsed = try value(prefix: currentTable + path, into: &root)
                let fullPath = currentTable + path
                try root.set(parsed, at: fullPath, line: keyLine, fullPath: fullPath)
                root.recordLine(keyLine, for: fullPath)
            }
            try endOfLine()
        }
        return root
    }

    // MARK: Keys

    private mutating func key() throws(TOMLError) -> [String] {
        var parts = [try simpleKey()]
        while true {
            skipWhitespaceAndComments(newlines: false)
            guard peek() == "." else { break }
            advance()
            skipWhitespaceAndComments(newlines: false)
            parts.append(try simpleKey())
        }
        return parts
    }

    private mutating func simpleKey() throws(TOMLError) -> String {
        switch peek() {
        case "\"": return try basicString()
        case "'": return try literalString()
        default:
            var result = ""
            while let scalar = peek(), isBareKey(scalar) {
                result.unicodeScalars.append(scalar)
                advance()
            }
            guard !result.isEmpty else { throw TOMLError(line: line, message: "expected a key") }
            return result
        }
    }

    private func isBareKey(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isASCIIHexDigit || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
            || scalar == "_" || scalar == "-"
    }

    // MARK: Values

    private mutating func value(prefix: [String], into root: inout TOMLTable) throws(TOMLError) -> TOMLValue {
        guard let scalar = peek() else { throw TOMLError(line: line, message: "expected a value") }
        switch scalar {
        case "\"":
            if lookahead("\"\"\"") { throw TOMLError(line: line, message: "multi-line strings are not supported") }
            return .string(try basicString())
        case "'":
            return .string(try literalString())
        case "[":
            return .array(try array(prefix: prefix, into: &root))
        case "{":
            return .table(try inlineTable(prefix: prefix, into: &root))
        case "t", "f":
            if consume("true") { return .boolean(true) }
            if consume("false") { return .boolean(false) }
            throw TOMLError(line: line, message: "expected `true` or `false`")
        default:
            return try number()
        }
    }

    private mutating func basicString() throws(TOMLError) -> String {
        try expect("\"")
        var result = ""
        while true {
            guard let scalar = peek(), scalar != "\n" else {
                throw TOMLError(line: line, message: "unterminated string")
            }
            advance()
            if scalar == "\"" { return result }
            if scalar == "\\" {
                guard let escaped = peek() else { throw TOMLError(line: line, message: "unterminated escape") }
                advance()
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "u", "U":
                    let count = escaped == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0..<count {
                        guard let digit = peek(), digit.properties.isASCIIHexDigit else {
                            throw TOMLError(line: line, message: "invalid unicode escape")
                        }
                        hex.unicodeScalars.append(digit)
                        advance()
                    }
                    guard let code = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(code) else {
                        throw TOMLError(line: line, message: "invalid unicode escape")
                    }
                    result.unicodeScalars.append(unicode)
                default:
                    throw TOMLError(line: line, message: "unknown escape `\\\(escaped)`")
                }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    private mutating func literalString() throws(TOMLError) -> String {
        try expect("'")
        var result = ""
        while true {
            guard let scalar = peek(), scalar != "\n" else {
                throw TOMLError(line: line, message: "unterminated string")
            }
            advance()
            if scalar == "'" { return result }
            result.unicodeScalars.append(scalar)
        }
    }

    private mutating func array(prefix: [String], into root: inout TOMLTable) throws(TOMLError) -> [TOMLValue] {
        try expect("[")
        var items: [TOMLValue] = []
        while true {
            skipWhitespaceAndComments(newlines: true)
            if peek() == "]" {
                advance()
                return items
            }
            items.append(try value(prefix: prefix, into: &root))
            skipWhitespaceAndComments(newlines: true)
            if peek() == "," {
                advance()
            } else if peek() != "]" {
                throw TOMLError(line: line, message: "expected `,` or `]` in array")
            }
        }
    }

    private mutating func inlineTable(prefix: [String], into root: inout TOMLTable) throws(TOMLError) -> TOMLTable {
        try expect("{")
        var table = TOMLTable()
        skipWhitespaceAndComments(newlines: false)
        if peek() == "}" {
            advance()
            return table
        }
        while true {
            skipWhitespaceAndComments(newlines: false)
            let keyLine = line
            let path = try key()
            skipWhitespaceAndComments(newlines: false)
            try expect("=")
            skipWhitespaceAndComments(newlines: false)
            let parsed = try value(prefix: prefix + path, into: &root)
            try table.set(parsed, at: path, line: keyLine, fullPath: prefix + path)
            root.recordLine(keyLine, for: prefix + path)
            skipWhitespaceAndComments(newlines: false)
            if peek() == "," {
                advance()
            } else if peek() == "}" {
                advance()
                return table
            } else {
                throw TOMLError(line: line, message: "expected `,` or `}` in inline table")
            }
        }
    }

    private mutating func number() throws(TOMLError) -> TOMLValue {
        var text = ""
        while let scalar = peek(), scalar.properties.isASCIIHexDigit || "+-._eE".unicodeScalars.contains(scalar) {
            text.unicodeScalars.append(scalar)
            advance()
        }
        let cleaned = text.replacingOccurrences(of: "_", with: "")
        if let integer = Int(cleaned) { return .integer(integer) }
        if let double = Double(cleaned), cleaned.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            return .float(double)
        }
        throw TOMLError(line: line, message: text.isEmpty ? "expected a value" : "invalid value `\(text)`")
    }

    // MARK: Scanning

    private func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    private func lookahead(_ literal: String) -> Bool {
        let wanted = Array(literal.unicodeScalars)
        guard index + wanted.count <= scalars.count else { return false }
        return Array(scalars[index..<index + wanted.count]) == wanted
    }

    private mutating func consume(_ literal: String) -> Bool {
        guard lookahead(literal) else { return false }
        for _ in literal.unicodeScalars { advance() }
        return true
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws(TOMLError) {
        guard peek() == scalar else {
            throw TOMLError(line: line, message: "expected `\(scalar)`")
        }
        advance()
    }

    private mutating func skipWhitespaceAndComments(newlines: Bool) {
        while let scalar = peek() {
            if scalar == " " || scalar == "\t" || scalar == "\r" || (newlines && scalar == "\n") {
                advance()
            } else if scalar == "#" {
                while let next = peek(), next != "\n" { advance() }
            } else {
                return
            }
        }
    }

    private mutating func endOfLine() throws(TOMLError) {
        skipWhitespaceAndComments(newlines: false)
        guard let scalar = peek() else { return }
        guard scalar == "\n" else {
            throw TOMLError(line: line, message: "unexpected `\(scalar)` after value")
        }
        advance()
    }
}
