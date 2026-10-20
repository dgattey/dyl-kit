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

    /// Directories `dyl-lint` reads: the app's sources and, in the repo that vendors it, DylKit's own.
    public var lintRoots: [String] {
        ["Sources", "Packages/DylKit/Sources"].filter {
            FileManager.default.fileExists(atPath: workspace.url($0).path)
        }
    }

    /// - Blocking: runs SwiftLint and reads every source file.
    public func run() -> Bool {
        var passed = true
        Log.step("manifest: \(DylAppManifest.fileName) OK")

        if let swiftlint = Shell.which("swiftlint") {
            let status = try? Shell.run(
                [swiftlint, "lint", "--strict", "--quiet", "--config", workspace.url(".swiftlint.yml").path],
                cwd: workspace.root, allowFailure: true)
            if status != 0 { passed = false }
            Log.step("swiftlint: \(status == 0 ? "OK" : "failed")")
        } else if ProcessInfo.processInfo.environment["CI"] != nil {
            Log.warn("swiftlint isn't installed")
            passed = false
        } else {
            Log.warn("swiftlint isn't installed; skipping tier 1 (brew install swiftlint)")
        }

        let paths = Linter.swiftFiles(under: lintRoots.map { workspace.url($0).path })
        let files = paths.compactMap { path in
            (try? String(contentsOfFile: path, encoding: .utf8)).map { ParsedFile(path: path, source: $0) }
        }
        let lint = Linter.lint(files)
        for finding in lint.findings { print(finding) }
        if lint.errorCount > 0 { passed = false }
        Log.step(
            "dyl-lint: \(files.count) files, \(lint.errorCount) errors, \(lint.warningCount) warnings, "
                + "\(lint.allowedCount) lint:allow")

        let release = ReleaseChecks(workspace: workspace).run()
        release.print()
        if !release.passed { passed = false }

        let staleAssets = (try? AgentAssets.sync(workspace: workspace, check: true)) ?? ["skills/"]
        for path in staleAssets { print("error: \(path) differs from DylKit's copy; run `./run dev skills sync`") }
        if !staleAssets.isEmpty { passed = false }
        Log.step("skills: \(staleAssets.isEmpty ? "OK" : "\(staleAssets.count) out of date")")
        return passed
    }

    /// `checks`, then build and test the app and DylKit, then the site's typecheck and tests.
    ///
    /// - Blocking: runs `swift` and `npm`.
    public func verify() throws {
        guard run() else { throw ToolError("checks failed") }
        try Shell.run(["swift", "build"], cwd: workspace.root)
        try Shell.run(["swift", "test"], cwd: workspace.root)
        let dylKit = workspace.url("Packages/DylKit")
        if FileManager.default.fileExists(atPath: dylKit.appending(path: "Package.swift").path) {
            try Shell.run(["swift", "test", "--package-path", dylKit.path], cwd: workspace.root)
        }
        let server = workspace.url("server")
        if FileManager.default.fileExists(atPath: server.appending(path: "package.json").path) {
            try Shell.run(["npm", "ci", "--no-audit", "--no-fund"], cwd: server)
            try Shell.run(["npm", "run", "typecheck"], cwd: server)
            try Shell.run(["npm", "test"], cwd: server)
        }
    }
}

/// One-time setup for a fresh clone: packages, icons and a pre-push hook that runs `checks`.
public struct Bootstrap: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// - Blocking: runs git and SwiftPM, and writes the hook.
    public func run() throws {
        try Shell.run(["swift", "package", "resolve"], cwd: workspace.root)
        _ = try Bundler(workspace: workspace).generateIcons()
        let hooks = URL(
            fileURLWithPath: try Shell.capture(["git", "rev-parse", "--git-path", "hooks"], cwd: workspace.root),
            relativeTo: workspace.root)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appending(path: "pre-push")
        try Data("#!/bin/sh\nexec ./run dev checks\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        Log.step("installed \(hook.path)")
        if Shell.which("swiftlint") == nil { Log.warn("install SwiftLint for tier 1: brew install swiftlint") }
    }
}

public enum Clean {
    /// Removes `build/`, and with `all` SwiftPM's `.build` too.
    ///
    /// - Blocking: deletes directories.
    public static func run(workspace: Workspace, all: Bool) throws {
        var targets = [workspace.buildDir]
        if all { targets += [workspace.url(".build"), workspace.url("Packages/DylKit/.build")] }
        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
            Log.step("removed \(target.path)")
        }
    }
}

/// Copies DylKit's skills and rules into the app's `.cursor/`, leaving the app's own skills alone.
public enum AgentAssets {
    /// DylKit's checkout. `devkit` is always compiled from it (vendored or as a SwiftPM checkout), so the
    /// compile-time path is the package root.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Each asset as (path relative to DylKit, path relative to the app).
    static func files() throws -> [(source: String, destination: String)] {
        let fileManager = FileManager.default
        let skills = try fileManager.contentsOfDirectory(atPath: packageRoot.appending(path: "skills").path).sorted()
            .filter { fileManager.fileExists(atPath: packageRoot.appending(path: "skills/\($0)/SKILL.md").path) }
            .map { ("skills/\($0)/SKILL.md", ".cursor/skills/\($0)/SKILL.md") }
        let rules = try fileManager.contentsOfDirectory(atPath: packageRoot.appending(path: "rules").path).sorted()
            .filter { $0.hasSuffix(".mdc") }
            .map { ("rules/\($0)", ".cursor/rules/\($0)") }
        return skills + rules
    }

    /// Writes the assets, or with `check` only reports which differ. Returns the app paths that differ (before
    /// writing).
    ///
    /// - Blocking: reads and writes files.
    public static func sync(workspace: Workspace, check: Bool) throws -> [String] {
        var stale: [String] = []
        for file in try files() {
            let contents = try Data(contentsOf: packageRoot.appending(path: file.source))
            let url = workspace.url(file.destination)
            if (try? Data(contentsOf: url)) == contents { continue }
            stale.append(file.destination)
            guard !check else { continue }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
            Log.step("wrote \(file.destination)")
        }
        return stale
    }
}

public enum CISync {
    /// Writes the forge wrappers from `CIWrappers`, or with `check` only reports which differ. Returns the paths
    /// that differ (before writing).
    ///
    /// - Blocking: reads and writes workflow files.
    public static func run(workspace: Workspace, forge: CIWrappers.Forge, check: Bool) throws -> [String] {
        var stale: [String] = []
        for wrapper in CIWrappers.render(forge, workspace: workspace) {
            let url = workspace.url(wrapper.path)
            if (try? String(contentsOf: url, encoding: .utf8)) == wrapper.contents { continue }
            stale.append(wrapper.path)
            guard !check else { continue }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(wrapper.contents.utf8).write(to: url)
            Log.step("wrote \(wrapper.path)")
        }
        return stale
    }
}
