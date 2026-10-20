import DylToolSupport
import Foundation

/// Turns release-note Markdown into the small HTML subset Sparkle's update dialog renders well: paragraphs, one flat
/// bullet list, links, bold and code. Parenthesized file-path asides are dropped because users can't act on them.
public struct NotesFormatter: Sendable {
    /// Top-level directories whose paths count as noise inside parentheses, besides anything with a file extension.
    public var pathRoots: [String]

    public static let defaultPathRoots = ["Sources", "Tests", "Packages", "scripts", "server", "ci", ".github"]
    static let bulletStyle = "margin-bottom: 6px; line-height: 1.45;"

    public init(pathRoots: [String] = NotesFormatter.defaultPathRoots) {
        self.pathRoots = pathRoots
    }

    public func html(_ markdown: String, version: String) -> String {
        let raw = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(pattern: #"<!--[\s\S]*?-->"#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.matches(pattern: #"(?i)<(ul|ol|li|p)\b"#) { return raw }

        var bullets: [String] = []
        var paragraphs: [String] = []
        var current: String?
        for line in raw.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                if let bullet = current { bullets.append(bullet) }
                current = nil
                continue
            }
            if stripped.matches(pattern: #"^!\[[^\]]*\]\([^)]+\)$"#)
                || stripped.matches(pattern: #"(?i)^<(?:img|video)\b"#)
                || stripped.matches(pattern: #"^#+\s+"#)
            {
                continue
            }
            if let match = stripped.firstMatch(of: /^[-*]\s+(.+)$/) {
                if let bullet = current { bullets.append(bullet) }
                current = String(match.1).trimmingCharacters(in: .whitespaces)
            } else if let bullet = current {
                current = "\(bullet) \(stripped)"
            } else {
                paragraphs.append(stripped)
            }
        }
        if let bullet = current { bullets.append(bullet) }

        var parts = paragraphs.map { #"<p style="margin: 0 0 8px 0; line-height: 1.45;">\#(renderInline($0))</p>"# }
        if !bullets.isEmpty {
            parts.append("<ul>")
            parts += bullets.map { #"  <li style="\#(Self.bulletStyle)">\#(renderInline($0))</li>"# }
            parts.append("</ul>")
        }
        if parts.isEmpty {
            parts.append(#"<p style="margin: 0; line-height: 1.45;">Release v\#(escapeHTML(version))</p>"#)
        }
        return parts.joined(separator: "\n")
    }

    func renderInline(_ text: String) -> String {
        var escaped = escapeHTML(stripFilePathParens(text))
        escaped = escaped.replacing(pattern: #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#, with: #"<a href="$2">$1</a>"#)
        escaped = escaped.replacing(pattern: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>")
        escaped = escaped.replacing(pattern: #"`([^`]+)`"#, with: "<code>$1</code>")
        return escaped
    }

    func stripFilePathParens(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        for match in text.matches(of: /\s*\(([^()]+)\)/) {
            output += text[cursor..<match.range.lowerBound]
            if !isNoiseParen(String(match.1)) { output += text[match.range] }
            cursor = match.range.upperBound
        }
        output += text[cursor...]
        output = output.replacing(pattern: #"\s+([,.;:])"#, with: "$1")
        output = output.replacing(pattern: "  +", with: " ")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNoiseParen(_ inner: String) -> Bool {
        let cleaned = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return true }
        let parts = cleaned.split(separator: /\s*(?:,|\band\b|\bor\b|&)\s*/, omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !token.isEmpty && isPathLike(token)
        }
    }

    private func isPathLike(_ token: String) -> Bool {
        let roots = pathRoots.map(regexEscaped).joined(separator: "|")
        let extensions =
            "swift|ts|tsx|js|mjs|css|json|yml|yaml|sh|md|plist|entitlements|pbxproj|xcframework|png|jpg|"
            + "jpeg|svg|ico|xml|toml"
        let pattern = #"^([/\.]\S+|(?:\#(roots))/\S*|\S+\.(?:\#(extensions))|swift\s+test|npm\s+test)\n?$"#
        return token.matches(pattern: pattern)
    }
}

/// `html.escape(text, quote=False)`: ampersand first, then angle brackets.
func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
