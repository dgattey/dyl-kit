import DylToolSupport
import Foundation

/// The release as separate steps, so a CI wrapper can run them one at a time: `version`, `bundle`, `sign`,
/// `appcast`, `publish`. Each step reads what the earlier ones left in `build/release/`. `publish` pushes the
/// tag with plain git and uploads the zip, the site's icons, the appcast and `release.json` to the app's Blob store;
/// nothing is committed.
public struct ReleasePipeline: Sendable {
    public let workspace: Workspace
    let repo: ReleaseRepo
    private let transport: any HTTPTransport

    public init(workspace: Workspace, transport: any HTTPTransport = URLSessionTransport()) {
        self.workspace = workspace
        self.transport = transport
        repo = ReleaseRepo(root: workspace.root, transport: transport)
    }

    private var assets: String { workspace.manifest.release.assets }
    /// Where the release `tag`'s zip is served from, ending in `/`.
    func downloadPrefix(tag: String) -> String { "\(assets)/releases/\(tag)/" }
    /// The newest published release's feed, which each publish replaces.
    var latestAppcastURL: String { "\(assets)/appcast.xml" }
    /// Every release's notes, which each publish appends to.
    var latestHistoryURL: String { "\(assets)/history.json" }
    /// The site's page with every version's notes, where Sparkle's full-notes link and the end of each update's notes
    /// point. An update's own notes stop at ten versions.
    var allReleasesURL: String { workspace.manifest.release.siteUrl + "/releases" }
    public var stagingDir: URL { repo.stagingDir }
    var stagedAppcast: URL { stagingDir.appending(path: "appcast.xml") }
    var stagedReleaseJSON: URL { stagingDir.appending(path: "release.json") }
    public var stagedHistory: URL { stagingDir.appending(path: "history.json") }
    var stagedIcons: URL { stagingDir.appending(path: "icons") }
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

