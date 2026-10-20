import DylToolSupport
import Foundation

/// Picks the next version and build number from git and the published appcasts, never from a forge API.
public struct VersionPlanner: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    public struct Plan: Equatable, Sendable {
        public let current: AppVersion
        public let next: AppVersion
        public let bump: AppVersion.Bump
        public let build: Int
    }

    /// The next release for `bump`.
    ///
    /// - Blocking: runs git and reads the committed appcast.
    public func plan(bump: AppVersion.Bump, liveFeed: [AppcastItem] = []) throws -> Plan {
        let local = Appcast.items(at: workspace.appcastURL)
        let current = Self.currentVersion(appcasts: [local, liveFeed], tags: try tags())
        let commitCount = Int(try Shell.capture(["git", "rev-list", "--count", "HEAD"], cwd: workspace.root)) ?? 1
        let build = Self.nextBuild(commitCount: commitCount, appcasts: [local, liveFeed])
        return Plan(current: current, next: current.bumped(bump), bump: bump, build: build)
    }

    /// - Blocking: runs git.
    public func headCommitMessage() throws -> CommitMessage {
        CommitMessage(try Shell.capture(["git", "log", "-1", "--format=%B"], cwd: workspace.root))
    }

    /// The version the last release shipped, which dev builds carry until the next one.
    ///
    /// - Blocking: runs git and reads the committed appcast.
    public func shippedVersion() throws -> AppVersion {
        Self.currentVersion(
            appcasts: [Appcast.items(at: workspace.appcastURL)], tags: try tags())
    }

    /// - Blocking: runs git.
    private func tags() throws -> [String] {
        try Shell.capture(["git", "tag", "--list"], cwd: workspace.root, allowFailure: true)
            .split(separator: "\n").map(String.init)
    }

    /// The highest of every published version and tag, or 1.0.0 for a first release.
    public static func currentVersion(appcasts: [[AppcastItem]], tags: [String]) -> AppVersion {
        let published = appcasts.flatMap { $0 }.compactMap { AppVersion($0.displayVersion) }
        let tagged = tags.filter { $0.matches(pattern: #"^v?\d+\.\d+\.\d+$"#) }.compactMap { AppVersion($0) }
        return (published + tagged).max() ?? AppVersion(major: 1, minor: 0, patch: 0)
    }

    /// The commit count, raised above every build number already published so Sparkle always sees an upgrade.
    public static func nextBuild(commitCount: Int, appcasts: [[AppcastItem]]) -> Int {
        let published = appcasts.flatMap { $0 }.compactMap { $0.build.flatMap { Int($0) } }.max() ?? 0
        return max(commitCount, published + 1)
    }
}
