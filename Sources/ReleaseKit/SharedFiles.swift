import Foundation

/// Files every app keeps as DylKit ships them in `Shared/`, so a fix lands in all three apps with the version bump.
/// `devkit sync` writes them and the `shared_files` check fails on any drift.
public enum SharedFiles {
    public struct File: Sendable {
        public let path: String
        public let contents: String
        public let executable: Bool

        init(path: String, executable: Bool = false) {
            let name = (path as NSString).lastPathComponent
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Shared"),
                let contents = try? String(contentsOf: url, encoding: .utf8)
            else { preconditionFailure("ReleaseKit's resources are missing Shared/\(name)") }
            self.path = path
            self.contents = contents
            self.executable = executable
        }
    }

    public static let all: [File] = [run, prCheck, release, prTemplate]

    static let run = File(path: "run", executable: true)
    static let prCheck = File(path: ".github/workflows/pr-check.yml")
    static let release = File(path: ".github/workflows/release.yml")
    /// `ReleaseInfo` reads the notes and the one checked Release info box from the body this template starts.
    static let prTemplate = File(path: ".github/pull_request_template.md")

    public enum Drift: String, Sendable {
        case missing
        case differs = "differs from DylKit's copy"
        case notExecutable = "isn't executable"
    }

    /// Every shared file under `root` that isn't byte for byte DylKit's copy.
    ///
    /// - Blocking: reads files.
    public static func drift(root: URL) -> [(file: File, drift: Drift)] {
        all.compactMap { file in drift(of: file, root: root).map { (file, $0) } }
    }

    /// Rewrites every shared file under `root` that drifted, and returns their paths.
    ///
    /// - Blocking: reads and writes files.
    public static func sync(root: URL) throws -> [String] {
        let stale = all.filter { drift(of: $0, root: root) != nil }
        for file in stale {
            let url = root.appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
            if file.executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return stale.map(\.path)
    }

    private static func drift(of file: File, root: URL) -> Drift? {
        let url = root.appending(path: file.path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .missing }
        if text != file.contents { return .differs }
        if file.executable, !FileManager.default.isExecutableFile(atPath: url.path) { return .notExecutable }
        return nil
    }
}
