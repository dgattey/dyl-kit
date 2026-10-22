import DylToolSupport
import Foundation

/// One side of `check --live`: an app, its feed's newest item and the archive that item names.
struct ReleaseSnapshot {
    var info: Plist
    var designatedRequirement: String?
    var entitlements: Plist?
    /// `Signature=` from `codesign -dvv`: `adhoc`, or the signing authority's kind.
    var signature: String?
    var feed: [AppcastItem]
    var archive: Data

    var newest: AppcastItem? { feed.newest }

    func string(_ key: String) -> String? { info[key]?.string }
}

/// Compares the staged release with the one installs run now, so a PR proves it ships a valid Sparkle update.
struct LiveComparison {
    var live: ReleaseSnapshot
    var staged: ReleaseSnapshot
    var manifestFeedURL: String
    /// `codesign --verify --deep --strict` on the staged app, nil when it passed.
    var stagedCodesignFailure: String?
    /// Info.plist keys from `[local-values]`, printed only as their length.
    var redactedKeys: Set<String>

    static let rules = [
        "live_bundle_id", "live_executable", "live_public_key", "live_feed_url", "live_min_os", "live_build_increases",
        "staged_appcast_matches_app", "live_codesign", "live_designated_requirement", "live_entitlements",
        "live_signing_scheme", "live_ed_signature", "live_feed_valid",
    ]

    func findings() -> [CheckFinding] {
        var findings: [CheckFinding] = []
        func fail(_ rule: String, _ message: String, severity: CheckFinding.Severity = .error) {
            findings.append(CheckFinding(rule: rule, severity: severity, file: nil, message: message))
        }
        func show(_ value: String?) -> String { value.map { "`\($0)`" } ?? "missing" }
        func same(_ rule: String, _ key: String) {
            let (old, new) = (live.string(key), staged.string(key))
            if old != new { fail(rule, "\(key): live \(show(old)), staged \(show(new))") }
        }

        same("live_bundle_id", "CFBundleIdentifier")
        same("live_executable", "CFBundleExecutable")
        same("live_public_key", "SUPublicEDKey")
        let stagedFeed = staged.string("SUFeedURL")
        if stagedFeed != manifestFeedURL {
            fail(
                "live_feed_url",
                "staged SUFeedURL is \(show(stagedFeed)), DylApp.toml's feed is `\(manifestFeedURL)` "
                    + "(live app: \(show(live.string("SUFeedURL"))))")
        }
        let (oldOS, newOS) = (live.string("LSMinimumSystemVersion"), staged.string("LSMinimumSystemVersion"))
        if let oldOS, let newOS, let old = AppVersion(oldOS), let new = AppVersion(newOS), old != new {
            if new < old {
                fail("live_min_os", "staged LSMinimumSystemVersion \(newOS) is lower than live \(oldOS)")
            } else {
                fail(
                    "live_min_os", "raises LSMinimumSystemVersion from \(oldOS) to \(newOS); Macs on \(oldOS) stop updating",
                    severity: .warning)
            }
        }
        let liveNewest = live.newest
        let stagedBuild = staged.string("CFBundleVersion").flatMap { Int($0) }
        if !(stagedBuild.flatMap { new in liveNewest.map { new > $0.build } } ?? false) {
            fail(
                "live_build_increases",
                "staged CFBundleVersion \(show(staged.string("CFBundleVersion"))) must be above the live feed's "
                    + "sparkle:version \(show(liveNewest.map { String($0.build) }))")
        }
        let stagedItem = staged.newest
        let stagedItemBuild = stagedItem.map { String($0.build) }
        if stagedItemBuild != staged.string("CFBundleVersion")
            || stagedItem?.shortVersion != staged.string("CFBundleShortVersionString")
        {
            fail(
                "staged_appcast_matches_app",
                "staged appcast is \(show(stagedItem?.shortVersion)) (\(show(stagedItemBuild))), the app is "
                    + "\(show(staged.string("CFBundleShortVersionString"))) (\(show(staged.string("CFBundleVersion"))))")
        }
        if let stagedCodesignFailure { fail("live_codesign", stagedCodesignFailure) }
        if live.designatedRequirement != staged.designatedRequirement {
            fail(
                "live_designated_requirement",
                "live \(show(live.designatedRequirement)), staged \(show(staged.designatedRequirement))")
        }
        if live.entitlements != staged.entitlements {
            let keys = Set((live.entitlements ?? [:]).keys).symmetricDifference((staged.entitlements ?? [:]).keys)
            fail("live_entitlements", "entitlements differ\(keys.isEmpty ? "" : ": \(keys.sorted().joined(separator: ", "))")")
        }
        if live.signature != staged.signature {
            fail("live_signing_scheme", "live Signature=\(show(live.signature)), staged \(show(staged.signature))")
        }
        if let key = live.string("SUPublicEDKey") {
            func problem(_ item: AppcastItem?, _ archive: Data) -> String? {
                switch EdSignature.check(item, archive: archive, publicKey: key) {
                case .valid: nil
                case .invalid(let reason): reason
                case .unverifiable: "can't verify Ed25519 on this platform; run on macOS"
                }
            }
            if let problem = problem(stagedItem, staged.archive) {
                fail("live_ed_signature", "staged archive against the live app's SUPublicEDKey: \(problem)")
            }
            if let problem = problem(liveNewest, live.archive) {
                fail("live_feed_valid", "the live feed's newest item: \(problem)")
            }
        } else {
            fail("live_ed_signature", "the live app has no SUPublicEDKey")
        }
        return findings
    }

