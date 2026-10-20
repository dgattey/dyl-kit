import DylToolSupport
import Foundation

/// The release as separate steps, so a CI wrapper can run them one at a time: `version`, `bundle`, `sign`,
/// `appcast`, `check`, `publish`. Each step reads what the earlier ones left in `build/release/`. `publish` commits
/// the artifacts and tags the release with plain git, so any forge (or none) can host it.
public struct ReleasePipeline: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    public var stagingDir: URL { workspace.buildDir.appending(path: "release") }
    private var planFile: URL { stagingDir.appending(path: "plan.json") }
    private var stageDir: URL { stagingDir.appending(path: "stage") }

    /// What `version` decided, shared with every later step.
    public struct State: Codable, Equatable, Sendable {
        public var version: String
        public var build: Int
        public var subject: String
        public var body: String

        public init(version: String, build: Int, subject: String, body: String) {
            self.version = version
            self.build = build
            self.subject = subject
            self.body = body
        }
    }

    // MARK: Steps

    /// Plans the release from the merged PR's body (`prBody`, which the forge wrapper fetched; the merge commit
    /// message when that lookup failed), tags and the live feed, then resets `build/release/` around the new plan.
    ///
    /// - Blocking: runs git and writes the plan.
    public func version(explicitBump: AppVersion.Bump?, prBody: String? = nil) async throws -> State {
        let liveFeed = await LiveFeed.fetch(workspace.manifest.release.feedURL)
        let planner = VersionPlanner(workspace: workspace)
        let head = try planner.headCommitMessage()
        try fastForwardToRemote()
        if prBody == nil { Log.warn("no PR body from the forge; reading `# Release info` from the merge commit") }
        let subject = head.subject
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
        let plan = try planner.plan(bump: bump, liveFeed: liveFeed)
        let state = State(version: plan.next.description, build: plan.build, subject: subject, body: body)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: stagingDir)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: planFile)
        Log.step("releasing \(plan.next) (build \(plan.build), \(plan.bump.rawValue) bump from \(plan.current))")
        return state
    }

    /// - Blocking: reads the plan.
    public func state() throws -> State {
        guard let data = try? Data(contentsOf: planFile) else {
            throw ToolError("no release plan at \(planFile.path); run `release-kit version` first")
        }
        return try JSONDecoder().decode(State.self, from: data)
    }

    /// - Blocking: builds the release bundle.
    @discardableResult
    public func bundle() throws -> URL {
        let state = try state()
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        return try Bundler(workspace: workspace)
            .bundle(configuration: .release, shortVersion: state.version, build: String(state.build), into: stageDir)
    }

    /// Signs the staged app inside-out, verifies it, and zips it for Sparkle.
    ///
    /// - Blocking: runs codesign and ditto.
    @discardableResult
    public func sign() throws -> URL {
        let state = try state()
        let manifest = workspace.manifest
        let app = stagedApp
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw ToolError("no staged app at \(app.path); run `release-kit bundle` first")
        }
        let signer = Signer(
            entitlements: workspace.url(manifest.build.entitlements),
            bundleIdentifier: manifest.app.bundleId
        )
        try signer.sign(app)
        try signer.verify(app)
        let archive = archiveURL(state)
        try? FileManager.default.removeItem(at: archive)
        try Shell.run(["ditto", "-c", "-k", "--keepParent", app.path, archive.path])
        return archive
    }

    /// Writes the notes, runs Sparkle's `generate_appcast`, fails closed unless the new signature verifies against
    /// the key baked into the app, runs the release checks against the staged feed, then installs the archive and
    /// feed into the artifacts directory.
    ///
    /// - Blocking: runs Sparkle's tools and writes artifacts.
    @discardableResult
    public func appcast(edKeyFile: URL) async throws -> URL {
        let state = try state()
        let archive = archiveURL(state)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw ToolError("no archive at \(archive.path); run `release-kit sign` first")
        }
        let liveFeed = await LiveFeed.fetch(workspace.manifest.release.feedURL)
        let notes = try releaseNotes(state: state, history: [liveFeed])
        try Data((notes + "\n").utf8).write(
            to: stagingDir.appending(path: "\(workspace.manifest.app.name)-\(state.version).html"))
        let appcast = try generateAppcast(edKeyFile: edKeyFile)
        try verifySignature(appcast: appcast, archive: archive, app: stagedApp)
        try install(archive: archive, appcast: appcast, liveFeed: liveFeed)
        return appcast
    }

    /// Release checks against the staged feed, then copies the archive and feed into the artifacts directory.
    private func install(archive: URL, appcast: URL, liveFeed: [AppcastItem]) throws {
        let report = ReleaseChecks(workspace: workspace)
            .run(stagedAppcast: appcast, stagedArchive: archive, liveFeed: liveFeed)
        report.print()
        guard report.passed else { throw ToolError("release checks failed") }

        let fileManager = FileManager.default
        let artifacts = workspace.artifactsDir
        try fileManager.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let prefix = "\(workspace.manifest.app.name)-"
        for old in try fileManager.contentsOfDirectory(atPath: artifacts.path)
        where old.hasPrefix(prefix) && old.hasSuffix(".zip") {
            try fileManager.removeItem(at: artifacts.appending(path: old))
        }
        try fileManager.copyItem(at: archive, to: artifacts.appending(path: archive.lastPathComponent))
        let destination = workspace.appcastURL
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: appcast, to: destination)
        Log.step("wrote \(workspace.manifest.release.artifactsDir)/\(archive.lastPathComponent) and appcast.xml")
    }

    /// Commits the artifacts, tags `v<version>`, and pushes both atomically to the current branch.
    ///
    /// - Blocking: runs git.
    public func publish(push: Bool) throws {
        let version = try state().version
        let root = workspace.root
        try Shell.run(["git", "add", workspace.manifest.release.artifactsDir], cwd: root)
        let staged = try Shell.run(["git", "diff", "--staged", "--quiet"], cwd: root, allowFailure: true)
        guard staged != 0 else {
            Log.step("no artifact changes to publish")
            return
        }
        try Shell.run(["git", "commit", "-m", "Release v\(version)"], cwd: root)
        try Shell.run(["git", "tag", "v\(version)"], cwd: root)
        guard push else { return }
        let branch = try Shell.capture(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: root)
        try Shell.run(["git", "push", "--atomic", "origin", "HEAD:\(branch)", "refs/tags/v\(version)"], cwd: root)
    }

    // MARK: Helpers

    /// A queued release job checks out its own merge commit, behind the release an earlier job pushed, so `publish`
    /// would push a non-fast-forward. Catch up before planning, so tags and the committed appcast are current too.
    /// Branches that aren't on `origin` are left alone.
    private func fastForwardToRemote() throws {
        let root = workspace.root
        let branch = try Shell.capture(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: root)
        guard branch != "HEAD" else { return }
        let lookup = ["git", "ls-remote", "--quiet", "--exit-code", "--heads", "origin", branch]
        guard try Shell.run(lookup, cwd: root, allowFailure: true) == 0 else { return }
        try Shell.run(["git", "pull", "--ff-only", "--quiet", "origin", branch], cwd: root)
    }

    private var stagedApp: URL { stageDir.appending(path: "\(workspace.manifest.app.name).app") }

    private func archiveURL(_ state: State) -> URL {
        stagingDir.appending(path: "\(workspace.manifest.app.name)-\(state.version).zip")
    }

    /// Cumulative HTML notes for the planned version, carrying forward the committed and live feeds.
    ///
    /// - Blocking: reads the committed appcast and its git history, and lists `Sources/`.
    public func releaseNotes(state: State, history: [[AppcastItem]]) throws -> String {
        let markdown = ReleaseInfo.notesMarkdown(body: state.body, fallbackTitle: state.subject)
        let modules = (try? FileManager.default.contentsOfDirectory(atPath: workspace.url("Sources").path)) ?? []
        let formatter = NotesFormatter(pathRoots: NotesFormatter.defaultPathRoots + modules.sorted())
        let local = Appcast.items(at: workspace.appcastURL)
        return CumulativeNotes.html(
            version: state.version,
            build: String(state.build),
            newNotes: formatter.html(markdown, version: state.version),
            history: [local] + history,
            knownBuilds: try committedBuilds()
        )
    }

    /// The build each committed revision of the appcast shipped, keyed by version. Notes written before sections
    /// carried build stamps get theirs from here; once carried forward, the stamps travel with the notes.
    ///
    /// - Blocking: runs git.
    private func committedBuilds() throws -> [String: String] {
        let path = workspace.appcastPath
        let revisions = try Shell.capture(
            ["git", "log", "--format=%H", "--", path], cwd: workspace.root, allowFailure: true)
        var builds: [String: String] = [:]
        for revision in revisions.split(separator: "\n") {
            let xml = try Shell.capture(["git", "show", "\(revision):\(path)"], cwd: workspace.root, allowFailure: true)
            for item in Appcast.items(in: Data(xml.utf8)) where builds[item.displayVersion] == nil {
                builds[item.displayVersion] = item.build
            }
        }
        return builds
    }

    private func generateAppcast(edKeyFile: URL) throws -> URL {
        let tool = workspace.sparkleTool("generate_appcast")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw ToolError("\(tool.path) is missing; run `swift build` so SwiftPM unpacks Sparkle")
        }
        let feed = stagingDir.appending(path: "feed")
        try? FileManager.default.removeItem(at: feed)
        try FileManager.default.createDirectory(at: feed, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
        where name.hasSuffix(".zip") || name.hasSuffix(".html") {
            try FileManager.default.copyItem(at: stagingDir.appending(path: name), to: feed.appending(path: name))
        }
        let site = workspace.manifest.release.siteUrl
        let prefix = site.hasSuffix("/") ? site : site + "/"
        // The site's notes section lists every version the appcast carries, so it's the dialog's "full notes" link.
        try Shell.run([
            tool.path, "--embed-release-notes", "--disable-signing-warning", "--download-url-prefix", prefix,
            "--link", site, "--full-release-notes-url", prefix + "#release-notes", "--ed-key-file", edKeyFile.path,
            feed.path,
        ])
        let appcast = stagingDir.appending(path: "appcast.xml")
        try? FileManager.default.removeItem(at: appcast)
        try FileManager.default.moveItem(at: feed.appending(path: "appcast.xml"), to: appcast)
        try? FileManager.default.removeItem(at: feed)
        return appcast
    }

    private func verifySignature(appcast: URL, archive: URL, app: URL) throws {
        guard let item = Appcast.items(at: appcast).first, let signature = item.edSignature, !signature.isEmpty else {
            throw ToolError("generate_appcast wrote no sparkle:edSignature to \(appcast.path)")
        }
        guard let publicKey = InfoPlist.read(app.appending(path: "Contents/Info.plist"))?["SUPublicEDKey"]?.string
        else { throw ToolError("SUPublicEDKey is missing from the built Info.plist") }
        switch EdSignature.verify(archive: try Data(contentsOf: archive), signature: signature, publicKey: publicKey) {
        case .valid: Log.step("edSignature verifies against SUPublicEDKey")
        case .invalid(let reason): throw ToolError("edSignature check failed: \(reason) (private/public key mismatch?)")
        case .unverifiable: throw ToolError("can't verify edSignature on this platform; release from macOS")
        }
    }

    /// The Sparkle private key: an explicit file, `SPARKLE_ED_PRIVATE_KEY_BASE64` (CI), or a repo-local key file.
    ///
    /// - Blocking: reads and may write a temporary key file.
    public func resolveEdKey(explicit: String?) throws -> URL {
        if let path = explicit {
            guard FileManager.default.fileExists(atPath: path) else { throw ToolError("no Sparkle key at \(path)") }
            return URL(fileURLWithPath: path)
        }
        let environment = ProcessInfo.processInfo.environment
        if let encoded = environment["SPARKLE_ED_PRIVATE_KEY_BASE64"] {
            let key = try Self.edKeyFile(fromSecret: encoded)
            let file = FileManager.default.temporaryDirectory.appending(path: "dylkit-sparkle-\(UUID().uuidString).key")
            try key.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            workspace.url(".cert/sparkle_ed.key"),
            workspace.url("sparkle_private.key"),
            home.appending(path: ".config/\(workspace.manifest.app.name.lowercased())/sparkle_ed.key"),
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ToolError(
                "no Sparkle private key: pass --ed-key-file, set SPARKLE_ED_PRIVATE_KEY_BASE64, or add .cert/sparkle_ed.key"
            )
        }
        return found
    }

    /// `sign_update --ed-key-file` reads the base64 text that `generate_keys -x` exports. The CI secret holds either
    /// that text or that text base64-encoded again; an Ed25519 key is 32 or 64 bytes, which tells them apart.
    static func edKeyFile(fromSecret secret: String) throws -> Data {
        let compact = secret.filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: compact) else {
            throw ToolError("SPARKLE_ED_PRIVATE_KEY_BASE64 isn't valid base64")
        }
        return [32, 64].contains(decoded.count) ? Data(compact.utf8) : decoded
    }
}