        var tag: String { "v\(version)" }
    }

    /// Every item installs can be offered: the site's feed, which `SUFeedURL` polls, then the Blob store's latest feed.
    /// Each is read strictly (see `Appcast.published`).
    public func publishedFeeds() async throws -> [AppcastItem] {
        async let site = Appcast.published(workspace.manifest.release.feedURL, transport: transport)
        async let latest = Appcast.published(latestAppcastURL, transport: transport)
        return try await site + latest
    }

    // MARK: Steps

    /// Plans the release against the published feeds (see `ReleaseRepo.version`).
    ///
    /// - Blocking: runs git and writes the plan.
    public func version(explicitBump: AppVersion.Bump?, pullRequest: Int?) async throws -> State {
        try await repo.version(
            explicitBump: explicitBump, pullRequest: pullRequest, published: try await publishedFeeds())
    }

    /// What `version` decides.
    enum Plan: Equatable {
        /// The current version bumped, at the next build.
        case next(AppVersion, build: Int, bumpedFrom: AppVersion)
        /// The version a release tag at HEAD names. Only `publish` tags, so an earlier run of this release got that far;
        /// GitHub re-runs whole jobs, and bumping again would publish the same commit twice.
        case resumed(AppVersion, build: Int)
    }

    /// A resumed release keeps the build it published with, or takes the next build when it never went out.
    static func plan(
        headTags: [String], tags: [String], published: [AppcastItem], commitCount: Int, bump: AppVersion.Bump
    ) -> Plan {
        let build = nextBuild(commitCount: commitCount, published: published)
        let tagged = headTags.filter { $0.matches(pattern: #"^v\d+\.\d+\.\d+$"#) }.compactMap { AppVersion($0) }
        if let version = tagged.max() {
            let shipped = published.filter { AppVersion($0.displayVersion) == version }.newest
            return .resumed(version, build: shipped?.build ?? build)
        }
        let current = currentVersion(published: published, tags: tags)
        return .next(current.bumped(bump), build: build, bumpedFrom: current)
    }

    /// The version the last release shipped, which dev builds carry until the next one: the highest of the published
    /// feeds and the local tags. Checkouts that only fetch their branch never get new tags, so the feeds come first;
    /// when they can't be read, offline say, the tags decide.
    ///
    /// - Blocking: reads the published feeds and runs git.
    public func shippedVersion() async throws -> AppVersion {
        let published: [AppcastItem]
        do {
            published = try await publishedFeeds()
        } catch {
            Log.step("\(error); the version comes from local tags")
            published = []
        }
        return Self.currentVersion(published: published, tags: try repo.tags("--list"))
    }

    /// The highest of every published version and tag, or 1.0.0 for a first release.
    static func currentVersion(published: [AppcastItem], tags: [String]) -> AppVersion {
        let shipped = published.compactMap { AppVersion($0.displayVersion) }
        let tagged = tags.filter { $0.matches(pattern: #"^v?\d+\.\d+\.\d+$"#) }.compactMap { AppVersion($0) }
        return (shipped + tagged).max() ?? AppVersion(major: 1, minor: 0, patch: 0)
    }

    /// The commit count, raised above every build number already published so Sparkle always sees an upgrade.
    static func nextBuild(commitCount: Int, published: [AppcastItem]) -> Int {
        max(commitCount, (published.newest?.build ?? 0) + 1)
    }

    /// Publishing must never offer installs an older build than they can already get. Equal is a re-run of a publish
    /// that already went out.
    static func refuseRegression(staged: [AppcastItem], published: [AppcastItem]) throws {
        guard let stagedBuild = staged.newest?.build else { throw ToolError("the staged appcast has no items") }
        if let publishedBuild = published.newest?.build, stagedBuild < publishedBuild {
            throw ToolError(
                "staged build \(stagedBuild) is below the published build \(publishedBuild); a newer release shipped "
                    + "after `release-kit version` planned this one")
        }
    }

    /// - Blocking: reads the plan.
    public func state() throws -> State { try repo.state() }

    /// - Blocking: builds the release bundle.
    @discardableResult
    public func bundle() throws -> URL {
        let state = try state()
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let app = try Bundler(workspace: workspace)
            .bundle(
                configuration: .release, identity: .release, shortVersion: state.version, build: String(state.build),
                into: stageDir)
        try SiteIcons(workspace: workspace).write(into: stagedIcons)
        return app
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

    /// Writes the notes, runs Sparkle's `generate_appcast` with enclosures on the Blob store, fails closed unless the new
    /// signature verifies against the key baked into the app, runs the release checks against the published feeds,
    /// then writes `release.json` and `history.json` beside the appcast.
    ///
    /// - Blocking: runs Sparkle's tools and writes into `build/release/`.
    @discardableResult
    public func appcast(edKeyFile: URL?) async throws -> URL {
        let state = try state()
        let archive = archiveURL(state)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw ToolError("no archive at \(archive.path); run `release-kit sign` first")
        }
        let published = try await publishedFeeds()
        let notes = releaseNotes(state: state, history: published)
        try Data((notes + "\n").utf8).write(
            to: stagingDir.appending(path: "\(workspace.manifest.app.name)-\(state.version).html"))
        let appcast = try generateAppcast(edKeyFile: edKeyFile, downloadPrefix: downloadPrefix(tag: state.tag))
        try verifySignature(appcast: appcast, archive: archive, app: stagedApp)
        let report = ReleaseChecks(workspace: workspace).run(staged: stagedRelease(state, published: published))
        report.print()
        guard report.passed else { throw ToolError("release checks failed") }
        guard let item = try Appcast.items(at: appcast).newest else { throw ToolError("\(appcast.path) has no items") }
        try PublishedRelease(item).write(to: stagedReleaseJSON)
        Log.step("wrote \(stagedReleaseJSON.path)")
        let history = try await ReleaseHistory.published(latestHistoryURL, transport: transport)
        try ReleaseHistory.next(published: history, staged: item, feeds: published).write(to: stagedHistory)
        Log.step("wrote \(stagedHistory.path)")
        return appcast
    }

    func stagedRelease(_ state: State, published: [AppcastItem]) -> ReleaseChecks.StagedRelease {
        ReleaseChecks.StagedRelease(
            appcast: stagedAppcast, archive: archiveURL(state), downloadPrefix: downloadPrefix(tag: state.tag),
            published: published)
    }

    /// Publishes the staged zip, the site icons, then `history.json`, the appcast and `release.json` as the latest (see
    /// `ReleaseRepo.publish`), unless that would offer an older build than the published feeds.
    ///
    /// - Blocking: runs git.
    public func publish() async throws {
        let state = try state()
        let latest = [stagedHistory, stagedAppcast, stagedReleaseJSON]
        let icons = SiteIcons.all.map { stagedIcons.appending(path: $0.name) }
        for file in [archiveURL(state)] + latest where !FileManager.default.fileExists(atPath: file.path) {
            throw ToolError("no \(file.path); run `release-kit appcast` first")
        }
        for file in icons where !FileManager.default.fileExists(atPath: file.path) {
            throw ToolError("no \(file.path); run `release-kit bundle` first")
        }
        try Self.refuseRegression(staged: try Appcast.items(at: stagedAppcast), published: try await publishedFeeds())
        try await repo.publish([archiveURL(state)], icons: icons, latest: latest, assets: assets)
    }

    // MARK: Helpers

    var stagedApp: URL { stageDir.appending(path: "\(workspace.manifest.app.name).app") }

    func archiveURL(_ state: State) -> URL {
        stagingDir.appending(path: "\(workspace.manifest.app.name)-\(state.version).zip")
    }

    /// Cumulative HTML notes for the planned version, carrying forward the published feeds.
    ///
    /// - Blocking: lists `Sources/`.
    public func releaseNotes(state: State, history: [AppcastItem]) -> String {
        let markdown = ReleaseInfo.notesMarkdown(body: state.body, fallbackTitle: state.subject)
        return CumulativeNotes.html(
            version: state.version,
            build: String(state.build),
            newNotes: notesFormatter.html(markdown, version: state.version),
            history: history,
            allNotesURL: allReleasesURL
        )
    }

    /// - Blocking: lists `Sources/`.
    private var notesFormatter: NotesFormatter {
        let modules = (try? FileManager.default.contentsOfDirectory(atPath: workspace.url("Sources").path)) ?? []
        return NotesFormatter(pathRoots: NotesFormatter.defaultPathRoots + modules.sorted())
    }

    // MARK: History backfill

    /// Builds `history.json` for an app whose releases predate it: the published history, then every version the
    /// published feeds and `appcasts` (older feeds, as paths or URLs) describe, then the GitHub Releases of `gitHubRepo`
    /// (default `GITHUB_REPOSITORY`; needs `GITHUB_TOKEN`). Earlier sources win, and newer feeds before older ones, so
    /// re-running converges. Writes `build/release/history.json` and returns it.
    ///
    /// - Blocking: reads the appcasts and writes the file.
    public func backfillHistory(appcasts: [String], gitHubRepo: String?) async throws -> URL {
        var items = try await publishedFeeds()
        for source in appcasts {
            items += source.hasPrefix("https://") || source.hasPrefix("http://")
                ? try await Appcast.published(source, transport: transport)
                : try Appcast.items(at: URL(fileURLWithPath: source))
        }
        var history = try await ReleaseHistory.published(latestHistoryURL, transport: transport)
            .filling(items.sorted { $0.build > $1.build }.flatMap(ReleaseHistory.entries(from:)))
        if let name = gitHubRepo ?? repo.environment["GITHUB_REPOSITORY"] {
            var environment = repo.environment
            environment["GITHUB_REPOSITORY"] = name
            let releases = try await GitHub(environment: environment, transport: transport).releases()
            history = history.filling(ReleaseHistory.entries(from: releases, formatter: notesFormatter))
        } else {
            Log.step("no GitHub repo; the history has only what the appcasts carry")
        }
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try history.write(to: stagedHistory)
        let withNotes = history.releases.filter { !$0.html.isEmpty }.count
        Log.step("wrote \(stagedHistory.path): \(history.releases.count) releases, \(withNotes) with notes")
        return stagedHistory
    }

    /// Uploads the backfilled `history.json` to the Blob store root.
    public func publishHistory() async throws {
        guard FileManager.default.fileExists(atPath: stagedHistory.path) else {
            throw ToolError("no \(stagedHistory.path); run `release-kit history` first")
        }
        _ = try await BlobStore(environment: repo.environment, transport: transport)
            .publish(root: [stagedHistory], assets: assets)
    }

    private func generateAppcast(edKeyFile: URL?, downloadPrefix: String) throws -> URL {
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
        // The feed holds only this release: Sparkle offers the newest item a Mac can run, whatever build it's on, and
        // shows only that item's notes. Its "Version History" button opens the full-notes link.
        let key = edKeyFile.map { ["--ed-key-file", $0.path] } ?? []
        try Shell.run(
            [
                tool.path, "--embed-release-notes", "--disable-signing-warning", "--download-url-prefix", downloadPrefix,
                "--link", workspace.manifest.release.siteUrl, "--full-release-notes-url", allReleasesURL,
            ] + key + [feed.path])
        try? FileManager.default.removeItem(at: stagedAppcast)
        try FileManager.default.moveItem(at: feed.appending(path: "appcast.xml"), to: stagedAppcast)
        try? FileManager.default.removeItem(at: feed)
        return stagedAppcast
    }

    private func verifySignature(appcast: URL, archive: URL, app: URL) throws {
        guard let publicKey = InfoPlist.read(app.appending(path: "Contents/Info.plist"))?["SUPublicEDKey"]?.string
        else { throw ToolError("SUPublicEDKey is missing from the built Info.plist") }
        let item = try Appcast.items(at: appcast).newest
        switch EdSignature.check(item, archive: try Data(contentsOf: archive), publicKey: publicKey) {
        case .valid: Log.step("edSignature verifies against SUPublicEDKey")
        case .invalid(let reason): throw ToolError("\(appcast.path): \(reason)")
        case .unverifiable: throw ToolError("can't verify edSignature on this platform; release from macOS")
        }
    }

    /// The environment variable CI passes the Sparkle private key in.
    public static let edKeyVariable = "SPARKLE_ED_PRIVATE_KEY_BASE64"

    /// The Sparkle private key: an explicit file, `SPARKLE_ED_PRIVATE_KEY_BASE64` (CI), or a local key file. Nil
    /// means `generate_appcast` reads the login Keychain, where `generate-sparkle-key.sh` stores it.
    ///
    /// - Blocking: reads and may write a temporary key file.
    public func resolveEdKey(explicit: String?) throws -> URL? {
        if let path = explicit {
            guard FileManager.default.fileExists(atPath: path) else { throw ToolError("no Sparkle key at \(path)") }
            return URL(fileURLWithPath: path)
        }
        let environment = ProcessInfo.processInfo.environment
        if let encoded = environment[Self.edKeyVariable] {
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
        let found = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        if found == nil { Log.step("no Sparkle key file; generate_appcast signs with the key in the login Keychain") }
        return found
    }

    /// `sign_update --ed-key-file` reads the base64 text that `generate_keys -x` exports. The CI secret holds either
    /// that text or that text base64-encoded again; an Ed25519 key is 32 or 64 bytes, which tells them apart.
    static func edKeyFile(fromSecret secret: String) throws -> Data {
        let compact = secret.filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: compact) else {
            throw ToolError("\(edKeyVariable) isn't valid base64")
        }
        return [32, 64].contains(decoded.count) ? Data(compact.utf8) : decoded
    }
}
