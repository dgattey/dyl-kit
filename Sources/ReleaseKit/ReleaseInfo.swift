import DylToolSupport
import Foundation
import ReleaseNotes

/// The parsing contract with the shared PR template: exactly one `# Release info` checkbox picks the bump, and the
/// notes come from `ReleaseNotes`. The CI wrapper hands release-kit the merged PR's body; the merge commit message is
/// the fallback when the GitHub lookup fails.
public enum ReleaseInfo {
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

    /// Markdown for the update dialog: `ReleaseNotes.markdown(body:)`, else `- <title>`.
    public static func notesMarkdown(body: String, fallbackTitle: String) -> String {
        ReleaseNotes.markdown(body: body) ?? (fallbackTitle.isEmpty ? "" : "- \(fallbackTitle)")
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
}
