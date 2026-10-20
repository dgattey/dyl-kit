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

        if let swiftlint = Self.swiftLint {
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

        return passed
    }

    /// A `swiftlint` on `PATH` that runs. Version-manager shims with no version selected are on `PATH` but fail.
    ///
    /// - Blocking: runs `which` and `swiftlint version`.
    static var swiftLint: String? {
        guard let path = Shell.which("swiftlint"), (try? Shell.capture([path, "version"])) != nil else { return nil }
        return path
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
        if Checks.swiftLint == nil { Log.warn("install SwiftLint for tier 1: brew install swiftlint") }
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
