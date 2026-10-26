import DylLintRules
import DylManifest
import DylToolSupport
import Foundation
import ReleaseKit

/// Every static check, in the order a PR needs them: the manifest (already validated when the workspace loaded),
/// SwiftLint with the shared config (tier 1), `dyl-lint` (tier 2) and the release checks (tier 3).
public struct Checks: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// Directories `dyl-lint` reads. DylKit lints its own sources in its own CI.
    public var lintRoots: [String] {
        ["Sources"].filter { FileManager.default.fileExists(atPath: workspace.url($0).path) }
    }

    /// - Blocking: runs SwiftLint and reads every source file.
    public func run() -> Bool { failures().isEmpty }

    /// Runs every tier, printing as it goes, and returns one line per failure: a tier that failed, or a release
    /// check's error.
    ///
    /// - Blocking: runs SwiftLint and reads every source file.
    func failures() -> [String] {
        var found: [String] = []
        Log.step("manifest: \(DylAppManifest.fileName) OK")

        switch swiftLint().flatMap({ swiftlint in lintConfigs().map { (swiftlint, $0) } }) {
        case .success(let (swiftlint, configs)):
            let status = try? Shell.run(
                [swiftlint, "lint", "--strict", "--quiet"] + configs.flatMap { ["--config", $0] },
                cwd: workspace.root, allowFailure: true)
            if status != 0 { found.append("swiftlint failed") }
            Log.step("swiftlint: \(status == 0 ? "OK" : "failed")")
        case .failure(let problem):
            Log.step("swiftlint: failed: \(problem)")
            found.append("swiftlint failed: \(problem)")
        }

        let files = Linter.parsedFiles(under: lintRoots.map { workspace.url($0).path })
        let lint = Linter.lint(files)
        for finding in lint.findings { print(finding) }
        if lint.errorCount > 0 { found.append("dyl-lint found \(lint.errorCount) errors") }
        Log.step(
            "dyl-lint: \(files.count) files, \(lint.errorCount) errors, \(lint.warningCount) warnings, "
                + "\(lint.allowedCount) lint:allow")

        let release = ReleaseChecks(workspace: workspace).run()
        release.print()
        found += release.findings.filter { $0.severity == .error }.map(\.description)

        return found
    }

    /// The `swiftlint` that `mise.toml` pins. A missing, broken or different linter fails the checks rather than
    /// skipping tier 1; a version-manager shim with no version selected is on `PATH` but can't run.
    ///
    /// - Blocking: reads `mise.toml` and runs `which` and `swiftlint version`.
    func swiftLint() -> Result<String, ToolError> {
        let mise = (try? String(contentsOf: workspace.url("mise.toml"), encoding: .utf8)) ?? ""
        guard let pinned = mise.firstMatch(of: /swiftlint\s*=\s*"([^"]+)"/)?.1 else {
            return .failure(ToolError("mise.toml doesn't pin swiftlint; add `swiftlint = \"<version>\"` under [tools]"))
        }
        let fix = "run `mise install` in the repo (mise.toml pins swiftlint \(pinned))"
        guard let path = Shell.which("swiftlint") else { return .failure(ToolError("swiftlint isn't on PATH; \(fix)")) }
        guard let version = try? Shell.capture([path, "version"], cwd: workspace.root) else {
            return .failure(ToolError("\(path) doesn't run; \(fix)"))
        }
        guard version == pinned else { return .failure(ToolError("swiftlint is \(version); \(fix)")) }
        return .success(path)
    }

    /// DylKit's shared config, then the app's `.swiftlint.yml` if it has one; SwiftLint reads repeated `--config`s
    /// as parent and child. DylKit is found through SwiftPM, so a `.package(path:)` checkout works as well as a URL
    /// one.
    ///
    /// - Blocking: runs `swift package show-dependencies`.
    func lintConfigs() -> Result<[String], ToolError> {
        let local = workspace.url(".swiftlint.yml")
        let hasLocal = FileManager.default.fileExists(atPath: local.path)
        guard
            let json = try? Shell.capture(
                ["swift", "package", "show-dependencies", "--format", "json"], cwd: workspace.root),
            let kit = Self.dylKitPath(dependenciesJSON: json)
        else { return .failure(ToolError("can't find the dyl-kit package; run `swift package resolve`")) }
        let shared = URL(fileURLWithPath: kit).appending(path: "lint/swiftlint.yml").path
        guard let excluded = try? Self.excludeBuildFolders(root: workspace.root) else {
            return .failure(ToolError("can't write build/\(Self.excludedConfigName)"))
        }
        return .success([shared] + (hasLocal ? [local.path] : []) + [excluded])
    }

    static let excludedConfigName = "swiftlint-excluded.yml"

    /// SwiftLint resolves a config's `excluded` paths against that config's own folder, so the shared config, inside
    /// DylKit's checkout, can't name the app's `.build` or `build/`. This last layer lives in `build/` and names both
    /// relative to it, so they stay out whatever the app's `.swiftlint.yml` says.
    ///
    /// - Blocking: writes `build/swiftlint-excluded.yml`.
    static func excludeBuildFolders(root: URL) throws -> String {
        let file = root.appending(path: "build/\(excludedConfigName)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "excluded:\n  - '.'\n  - '../.build'\n".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private struct Dependency: Decodable {
        let identity: String
        let path: String
        let dependencies: [Dependency]
    }

    /// The checkout of `dyl-kit` anywhere in `swift package show-dependencies --format json`'s tree.
    static func dylKitPath(dependenciesJSON: String) -> String? {
        guard let root = try? JSONDecoder().decode(Dependency.self, from: Data(dependenciesJSON.utf8)) else { return nil }
        var queue = [root]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.identity == "dyl-kit" { return node.path }
            queue += node.dependencies
        }
        return nil
    }

    /// `checks`, then build and test the app even when the checks failed, so an app still missing setup such as its
    /// Sparkle key gets a build and test result. Fails at the end, listing every failure. The site has its own ubuntu
    /// job.
    ///
    /// - Blocking: runs `swift`.
    public func verify() throws {
        var problems = failures()
        if try Shell.run(["swift", "build"], cwd: workspace.root, allowFailure: true) != 0 {
            problems.append("swift build failed")
        } else if try Shell.run(["swift", "test"], cwd: workspace.root, allowFailure: true) != 0 {
            problems.append("swift test failed")
        }
        guard !problems.isEmpty else { return }
        Log.step("verify failed:")
        for problem in problems { FileHandle.standardError.write(Data("  \(problem)\n".utf8)) }
        throw ToolError("\(problems.count) problem\(problems.count == 1 ? "" : "s"); see the list above")
    }
}
