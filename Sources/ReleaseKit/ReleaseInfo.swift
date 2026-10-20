import DylToolSupport
import Foundation

/// The parsing contract with the shared PR template: `# Release info` checkboxes pick the bump, and the notes come
/// from the first non-empty section in `notesHeadings`. The release reads this from the merge commit's message, so
/// squash merges must use "Pull request title and description" as the default commit message.
public enum ReleaseInfo {
    public static let notesHeadings = ["Release notes", "Highlights", "What changed?", "Summary", "Overview"]

    /// The checked bump in `body`, or nil when none is checked.
    public static func releaseType(in body: String) -> AppVersion.Bump? {
        for bump in [AppVersion.Bump.major, .minor, .patch] where checked(bump, in: body) {
            return bump
        }
        return nil
    }

    /// An error message when `body` doesn't check exactly one of Major, Minor and Patch.
    public static func validate(_ body: String) -> String? {
        guard body.matches(pattern: #"(?im)^#+\s*Release info\s*$"#) else {
            return "the PR body has no `# Release info` section; restore it from the PR template"
        }
        let checkedBumps = AppVersion.Bump.allCases.filter { checked($0, in: body) }
        switch checkedBumps.count {
        case 1: return nil
        case 0: return "check one of Major, Minor or Patch under `# Release info`"
        default:
            let names = checkedBumps.map { $0.rawValue.capitalized }.joined(separator: ", ")
            return "check only one release type under `# Release info` (found \(names))"
        }
    }

    /// Markdown for the update dialog: the first non-empty notes section, else `- <title>`.
    public static func notesMarkdown(body: String, fallbackTitle: String) -> String {
        for heading in notesHeadings {
            if let section = section(heading, in: body) { return section }
        }
        return fallbackTitle.isEmpty ? "" : "- \(fallbackTitle)"
    }

    /// The lines under `# <heading>` up to the next heading or rule, minus empty `-` placeholders, or nil when empty.
    public static func section(_ heading: String, in body: String) -> String? {
        let escaped = regexEscaped(heading)
        var inSection = false
        var collected: [String] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inSection {
                inSection = trimmed.matches(pattern: "(?i)^#+\\s*\(escaped)\\s*$")
                continue
            }
            if trimmed.matches(pattern: #"^#+\s+\S"#)
                || trimmed.matches(pattern: #"^-+\s*$"#)
                || line.contains("<!-- CURSOR_AGENT_PR_BODY_END -->")
            {
                break
            }
            if line.matches(pattern: #"^\s*[-*]\s*$"#) { continue }
            collected.append(line)
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func checked(_ bump: AppVersion.Bump, in body: String) -> Bool {
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
