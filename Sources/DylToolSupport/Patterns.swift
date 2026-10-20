import Foundation

/// Runtime-pattern helpers over Swift `Regex`, for patterns assembled from data (headings, globs, path roots).
/// Inline options work as usual: `(?i)` ignores case, `(?m)` makes `^`/`$` match at line breaks.
extension String {
    public func matches(pattern: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return contains(regex)
    }

    /// Replaces every match of `pattern`, expanding `$1`…`$9` in `template` to capture groups.
    public func replacing(pattern: String, with template: String) -> String {
        guard let regex = try? Regex(pattern) else { return self }
        return replacing(regex) { match in
            var output = ""
            var characters = template[...]
            while let character = characters.popFirst() {
                if character == "$", let digit = characters.first?.wholeNumberValue, digit < match.output.count {
                    characters.removeFirst()
                    output += match.output[digit].substring.map(String.init) ?? ""
                } else {
                    output.append(character)
                }
            }
            return output
        }
    }
}

/// `text` with regex metacharacters escaped, for embedding in a pattern.
public func regexEscaped(_ text: String) -> String {
    let special = Set("\\^$.|?*+()[]{}/-")
    return text.reduce(into: "") { result, character in
        if special.contains(character) { result.append("\\") }
        result.append(character)
    }
}
