import DylToolSupport
import Foundation

/// Sparkle 2 renders only the winning item's `<description>`, so each release carries the notes of the versions
/// before it: the new notes on top, then earlier versions newest first, deduplicated and capped at `maxVersions`.
/// History comes from earlier appcasts; a feed's description is split on its `<h3>` version headings.
public enum CumulativeNotes {
    static let topHeadingStyle = "margin: 0 0 6px 0; font-size: 13px;"
    static let previousHeadingStyle = "margin: 14px 0 6px 0; font-size: 13px; opacity: 0.75;"

    /// Earlier histories win when two describe the same version.
    public static func html(
        version: String, newNotes: String, history: [[AppcastItem]], maxVersions: Int = 10
    )
        -> String
    {
        var notes: [String: String] = [:]
        for items in history {
            for item in items {
                for (sectionVersion, body) in split(item.description, fallbackVersion: normalize(item.displayVersion)) {
                    let normalized = normalizeBody(body)
                    guard !sectionVersion.isEmpty, !normalized.isEmpty, sectionVersion != version,
                        notes[sectionVersion] == nil
                    else { continue }
                    notes[sectionVersion] = normalized
                }
            }
        }
        let previous = notes.keys.sorted { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
            .reversed()
            .prefix(max(maxVersions - 1, 0))
        var output = [
            #"<h3 style="\#(topHeadingStyle)">\#(escapeHTML(version))</h3>"#,
            newNotes.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        for previousVersion in previous {
            output.append(#"<h3 style="\#(previousHeadingStyle)">\#(escapeHTML(previousVersion))</h3>"#)
            output.append(notes[previousVersion] ?? "")
        }
        return output.joined(separator: "\n")
    }

    static func split(_ description: String, fallbackVersion: String) -> [(String, String)] {
        let headings = description.matches(of: /(?is)<h3\b[^>]*>(.*?)<\/h3>/)
        var sections: [(String, String)] = []
        let leading = description[..<(headings.first?.range.lowerBound ?? description.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !leading.isEmpty, !fallbackVersion.isEmpty { sections.append((fallbackVersion, leading)) }
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].range.lowerBound : description.endIndex
            sections.append((normalize(String(heading.1)), String(description[heading.range.upperBound..<end])))
        }
        return sections
    }

    static func normalize(_ text: String) -> String {
        let plain = unescapeHTML(text.replacing(pattern: "<[^>]+>", with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.replacing(pattern: "(?i)^(?:version\\s+|v)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeBody(_ body: String) -> String {
        let styled = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(pattern: #"(?i)<li\s*>"#, with: #"<li style="\#(NotesFormatter.bulletStyle)">"#)
        let placeholder = #"(?i)^\s*(?:<p\b[^>]*>)?\s*Release\s+v?[\d.]+\s*(?:</p>)?\s*$"#
        return styled.matches(pattern: placeholder) ? "" : styled
    }

    static func versionKey(_ version: String) -> [Int] {
        version.matches(of: /\d+/).compactMap { Int($0.output) }
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
