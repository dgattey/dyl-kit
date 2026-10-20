import DylToolSupport
import Foundation
import ReleaseKit

/// Local app builds into `build/`, never `/Applications`, so the installed release keeps updating on its own.
public struct DevBuild: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    public var appURL: URL { workspace.buildDir.appending(path: "\(workspace.manifest.app.name).app") }

    /// Bundles and ad-hoc signs `build/<App>.app` with the last shipped version and the commit count as its build.
    ///
    /// - Blocking: runs `swift build`, `codesign` and `lsregister`.
    @discardableResult
    public func build(configuration: Bundler.Configuration) throws -> URL {
        let manifest = workspace.manifest
        let version = try VersionPlanner(workspace: workspace).shippedVersion().description
        let build = (try? Shell.capture(["git", "rev-list", "--count", "HEAD"], cwd: workspace.root)) ?? "1"
        try FileManager.default.createDirectory(at: workspace.buildDir, withIntermediateDirectories: true)
        let app = try Bundler(workspace: workspace)
            .bundle(configuration: configuration, shortVersion: version, build: build, into: workspace.buildDir)
        try Signer(entitlements: workspace.url(manifest.build.entitlements), bundleIdentifier: manifest.app.bundleId)
            .sign(app)
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
            + "/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            try Shell.run([lsregister, "-f", app.path], allowFailure: true)
        }
        Log.step("built \(app.path) (\(version), build \(build))")
        return app
    }
}

/// Launch-time options passed to the app as `<PREFIX>_<NAME>` environment variables (see `LaunchOverrides`).
public struct LaunchOptions: Sendable {
    public var appearance: String?
    public var initialView: String?
    public var windowSize: String?
    public var extra: [String: String] = [:]

    public init(appearance: String? = nil, initialView: String? = nil, windowSize: String? = nil) {
        self.appearance = appearance
        self.initialView = initialView
        self.windowSize = windowSize
    }

    func environment(prefix: String) -> [String: String] {
        var values = extra
        values["APPEARANCE"] = appearance
        values["INITIAL_VIEW"] = initialView
        values["WINDOW_SIZE"] = windowSize
        return Dictionary(uniqueKeysWithValues: values.map { ("\(prefix)_\($0.key)", $0.value) })
    }
}

/// Starts the dev build behind whatever has focus. Only the copy under `build/` is ever stopped; the installed
/// release keeps running.
public struct Launcher: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    private func executable(of app: URL) -> URL {
        app.appending(path: "Contents/MacOS/\(workspace.manifest.build.product)")
    }

    /// - Blocking: runs `pgrep`.
    public func pid(of app: URL) -> Int32? {
        let output = try? Shell.capture(["pgrep", "-f", executable(of: app).path], allowFailure: true)
        return output?.split(separator: "\n").first.flatMap { Int32($0) }
    }

    /// - Blocking: runs `pkill` and waits for the process to exit.
    public func stop(_ app: URL) async throws {
        guard pid(of: app) != nil else { return }
        try Shell.run(["pkill", "-f", executable(of: app).path], allowFailure: true)
        for _ in 0..<50 where pid(of: app) != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// `open -g` keeps focus where it is. Returns the new process id once it's running.
    ///
    /// - Blocking: runs `open` and polls `pgrep`.
    @discardableResult
    public func launch(_ app: URL, options: LaunchOptions) async throws -> Int32 {
        try await stop(app)
        let prefix = workspace.manifest.launch?.envPrefix ?? workspace.manifest.app.name.uppercased()
        let environment = options.environment(prefix: prefix).sorted { $0.key < $1.key }
        try Shell.run(["open", "-g"] + environment.flatMap { ["--env", "\($0.key)=\($0.value)"] } + [app.path])
        for _ in 0..<100 {
            if let pid = pid(of: app) {
                Log.step("launched \(app.lastPathComponent) in the background (pid \(pid))")
                return pid
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ToolError("\(app.lastPathComponent) didn't start")
    }
}
