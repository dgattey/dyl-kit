// The release-info job in .github/workflows/app.yml compiles this with Sources/ReleaseNotes alone, so it imports nothing
// from that module: `swiftc -parse-as-library Sources/ReleaseNotes/*.swift scripts/check-release-notes.swift`.
// It reads a PR body on stdin and fails with one GitHub error per problem in its # Release notes.
import Foundation

@main enum CheckReleaseNotes {
    static func main() {
        let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let problems = ReleaseNotes.problems(inBody: body)
        guard !problems.isEmpty else {
            print("Release notes OK")
            return
        }
        for problem in problems { print("::error title=Release notes::\(problem)") }
        print(
            """
            Release notes are what people read in the update dialog and on the download page: short, plain-English \
            bullets about what they can see or do (aim for 3, up to 5), or one sentence for internal plumbing. Plain PR \
            numbers like (#12) are fine. File paths, code names, flags and backticks go in # What changed? instead. \
            DylKit's .cursor/rules/changelog-release-notes.mdc has examples.
            """)
        exit(1)
    }
}
