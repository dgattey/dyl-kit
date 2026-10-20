import Foundation

/// A TOML value, limited to what `DylApp.toml` uses.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])
}

public struct TOMLError: Error, Equatable, CustomStringConvertible, Sendable {
    public let line: Int
    public let message: String

    public var description: String { "line \(line): \(message)" }
}

/// A parsed document as dotted keys (`app.platforms.macos`) with the line each key or table header is on. Inline
/// tables are stored whole and flattened, so both `bundle.usage` and `app.platforms.macos` resolve.
public struct TOMLDocument: Sendable {
    public fileprivate(set) var values: [String: TOMLValue] = [:]
    public fileprivate(set) var lines: [String: Int] = [:]

    public subscript(key: String) -> TOMLValue? { values[key] }

    fileprivate mutating func set(_ key: String, _ value: TOMLValue, line: Int) throws(TOMLError) {
        guard values[key] == nil else { throw TOMLError(line: line, message: "duplicate key `\(key)`") }
        values[key] = value
        lines[key] = line
        if case .table(let entries) = value {
            for (child, childValue) in entries { try set("\(key).\(child)", childValue, line: line) }
        }
    }
}

/// The TOML subset `DylApp.toml` needs: `[table]` headers, bare and dotted keys, basic and literal strings,
/// integers, booleans, multi-line arrays and inline tables, with `#` comments.
public enum TOML {
    public static func parse(_ text: String) throws(TOMLError) -> TOMLDocument {
        var scanner = Scanner(characters: Array(text))
        var document = TOMLDocument()
        var table = ""
        while true {
            scanner.skip(newlines: true)
            guard let next = scanner.peek else { return document }
            let line = scanner.line
            if next == "[" {
                scanner.index += 1
                table = try scanner.key()
                try scanner.expect("]")
                document.lines[table] = document.lines[table] ?? line
            } else {
                let key = try scanner.key()
                try scanner.expect("=")
                try document.set(table.isEmpty ? key : "\(table).\(key)", try scanner.value(), line: line)
            }
            scanner.skip(newlines: false)
            if let extra = scanner.peek, extra != "\n" { throw scanner.error("unexpected `\(extra)`") }
        }
    }
}

private struct Scanner {
    let characters: [Character]
    var index = 0
    var line = 1

    var peek: Character? { index < characters.count ? characters[index] : nil }

    func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

    /// Skips spaces, tabs and comments, and newlines too when `newlines` is set.
    mutating func skip(newlines: Bool) {
        while let character = peek {
            if character == "#" {
                while let next = peek, next != "\n" { index += 1 }
            } else if character == " " || character == "\t" || character == "\r" || (newlines && character == "\n") {
                if character == "\n" { line += 1 }
                index += 1
            } else {
                return
            }
        }
    }

    mutating func expect(_ character: Character) throws(TOMLError) {
        skip(newlines: false)
        guard peek == character else { throw error("expected `\(character)`") }
        index += 1
    }

    mutating func key() throws(TOMLError) -> String {
        var parts: [String] = []
        repeat {
            if !parts.isEmpty { index += 1 }
            skip(newlines: false)
            if peek == "\"" || peek == "'" {
                parts.append(try string())
            } else {
                var bare = ""
                while let character = peek, character.isLetter || character.isNumber || "-_".contains(character) {
                    bare.append(character)
                    index += 1
                }
                guard !bare.isEmpty else { throw error("expected a key") }
                parts.append(bare)
            }
            skip(newlines: false)
        } while peek == "."
        return parts.joined(separator: ".")
    }

    mutating func value() throws(TOMLError) -> TOMLValue {
        skip(newlines: false)
        switch peek {
        case "\"", "'":
            return .string(try string())
        case "[":
            index += 1
            var items: [TOMLValue] = []
            while true {
                skip(newlines: true)
                if peek == "]" { break }
                items.append(try value())
                skip(newlines: true)
                guard peek == "," else { break }
                index += 1
            }
            try expect("]")
            return .array(items)
        case "{":
            index += 1
            var entries: [String: TOMLValue] = [:]
            skip(newlines: false)
            while peek != "}" {
                let key = try key()
                try expect("=")
                guard entries[key] == nil else { throw error("duplicate key `\(key)`") }
                entries[key] = try value()
                skip(newlines: false)
                guard peek == "," else { break }
                index += 1
                skip(newlines: false)
            }
            try expect("}")
            return .table(entries)
        default:
            var word = ""
            while let character = peek, character.isLetter || character.isNumber || character == "-" {
                word.append(character)
                index += 1
            }
            if word == "true" || word == "false" { return .boolean(word == "true") }
            guard let integer = Int(word) else { throw error("unsupported value `\(word)`") }
            return .integer(integer)
        }
    }

    /// A basic (`"…"`, with `\"`, `\\`, `\n` and `\t` escapes) or literal (`'…'`) single-line string.
    mutating func string() throws(TOMLError) -> String {
        let quote = characters[index]
        index += 1
        var result = ""
        while let character = peek, character != "\n" {
            index += 1
            if character == quote { return result }
            guard quote == "\"", character == "\\", let escaped = peek else {
                result.append(character)
                continue
            }
            index += 1
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\"", "\\": result.append(escaped)
            default: throw error("unsupported escape `\\\(escaped)`")
            }
        }
        throw error("unterminated string")
    }
}
