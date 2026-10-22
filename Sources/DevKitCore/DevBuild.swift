import DylCore
import DylToolSupport
import Foundation
import ReleaseKit

/// Local app builds into `build/`, never `/Applications`, so the installed release keeps updating on its own. They
/// carry the dev identity, so they never share a bundle ID with the installed release.
public struct DevBuild: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    public var appURL: URL { workspace.buildDir.appending(path: "\(AppIdentity.dev.name(workspace.manifest)).app") }

    /// Bundles and ad-hoc signs `build/<App> Dev.app` with the last shipped version and the commit count as its build.
    ///
    /// - Blocking: runs `swift build`, `codesign` and `lsregister`.
    @discardableResult
    public func build(configuration: Bundler.Configuration) throws -> URL {
        let manifest = workspace.manifest
        let version = try ReleasePipeline(workspace: workspace).shippedVersion().description
        let build = (try? Shell.capture(["git", "rev-list", "--count", "HEAD"], cwd: workspace.root)) ?? "1"
        try FileManager.default.createDirectory(at: workspace.buildDir, withIntermediateDirectories: true)
        let app = try Bundler(workspace: workspace)
            .bundle(
                configuration: configuration, identity: .dev, shortVersion: version, build: build,
                into: workspace.buildDir)
        try Signer(
            entitlements: workspace.url(manifest.build.entitlements),
            bundleIdentifier: AppIdentity.dev.bundleId(manifest)
        )
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

/// Launch-time options passed to the app as `DYLKIT_<NAME>` environment variables, which `LaunchOverrides.current`
/// and `AppWindow` read without any app code. Every launch also sets `DYLKIT_BACKGROUND=1`, so the app never
/// activates itself on top of whatever Dylan is doing.
public struct LaunchOptions: Sendable {
    public typealias Appearance = LaunchOverrides.Appearance

    public var appearance: Appearance?
    public var initialView: String?
    public var windowSize: String?

    public init(appearance: Appearance? = nil, initialView: String? = nil, windowSize: String? = nil) {
        self.appearance = appearance
        self.initialView = initialView
        self.windowSize = windowSize
    }

    var environment: [String: String] {
        let values: [String: String?] = [
            "BACKGROUND": "1",
            "APPEARANCE": appearance?.rawValue,
            "INITIAL_VIEW": initialView,
            "WINDOW_SIZE": windowSize,
        ]
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            value.map { ("DYLKIT_\(key)", $0) }
        })
    }

    /// Process-level appearance through AppKit's argument domain, so every window, sheet, menu and alert follows it
    /// whether or not the app uses `AppWindow`, and the system setting is never touched.
    var arguments: [String] {
        switch appearance {
        case nil: []
        case .light: ["-NSRequiresAquaSystemAppearance", "YES"]
        case .dark: ["-AppleInterfaceStyle", "Dark", "-NSRequiresAquaSystemAppearance", "NO"]
        }
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
    private func pid(of app: URL) -> Int32? {
        let output = try? Shell.capture(["pgrep", "-f", executable(of: app).path], allowFailure: true)
        return output?.split(separator: "\n").first.flatMap { Int32($0) }
    }

    /// - Blocking: runs `pkill` and waits for the process to exit.
    private func stop(_ app: URL) async throws {
        guard pid(of: app) != nil else { return }
        try Shell.run(["pkill", "-f", executable(of: app).path], allowFailure: true)
        for _ in 0..<50 where pid(of: app) != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Always `open -g`, never a foreground launch: focus stays where it is. Returns the new process id once it's
    /// running.
    ///
    /// - Blocking: runs `open` and polls `pgrep`.
    @discardableResult
    public func launch(_ app: URL, options: LaunchOptions) async throws -> Int32 {
        try await stop(app)
        try Shell.run(Self.openArguments(app, options: options))
        for _ in 0..<100 {
            if let pid = pid(of: app) {
                Log.step("launched \(app.lastPathComponent) in the background (pid \(pid))")
                return pid
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ToolError("\(app.lastPathComponent) didn't start")
    }

    static func openArguments(_ app: URL, options: LaunchOptions) -> [String] {
        let environment = options.environment.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
        let arguments = options.arguments.isEmpty ? [] : ["--args"] + options.arguments
        return ["open", "-g"] + environment + [app.path] + arguments
    }
}
