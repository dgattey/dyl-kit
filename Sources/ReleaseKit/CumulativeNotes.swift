import DylToolSupport
import Foundation

/// Sparkle 2 renders only the winning item's `<description>`, so each release carries the notes of the versions
/// before it: the new notes on top, then earlier versions newest first, deduplicated and capped at `maxVersions`.
///
/// Each version is a `<section data-sparkle-version="BUILD">` stamped with its `CFBundleVersion`. Sparkle 2.5+ adds
/// `sparkle-installed-version` to the section matching the running build, and `installedVersionStyle` hides it and
/// every older sibling, so users see only what's newer than their build. A build with no notes keeps an empty
/// section as that anchor. An unmatched build sees the full list.
///
/// History comes from earlier appcasts: stamped sections are read back as written; older descriptions are split on
/// their `<h3>` headings and get builds from the appcast items and `knownBuilds`.
public enum CumulativeNotes {
    static let topHeadingStyle = "margin: 0 0 6px 0; font-size: 13px;"
    static let previousHeadingStyle = "margin: 14px 0 6px 0; font-size: 13px; opacity: 0.75;"
    static let installedVersionStyle =
        "<style>.sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }</style>"

    struct Entry: Equatable {
        var version: String
        var build: String?
        var body: String
    }

    /// Earlier histories win when two describe the same version.
    public static func html(
        version: String, build: String, newNotes: String, history: [[AppcastItem]],
        knownBuilds: [String: String] = [:], maxVersions: Int = 10
    )
        -> String
    {
        let items = history.joined()
        let parsed = items.map { sections($0) }
        var builds: [String: String] = [:]
        for item in items where !normalize(item.displayVersion).isEmpty {
            if let itemBuild = item.build, !itemBuild.isEmpty, builds[normalize(item.displayVersion)] == nil {
                builds[normalize(item.displayVersion)] = itemBuild
            }
        }
        for entry in parsed.joined() where builds[entry.version] == nil {
            builds[entry.version] = entry.build
        }
        builds.merge(knownBuilds) { stamped, _ in stamped }

        var entries: [String: Entry] = [:]
        for entry in parsed.joined() where !entry.version.isEmpty && entry.version != version {
            guard entries[entry.version] == nil else { continue }
            let body = normalizeBody(entry.body)
            let entryBuild = entry.build ?? builds[entry.version]
            guard !body.isEmpty || entryBuild != nil else { continue }
            entries[entry.version] = Entry(version: entry.version, build: entryBuild, body: body)
        }
        let previous = entries.keys.sorted { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
            .reversed()
            .prefix(max(maxVersions - 1, 0))
        let newest = Entry(
            version: version, build: build, body: newNotes.trimmingCharacters(in: .whitespacesAndNewlines))
        var output = [installedVersionStyle, section(newest, headingStyle: topHeadingStyle)]
        for previousVersion in previous {
            if let entry = entries[previousVersion] {
                output.append(section(entry, headingStyle: previousHeadingStyle))
            }
        }
        return output.joined(separator: "\n")
    }

    static func section(_ entry: Entry, headingStyle: String) -> String {
        let stamp = entry.build.map { #" data-sparkle-version="\#(escapeHTML($0))""# } ?? ""
        guard !entry.body.isEmpty else {
            return #"<section\#(stamp) data-version="\#(escapeHTML(entry.version))"></section>"#
        }
        return [
            "<section\(stamp)>",
            #"<h3 style="\#(headingStyle)">\#(escapeHTML(entry.version))</h3>"#,
            entry.body,
            "</section>",
        ].joined(separator: "\n")
    }

    /// The versions in one appcast item's description, stamped sections first, else its legacy `<h3>` split.
    static func sections(_ item: AppcastItem) -> [Entry] {
        let stamped = item.description.matches(of: /(?is)<section\b([^>]*)>(.*?)<\/section>/)
        guard !stamped.isEmpty else {
            return split(item.description, fallbackVersion: normalize(item.displayVersion))
                .map { Entry(version: $0.0, build: nil, body: $0.1) }
        }
        return stamped.compactMap { match in
            let attributes = String(match.1)
            let inner = String(match.2)
            let build = attribute("data-sparkle-version", in: attributes)
            if let heading = inner.firstMatch(of: /(?is)<h3\b[^>]*>(.*?)<\/h3>/) {
                return Entry(
                    version: normalize(String(heading.1)), build: build,
                    body: String(inner[heading.range.upperBound...]))
            }
            return attribute("data-version", in: attributes).map { Entry(version: $0, build: build, body: "") }
        }
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        for match in attributes.matches(of: /([\w-]+)\s*=\s*"([^"]*)"/) where match.1 == name {
            let value = unescapeHTML(String(match.2)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
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
