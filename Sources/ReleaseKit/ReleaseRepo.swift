import DylToolSupport
import Foundation
import ReleaseNotes

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
    /// return it), the tags and `published`, then resets `build/release/` around the new plan. Earlier merges that
    /// never released fold in (see `unreleasedMerges`). A release tag already at HEAD is resumed instead (see
    /// `ReleasePipeline.plan`).
    ///
    /// - Blocking: runs git and writes the plan.
    public func version(
        explicitBump: AppVersion.Bump?, pullRequest: Int?, published: [AppcastItem]
    ) async throws -> ReleasePipeline.State {
        let prBody = await pullRequestBody(pullRequest)
        try Shell.run(["git", "fetch", "--quiet", "--tags", "origin"], cwd: root, allowFailure: true)
        let head = CommitMessage(try Shell.capture(["git", "log", "-1", "--format=%B"], cwd: root))
        var body: String
        var bump: AppVersion.Bump
        if let explicitBump {
            body = prBody ?? head.body
            bump = explicitBump
        } else {
            let source = try ReleaseInfo.source(prBody: prBody, commitBody: head.body)
            body = source.body
            bump = source.bump
        }
        // The PR check already rejected these; a release still ships rather than strand a merged PR.
        for problem in ReleaseNotes.problems(inBody: body) { Log.warn("Release notes: \(problem)") }
        let earlier = try await unreleasedMerges()
        if !earlier.isEmpty {
            Log.step("also releasing \(earlier.map(\.subject).joined(separator: "; ")), merged without a release")
            let folded = ReleaseInfo.folded([.init(subject: head.subject, body: body, bump: bump)] + earlier)
            body = folded.body
            if explicitBump == nil { bump = folded.bump }
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
    /// `BlobStore.publish`), returning their URLs. Re-running after a partial publish finishes it. With `dryRun`, it
    /// makes the same checks and returns the pathnames it would upload to, and tags, pushes and uploads nothing.
    ///
    /// - Blocking: runs git.
    @discardableResult
    public func publish(
        _ files: [URL], icons: [URL] = [], latest: [URL] = [], assets: String? = nil, dryRun: Bool = false
    ) async throws -> [String] {
        let state = try state()
        for file in files + icons + latest where !FileManager.default.fileExists(atPath: file.path) {
            throw ToolError("no \(file.path) to publish")
        }
        let store = dryRun ? nil : try BlobStore(environment: environment, transport: transport)
        let head = try Shell.capture(["git", "rev-parse", "HEAD"], cwd: root)
        let tagged = try Shell.capture(
            ["git", "rev-parse", "--quiet", "--verify", "refs/tags/\(state.tag)^{commit}"], cwd: root,
            allowFailure: true)
        if !tagged.isEmpty, tagged != head {
            throw ToolError("\(state.tag) already tags \(tagged), not HEAD (\(head))")
        }
        guard let store else {
            let count = files.count + icons.count + latest.count
            Log.step("dry run: would tag HEAD \(state.tag), push it, and upload \(count) files")
            return BlobStore.uploads(tag: state.tag, files: files, icons: icons, latest: latest).map(\.1)
        }
        if tagged.isEmpty { try Shell.run(["git", "tag", state.tag], cwd: root) }
        try Shell.run(["git", "push", "origin", "refs/tags/\(state.tag)"], cwd: root)
        return try await store.publish(tag: state.tag, files: files, icons: icons, latest: latest, assets: assets)
    }

    /// - Blocking: runs git.
    func tags(_ selection: String...) throws -> [String] {
        try Shell.capture(["git", "tag"] + selection, cwd: root, allowFailure: true)
            .split(separator: "\n").map(String.init)
    }

    /// Merges since the last release tag before HEAD that have none of their own, newest first. A concurrency group
    /// keeps one pending run and cancels any older one, so when merges land while a release runs, only the newest
    /// releases. Merges that only touch docs, the site, tests or CI never release, and those without a Release info box
    /// are left out. Only commits on origin's default branch count, so on a PR branch its own commits, which squash
    /// into one merge, are skipped.
    ///
    /// - Blocking: runs git.
    private func unreleasedMerges() async throws -> [ReleaseInfo.Merge] {
        let base = try Shell.capture(
            ["git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD^"], cwd: root, allowFailure: true)
        guard !base.isEmpty else { return [] }
        var merges: [ReleaseInfo.Merge] = []
        let landed = try landedBeforeHead()
        let commits = try Shell.capture(["git", "rev-list", "--first-parent", "\(base)..\(landed)"], cwd: root)
        for commit in commits.split(separator: "\n").map(String.init) {
            let files = try Shell.capture(["git", "diff", "--name-only", "\(commit)^", commit], cwd: root)
            guard files.split(separator: "\n").contains(where: { !Self.neverReleases($0) }) else { continue }
            let raw = try Shell.capture(["git", "log", "-1", "--format=%B", commit], cwd: root)
            let message = CommitMessage(raw)
            let number = ReleaseInfo.pullRequestNumber(in: raw)
            let prBody = number == nil ? nil : await pullRequestBody(number)
            guard let source = try? ReleaseInfo.source(prBody: prBody, commitBody: message.body) else {
                Log.warn("\(message.subject) has no Release info box; leaving it out of this release")
                continue
            }
            merges.append(.init(subject: message.subject, body: source.body, bump: source.bump))
        }
        return merges
    }

    /// The newest commit before HEAD on origin's default branch: HEAD^ when HEAD is a merge into it, or where a PR
    /// branch left it. HEAD^ when origin can't be read.
    ///
    /// - Blocking: runs git, over the network.
    private func landedBeforeHead() throws -> String {
        let fetched = try Shell.run(
            ["git", "fetch", "--quiet", "--no-tags", "origin", "HEAD"], cwd: root, quiet: true, allowFailure: true)
        guard fetched == 0 else { return "HEAD^" }
        let landed = try Shell.capture(["git", "merge-base", "HEAD^", "FETCH_HEAD"], cwd: root, allowFailure: true)
        return landed.isEmpty ? "HEAD^" : landed
    }

    /// Paths that never release on their own, as app.yml's `changes` job decides, except the workflows apps call,
    /// which DylKit ships.
    private static func neverReleases(_ path: Substring) -> Bool {
        path.wholeMatch(of: #/\.github\/workflows\/(app|release-info)\.yml/#) == nil
            && path.wholeMatch(of: #/.*\.md|(docs|server|Tests|\.github|\.cursor)\/.*/#) != nil
    }

    private func pullRequestBody(_ number: Int?) async -> String? {
        let fallback = "reading `# Release info` from the merge commit"
        guard let number else {
            Log.warn("no --pr; \(fallback)")
            return nil
        }
        do {
            let github = try GitHub(environment: GitHub.filling(environment, from: root), transport: transport)
            let body = try await github.pullRequestBody(number: number)
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
        } catch {
            Log.warn("couldn't read PR #\(number) from GitHub (\(error)); \(fallback)")
            return nil
        }
    }
}
