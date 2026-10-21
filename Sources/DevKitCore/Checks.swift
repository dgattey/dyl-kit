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
    public func run() -> Bool {
        var passed = true
        Log.step("manifest: \(DylAppManifest.fileName) OK")

        switch swiftLint().flatMap({ swiftlint in lintConfigs().map { (swiftlint, $0) } }) {
        case .success(let (swiftlint, configs)):
            let status = try? Shell.run(
                [swiftlint, "lint", "--strict", "--quiet"] + configs.flatMap { ["--config", $0] },
                cwd: workspace.root, allowFailure: true)
            if status != 0 { passed = false }
            Log.step("swiftlint: \(status == 0 ? "OK" : "failed")")
        case .failure(let problem):
            Log.step("swiftlint: failed: \(problem)")
            passed = false
        }

        let files = Linter.parsedFiles(under: lintRoots.map { workspace.url($0).path })
        let lint = Linter.lint(files)
        for finding in lint.findings { print(finding) }
        if lint.errorCount > 0 { passed = false }
        Log.step(
            "dyl-lint: \(files.count) files, \(lint.errorCount) errors, \(lint.warningCount) warnings, "
                + "\(lint.allowedCount) lint:allow")

        let release = ReleaseChecks(workspace: workspace).run()
        release.print()
        if !release.passed { passed = false }

        return passed
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
    /// one, which a `parent_config` path into `.build/checkouts` can't do.
    ///
    /// - Blocking: runs `swift package show-dependencies`.
    func lintConfigs() -> Result<[String], ToolError> {
        let local = workspace.url(".swiftlint.yml")
        let localText = try? String(contentsOf: local, encoding: .utf8)
        if let localText, localText.contains("parent_config:") {
            return .failure(ToolError(".swiftlint.yml: remove `parent_config`; devkit passes DylKit's shared config itself"))
        }
        guard
            let json = try? Shell.capture(
                ["swift", "package", "show-dependencies", "--format", "json"], cwd: workspace.root),
            let kit = Self.dylKitPath(dependenciesJSON: json)
        else { return .failure(ToolError("can't find the dyl-kit package; run `swift package resolve`")) }
        let shared = URL(fileURLWithPath: kit).appending(path: "lint/swiftlint.yml").path
        return .success([shared] + (localText == nil ? [] : [local.path]))
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

    /// `checks`, then build and test the app. The site has its own ubuntu job.
    ///
    /// - Blocking: runs `swift`.
    public func verify() throws {
        guard run() else { throw ToolError("checks failed") }
        try Shell.run(["swift", "build"], cwd: workspace.root)
        try Shell.run(["swift", "test"], cwd: workspace.root)
    }
}
