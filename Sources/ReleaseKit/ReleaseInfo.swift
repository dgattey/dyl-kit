import DylToolSupport
import Foundation

/// The parsing contract with the shared PR template: exactly one `# Release info` checkbox picks the bump, and the
/// notes come from the first non-empty section in `notesHeadings`. The CI wrapper hands release-kit the merged PR's
/// body; the merge commit message is the fallback when the wrapper's forge lookup fails.
public enum ReleaseInfo {
    public static let notesHeadings = [
        "Release notes", "Highlights", "What changed?", "Summary", "Overview", "Changes", "Description",
    ]
    /// Subsections of a notes section that are for reviewers, not users.
    static let reviewerSubsections: Set = ["verification", "testing", "test plan", "screenshots", "release info"]

    /// The checked bump in `body`, or nil unless exactly one box is checked.
    public static func releaseType(in body: String) -> AppVersion.Bump? {
        let checked = AppVersion.Bump.allCases.filter { isChecked($0, in: body) }
        return checked.count == 1 ? checked[0] : nil
    }

    /// The PR body when it checks exactly one box, else the merge commit body when that does.
    public static func source(prBody: String?, commitBody: String) throws -> (body: String, bump: AppVersion.Bump) {
        for body in [prBody, commitBody].compactMap(\.self) {
            if let bump = releaseType(in: body) { return (body, bump) }
        }
        let tried = prBody == nil ? "the merge commit message" : "the PR body or the merge commit message"
        throw ToolError("neither \(tried) checks exactly one box under `# Release info` (Major, Minor or Patch)")
    }

    /// Markdown for the update dialog: the first non-empty notes section, else `- <title>`.
    public static func notesMarkdown(body: String, fallbackTitle: String) -> String {
        for heading in notesHeadings {
            if let section = section(heading, in: body) { return section }
        }
        return fallbackTitle.isEmpty ? "" : "- \(fallbackTitle)"
    }

    /// The lines under `# <heading>` up to the next heading of the same or a higher level, or a rule. Deeper
    /// subheadings stay, except reviewer-only ones (Verification, Testing, Screenshots...) and their contents. Empty
    /// `*` placeholders are dropped. Nil when nothing is left.
    public static func section(_ heading: String, in body: String) -> String? {
        let wanted = heading.lowercased()
        var sectionLevel: Int?
        var skippedLevel: Int?
        var collected: [String] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let subheading = trimmed.firstMatch(of: /^(#+)\s*(.*?)\s*$/).map { ($0.1.count, $0.2.lowercased()) }
            guard let level = sectionLevel else {
                if let (level, title) = subheading, title == wanted { sectionLevel = level }
                continue
            }
            if trimmed.matches(pattern: #"^-+\s*$"#) || line.contains("<!-- CURSOR_AGENT_PR_BODY_END -->") { break }
            if let (subLevel, title) = subheading, !title.isEmpty {
                if subLevel <= level { break }
                if let skipped = skippedLevel, subLevel > skipped { continue }
                skippedLevel = reviewerSubsections.contains(title) ? subLevel : nil
                if skippedLevel != nil { continue }
            } else if skippedLevel != nil {
                continue
            }
            if line.matches(pattern: #"^\s*[-*]\s*$"#) { continue }
            collected.append(line)
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func isChecked(_ bump: AppVersion.Bump, in body: String) -> Bool {
        let name = bump.rawValue.capitalized
        return body.matches(pattern: "(?im)^\\s*-\\s*\\[[xX]\\]\\s*\(name)\\b")
    }
}

/// A commit message split into its subject (minus a trailing ` (#123)`) and body.
public struct CommitMessage: Sendable, Equatable {
    public let subject: String
    public let body: String

    public init(_ message: String) {
        let lines = message.components(separatedBy: "\n")
        let rawSubject = lines.first ?? ""
        subject = rawSubject.replacing(pattern: #"\s*\(#\d+\)\s*$"#, with: "")
        body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}
