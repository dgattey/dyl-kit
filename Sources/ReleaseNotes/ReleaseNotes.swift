import Foundation

/// The notes a release shows its readers, taken from the merged PR's body, and the rules they follow (DylKit's
/// `.cursor/rules/changelog-release-notes.mdc`). Foundation only, so an app's PR check can compile it with `swiftc`
/// alone instead of resolving DylKit's package.
public enum ReleaseNotes {
    /// Where notes come from, in order: `# Release notes`, then `# What changed?`, then headings older bodies used.
    public static let headings = [
        "Release notes", "What changed?", "Highlights", "Summary", "Overview", "Changes", "Description",
    ]
    /// Subsections of a notes section that are for reviewers, not users.
    static let reviewerSubsections: Set = ["verification", "testing", "test plan", "screenshots", "release info"]
    static let maxBullets = 5

    /// The first of `headings` with content in `body`, nil when none has any.
    public static func markdown(body: String) -> String? {
        headings.lazy.compactMap { section($0, in: body) }.first
    }

    /// `body` before its first `---` rule, without `<!-- -->` comments or anything after an agent's body-end marker.
    public static func cleaned(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        if let end = text.range(of: "<!-- CURSOR_AGENT_PR_BODY_END -->") { text = String(text[..<end.lowerBound]) }
        text = text.replacing(#/<!--[\s\S]*?-->/#, with: "")
        if let rule = text.firstMatch(of: #/^[ \t]*-{3,}[ \t]*$/#.anchorsMatchLineEndings()) {
            text = String(text[..<rule.range.lowerBound])
        }
        return text
    }

    /// The lines under `# <heading>` in the cleaned `body`, up to the next heading of the same or a higher level.
    /// Deeper subheadings stay, except reviewer-only ones (Verification, Testing, Screenshots...) and their contents.
    /// Empty `-` placeholders are dropped. Nil when nothing is left.
    public static func section(_ heading: String, in body: String) -> String? {
        let wanted = heading.lowercased()
        var sectionLevel: Int?
        var skippedLevel: Int?
        var collected: [String] = []
        for line in cleaned(body).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let subheading = trimmed.wholeMatch(of: #/(#+)\s*(.*?)\s*/#).map { ($0.1.count, $0.2.lowercased()) }
            guard let level = sectionLevel else {
                if let (level, title) = subheading, title == wanted { sectionLevel = level }
                continue
            }
            if let (subLevel, title) = subheading, !title.isEmpty {
                if subLevel <= level { break }
                if let skipped = skippedLevel, subLevel > skipped { continue }
                skippedLevel = reviewerSubsections.contains(title) ? subLevel : nil
                if skippedLevel != nil { continue }
            } else if skippedLevel != nil {
                continue
            }
            if trimmed.wholeMatch(of: #/[-*]/#) != nil { continue }
            collected.append(line)
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Rules

    /// What breaks the rules in `body`'s `# Release notes`, which every PR needs. Empty when the notes follow them.
    public static func problems(inBody body: String) -> [String] {
        guard let notes = section("Release notes", in: body) else {
            return ["there's no # Release notes section with content; add plain-English bullets above # Release info, aim for 3, up to 5"]
        }
        return problems(in: notes)
    }

    /// More than five bullets, and code on any line: backticks, file paths, flags, identifiers and selectors.
    public static func problems(in notes: String) -> [String] {
        let lines = notes.components(separatedBy: "\n")
        let bullets = lines.filter { $0.firstMatch(of: #/^\s*[-*]\s+\S/#) != nil }.count
        var problems = bullets > maxBullets ? ["\(bullets) bullets; aim for 3, up to \(maxBullets)"] : []
        for line in lines {
            let excerpt = line.trimmingCharacters(in: .whitespaces)
            let shown = excerpt.count > 80 ? "\(excerpt.prefix(79))…" : excerpt
            for (kind, tokens) in code(in: line) {
                problems.append("\(kind.rawValue) \(tokens.joined(separator: ", ")) in “\(shown)”")
            }
        }
        return problems
    }

    enum Kind: String, CaseIterable {
        case backticks = "backticked code"
        case path = "a file path"
        case flag = "a command-line flag"
        case identifier = "a code identifier"
        case selector = "a CSS selector or dotfile"
    }

    /// The code in one line of notes, by kind. Link targets, URLs and PR numbers such as (#12) aren't code.
    static func code(in line: String) -> [(kind: Kind, tokens: [String])] {
        var found: [Kind: [String]] = [:]
        let spans = line.matches(of: #/`[^`]*`/#).map { String($0.0) }
        if !spans.isEmpty || line.contains("`") { found[.backticks] = spans.isEmpty ? ["`"] : spans }
        let prose = line.replacing(#/`[^`]*`/#, with: " ")
            .replacing(#/\]\([^)]*\)/#, with: "]")
            .replacing(#/https?:\/\/\S+/#, with: " ")
        for raw in prose.split(whereSeparator: \.isWhitespace).map(String.init) {
            let token = trimmed(raw)
            guard !token.isEmpty, let kind = kind(of: token, raw: raw) else { continue }
            found[kind, default: []].append(raw.contains("()") ? "\(token)()" : token)
        }
        return Kind.allCases.compactMap { kind in found[kind].map { (kind, $0) } }
    }

    private static let fileExtensions: Set = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "css", "scss", "json", "yml", "yaml", "sh", "md", "mdc",
        "plist", "toml", "entitlements", "xcframework", "xcodeproj", "pbxproj", "xml", "html", "py", "rb", "go", "rs",
        "lock", "tgz", "dylib", "docktileplugin", "xcassets", "icns",
    ]
    /// First path components that make even `root/name` a path.
    private static let pathRoots: Set = [
        "Sources", "Tests", "Packages", "packages", "apps", "scripts", "server", "web", "src", "docs", "public",
    ]
    /// Product names that look like code.
    private static func isBrand(_ token: String) -> Bool {
        let brand = #/(i|iPad|mac|watch|tv|vision)OS|i(Phone|Pad|Cloud|Mac|Message|Pod|Tunes|Book)s?|e(Bay|Book|SIM)s?|[A-Z]\w*\.js/#
        return token.wholeMatch(of: brand) != nil
    }
    private static let domains: Set = ["com", "org", "net", "io", "dev", "app", "co", "ai", "me", "sh", "so", "xyz", "js"]

    private static func kind(of token: String, raw: String) -> Kind? {
        if token.wholeMatch(of: #/--?[A-Za-z][\w-]*/#) != nil { return .flag }
        if token.wholeMatch(of: #/[.#][A-Za-z][\w-]*/#) != nil { return .selector }
        if isBrand(token) { return nil }
        let components = token.split(separator: "/", omittingEmptySubsequences: false)
        let fileExtension = token.split(separator: ".").dropFirst().last.map { $0.lowercased() }
        let rooted = token.first.map { "./~".contains($0) } == true || pathRoots.contains(String(components[0]))
        if token.hasPrefix("@"), components.count == 2 { return .identifier }
        if fileExtension.map(fileExtensions.contains) == true
            || (components.count > 2 && token.contains(where: \.isLetter)) || (components.count == 2 && rooted)
        {
            return .path
        }
        if raw.firstMatch(of: #/\w\(\)/#) != nil || token.firstMatch(of: #/[A-Za-z0-9]_+[A-Za-z0-9]/#) != nil {
            return .identifier
        }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        if segments.contains(where: { $0.wholeMatch(of: #/[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*/#) != nil }) {
            return .identifier
        }
        if segments.count == 2, segments[0].first?.isUppercase == true, segments[1].first?.isLowercase == true,
            !domains.contains(String(segments[1]))
        {
            return .identifier
        }
        return nil
    }

    /// `token` without surrounding punctuation, Markdown emphasis or a possessive `'s`.
    private static func trimmed(_ token: String) -> String {
        var text = Substring(token)
        let leading: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "*", "_"]
        let trailing: Set<Character> = ["(", ")", "]", "}", "\"", "'", "”", "’", "*", "_", ",", ";", ":", "!", "?", "."]
        while let first = text.first, leading.contains(first) { text = text.dropFirst() }
        while let last = text.last, trailing.contains(last) { text = text.dropLast() }
        for suffix in ["'s", "’s"] where text.hasSuffix(suffix) { text = text.dropLast(2) }
        return String(text)
    }
}
