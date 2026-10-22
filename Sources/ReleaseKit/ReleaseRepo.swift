import DylToolSupport
import Foundation

/// What every release shares, an app's or DylKit's own: a checkout whose tags carry the versions, the Blob store its
/// files go to, and the plan `version` leaves in `build/release/plan.json` for the later steps.
public struct ReleaseRepo: Sendable {
    public let root: URL
    let environment: [String: String]
    let transport: any HTTPTransport

    public init(
        root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.root = root
        self.environment = environment
        self.transport = transport
    }

    public var stagingDir: URL { root.appending(path: "build/release") }
    private var planFile: URL { stagingDir.appending(path: "plan.json") }

    /// Plans the release from the merged PR's body (the merge commit message when there's no PR or GitHub can't
    /// return it), the tags and `published`, then resets `build/release/` around the new plan. A release tag already at
    /// HEAD is resumed instead (see `ReleasePipeline.plan`).
    ///
    /// - Blocking: runs git and writes the plan.
    public func version(
        explicitBump: AppVersion.Bump?, pullRequest: Int?, published: [AppcastItem]
    ) async throws -> ReleasePipeline.State {
        let prBody = await pullRequestBody(pullRequest)
        try Shell.run(["git", "fetch", "--quiet", "--tags", "origin"], cwd: root, allowFailure: true)
        let head = CommitMessage(try Shell.capture(["git", "log", "-1", "--format=%B"], cwd: root))
        let body: String
        let bump: AppVersion.Bump
        if let explicitBump {
            body = prBody ?? head.body
            bump = explicitBump
        } else {
            let source = try ReleaseInfo.source(prBody: prBody, commitBody: head.body)
            body = source.body
            bump = source.bump
        }
        let commitCount = Int(try Shell.capture(["git", "rev-list", "--count", "HEAD"], cwd: root)) ?? 1
        let plan = ReleasePipeline.plan(
            headTags: try tags("--points-at", "HEAD"), tags: try tags("--list"), published: published,
            commitCount: commitCount, bump: bump)
        let state: ReleasePipeline.State
        switch plan {
        case .next(let version, let build, let current):
            state = .init(version: version.description, build: build, subject: head.subject, body: body)
            Log.step("releasing \(version) (build \(build), \(bump.rawValue) bump from \(current))")
        case .resumed(let version, let build):
            state = .init(version: version.description, build: build, subject: head.subject, body: body)
            Log.step("HEAD is already tagged \(state.tag); resuming that release (build \(build))")
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: stagingDir)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: planFile)
        return state
    }

    /// - Blocking: reads the plan.
    public func state() throws -> ReleasePipeline.State {
        guard let data = try? Data(contentsOf: planFile) else {
            throw ToolError("no release plan at \(planFile.path); run `release-kit version` first")
        }
        return try JSONDecoder().decode(ReleasePipeline.State.self, from: data)
    }

    /// Tags HEAD `v<version>` (lightweight) unless that tag already points at it, pushes the tag, and uploads the
    /// release's `files`, the site's `icons` and the store root's `latest` to the Blob store at `assets` (see
    /// `BlobStore.publish`), returning their URLs. Re-running after a partial publish finishes it.
    ///
    /// - Blocking: runs git.
    @discardableResult
    public func publish(
        _ files: [URL], icons: [URL] = [], latest: [URL] = [], assets: String? = nil
    ) async throws -> [String] {
        let state = try state()
        for file in files + icons + latest where !FileManager.default.fileExists(atPath: file.path) {
            throw ToolError("no \(file.path) to publish")
        }
        let store = try BlobStore(environment: environment, transport: transport)
        let head = try Shell.capture(["git", "rev-parse", "HEAD"], cwd: root)
        let tagged = try Shell.capture(
            ["git", "rev-parse", "--quiet", "--verify", "refs/tags/\(state.tag)^{commit}"], cwd: root,
            allowFailure: true)
        if tagged.isEmpty {
            try Shell.run(["git", "tag", state.tag], cwd: root)
        } else if tagged != head {
            throw ToolError("\(state.tag) already tags \(tagged), not HEAD (\(head))")
        }
        try Shell.run(["git", "push", "origin", "refs/tags/\(state.tag)"], cwd: root)
        return try await store.publish(tag: state.tag, files: files, icons: icons, latest: latest, assets: assets)
    }

    /// - Blocking: runs git.
    func tags(_ selection: String...) throws -> [String] {
        try Shell.capture(["git", "tag"] + selection, cwd: root, allowFailure: true)
            .split(separator: "\n").map(String.init)
    }

    private func pullRequestBody(_ number: Int?) async -> String? {
        let fallback = "reading `# Release info` from the merge commit"
        guard let number else {
            Log.warn("no --pr; \(fallback)")
            return nil
        }
        do {
            let body = try await GitHub(environment: environment, transport: transport).pullRequestBody(number: number)
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
        } catch {
            Log.warn("couldn't read PR #\(number) from GitHub (\(error)); \(fallback)")
            return nil
        }
    }
}