    /// Live → staged Info.plist changes, without build-machine keys, and local values as their length only.
    func infoDiff() -> [String] {
        func render(_ key: String, _ value: PlistValue?) -> String {
            guard let value else { return "(none)" }
            if redactedKeys.contains(key) { return "<\(value.string?.count ?? 0) chars>" }
            return Self.render(value)
        }
        let keys = Set(live.info.keys).union(staged.info.keys)
            .filter { !$0.hasPrefix("DT") && !$0.hasPrefix("BuildMachine") }
        return keys.sorted().compactMap { key in
            let (old, new) = (live.info[key], staged.info[key])
            guard old != new else { return nil }
            return "\(key): \(render(key, old)) → \(render(key, new))"
        }
    }

    private static func render(_ value: PlistValue) -> String {
        switch value {
        case .string(let text): text
        case .integer(let number): String(number)
        case .boolean(let flag): String(flag)
        case .array(let items): "[" + items.map(render).joined(separator: ", ") + "]"
        case .dictionary(let entries):
            "{" + entries.keys.sorted().map { "\($0): \(render(entries[$0]!))" }.joined(separator: ", ") + "}"
        }
    }
}

/// Collects both snapshots on macOS: the staged release from `build/release/`, and the live one from the newest item
/// across the site's feed and the Blob store's latest feed, by downloading its enclosure and unzipping it with `ditto`.
public struct LiveChecks: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// - Blocking: downloads and unzips the live release and runs `codesign`.
    public func run() async throws -> (CheckReport, [String]) {
        let pipeline = ReleasePipeline(workspace: workspace)
        let missing = ToolError("no staged release; run `release-kit version`, `bundle`, `sign` and `appcast` first")
        guard let state = try? pipeline.state() else { throw missing }
        let stagedApp = pipeline.stagedApp
        let stagedArchive = pipeline.archiveURL(state)
        let stagedAppcast = pipeline.stagedAppcast
        for url in [stagedApp, stagedArchive, stagedAppcast] where !FileManager.default.fileExists(atPath: url.path) {
            throw missing
        }

        let feedURL = workspace.manifest.release.feedURL
        let published = try await pipeline.publishedFeeds()
        guard let enclosure = published.newest?.enclosureURL else {
            throw ToolError(
                "neither \(feedURL) nor \(pipeline.latestAppcastURL) has an item with an enclosure to compare with")
        }
        let liveArchive = try await Appcast.download(enclosure)

        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let zip = scratch.appending(path: "live.zip")
        try liveArchive.write(to: zip)
        try Shell.run(["ditto", "-x", "-k", zip.path, scratch.appending(path: "app").path])
        let apps = try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "app").path)
            .filter { $0.hasSuffix(".app") }
        guard let liveAppName = apps.first else { throw ToolError("\(enclosure) has no .app inside") }
        let liveApp = scratch.appending(path: "app/\(liveAppName)")

        let verify = ["codesign", "--verify", "--deep", "--strict", stagedApp.path]
        let codesignFailure = try Shell.run(verify, quiet: true, allowFailure: true) == 0
            ? nil : try Shell.capture(verify, includeStderr: true, allowFailure: true)
        let comparison = LiveComparison(
            live: try snapshot(app: liveApp, feed: published, archive: liveArchive),
            staged: try snapshot(
                app: stagedApp, feed: try Appcast.items(at: stagedAppcast),
                archive: try Data(contentsOf: stagedArchive)),
            manifestFeedURL: feedURL,
            stagedCodesignFailure: codesignFailure.map { $0.isEmpty ? "codesign --verify failed" : $0 },
            redactedKeys: Set(workspace.manifest.localValues?.keys.keys.map { $0 } ?? []))

        var report = ReleaseChecks(workspace: workspace).run(staged: pipeline.stagedRelease(state, published: published))
        report.checked += LiveComparison.rules
        report.findings += comparison.findings()
        return (report, comparison.infoDiff())
    }

    private func snapshot(app: URL, feed: [AppcastItem], archive: Data) throws -> ReleaseSnapshot {
        let requirement = try Shell.capture(["codesign", "-d", "-r-", app.path], allowFailure: true)
        let entitlements = try Shell.capture(
            ["codesign", "-d", "--entitlements", "-", "--xml", app.path], allowFailure: true)
        let details = try Shell.capture(["codesign", "-dvv", app.path], includeStderr: true, allowFailure: true)
        return ReleaseSnapshot(
            info: InfoPlist.read(app.appending(path: "Contents/Info.plist")) ?? [:],
            designatedRequirement: requirement.split(separator: "\n")
                .first { $0.hasPrefix("designated =>") }.map(String.init),
            entitlements: entitlements.isEmpty
                ? nil : try? PropertyListDecoder().decode(Plist.self, from: Data(entitlements.utf8)),
            signature: details.split(separator: "\n").first { $0.hasPrefix("Signature=") }
                .map { String($0.dropFirst("Signature=".count)) },
            feed: feed, archive: archive)
    }
}
