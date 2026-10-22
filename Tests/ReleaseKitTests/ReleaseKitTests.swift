import DylManifest
import DylToolSupport
import Foundation
import Testing

#if canImport(CryptoKit)
import CryptoKit
#endif

@testable import ReleaseKit

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
/// The smallest DylKit app, standing in for one that uses DylKit.
let appRoot = packageRoot.appending(path: "Tests/Fixtures/SampleApp")

private func fixture(_ path: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: path), encoding: .utf8)
}

/// `items` in an RSS channel that declares Sparkle's namespace.
func sparkleFeed(_ items: String) -> String {
    #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>\#(items)</channel></rss>"#
}

private let sconeosModules = [
    "SconeDomain", "SconeStore", "SconeUI", "SconeosApp", "SonosProtocolBoundary", "SpotifyBridge",
]

@Suite struct NotesFormatterTests {
    static let cases: [(body: String, html: String)] = [
        (
            #"""
            ## Highlights
            - First highlight
            ---
            - After the rule is dropped
            """#,
            #"""
            <ul>
              <li style="margin-bottom: 6px; line-height: 1.45;">First highlight</li>
            </ul>
            """#
        ),
        (
            #"""
            # Release notes

            <ul><li>Already HTML</li></ul>
            """#,
            #"""
            <ul><li>Already HTML</li></ul>
            """#
        ),
        (
            #"""
            Just a plain body without headings.
            - one
            - two (Tests/SconeKitTests/SconeDomainTests.swift)
            """#,
            #"""
            <p style="margin: 0 0 8px 0; line-height: 1.45;">Just a plain body without headings.</p>
            <ul>
              <li style="margin-bottom: 6px; line-height: 1.45;">one</li>
              <li style="margin-bottom: 6px; line-height: 1.45;">two</li>
            </ul>
            """#
        ),
        (
            #"""
            # Summary

            Intro paragraph with a [link](https://example.com/a?b=1&c=2) and **bold** text.

            - Fixed the map (`Sources/SconeUI/FloorplanMapView.swift`, `FloorplanMapView.swift`) so it stops jumping.
            - Keeps real parentheses (like this one) intact , with spacing .
            - Mixed (`scripts/build-macos.sh` and `package.json`) noise & <tags> escaped
              continuation line joins the bullet
              - nested bullet becomes its own bullet
            * star bullet with `code`
            ![screenshot](https://example.com/s.png)
            <img src="x.png">

            # Release info

            - [x] Patch
            """#,
            #"""
            <p style="margin: 0 0 8px 0; line-height: 1.45;">Intro paragraph with a <a href="https://example.com/a?b=1&amp;c=2">link</a> and <strong>bold</strong> text.</p>
            <ul>
              <li style="margin-bottom: 6px; line-height: 1.45;">Fixed the map so it stops jumping.</li>
              <li style="margin-bottom: 6px; line-height: 1.45;">Keeps real parentheses (like this one) intact, with spacing.</li>
              <li style="margin-bottom: 6px; line-height: 1.45;">Mixed noise &amp; &lt;tags&gt; escaped continuation line joins the bullet</li>
              <li style="margin-bottom: 6px; line-height: 1.45;">nested bullet becomes its own bullet</li>
              <li style="margin-bottom: 6px; line-height: 1.45;">star bullet with <code>code</code></li>
            </ul>
            """#
        ),
    ]

    @Test(arguments: cases) func formatsTheNotesSection(_ body: String, _ html: String) {
        let formatter = NotesFormatter(pathRoots: NotesFormatter.defaultPathRoots + sconeosModules)
        let extracted = ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "")
        #expect(formatter.html(extracted.isEmpty ? body : extracted, version: "2.3.4") == html)
    }
}

@Suite struct ReleaseInfoTests {
    @Test func readsExactlyOneCheckedBump() {
        #expect(ReleaseInfo.releaseType(in: "# Release info\n\n- [ ] Major\n- [x] Minor\n- [ ] Patch") == .minor)
        #expect(ReleaseInfo.releaseType(in: "- [X] major") == .major)
        #expect(ReleaseInfo.releaseType(in: "- [ ] Major\n- [ ] Minor") == nil)
        #expect(ReleaseInfo.releaseType(in: "- [x] Major\n- [x] Minor") == nil)
    }

    @Test func prBodyWinsAndTheCommitIsTheFallback() throws {
        let minor = "- [ ] Major\n- [x] Minor\n- [ ] Patch"
        let patch = "- [ ] Major\n- [ ] Minor\n- [x] Patch"
        #expect(try ReleaseInfo.source(prBody: minor, commitBody: patch).bump == .minor)
        #expect(try ReleaseInfo.source(prBody: nil, commitBody: patch).bump == .patch)
        #expect(try ReleaseInfo.source(prBody: "- [ ] Major", commitBody: patch).bump == .patch)
        #expect(throws: ToolError.self) { try ReleaseInfo.source(prBody: "- [ ] Major", commitBody: "Merge #4") }
    }

    /// scone-os #7 checked Minor but shipped as 1.0.6: the squash commit carried only the commit list, and the old
    /// scripts defaulted to patch. Its body, verbatim, has prose and a rule before the heading and labels after each box.
    @Test func scone7ReleasesAsMinorFromItsBodyAndNeverDefaultsToPatch() throws {
        let body = try fixture("release-info/pr-7-body.md")
        let squashMessage = try fixture("release-info/pr-7-merge-commit.txt")
        #expect(ReleaseInfo.releaseType(in: body) == .minor)
        #expect(ReleaseInfo.releaseType(in: body.replacingOccurrences(of: "\n", with: "\r\n")) == .minor)
        #expect(try ReleaseInfo.source(prBody: body, commitBody: squashMessage).bump == .minor)
        #expect(throws: ToolError.self) { try ReleaseInfo.source(prBody: nil, commitBody: squashMessage) }
        #expect(ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "").hasPrefix("- **One-click Spotify transfer:**"))
    }

    /// Scone #13's shape: an agent-written body between markers, with a footer after them.
    @Test func notesComeFromTheFirstNonEmptySectionElseTheTitle() {
        let body = """
            <!-- CURSOR_AGENT_PR_BODY_BEGIN -->
            # Release notes

            - Sconeos no longer stalls at launch.

            # What changed?

            - `SonosHousehold.waitForTopology` stops spinning once cancelled.

            # Release info

            - [x] Patch
            <!-- CURSOR_AGENT_PR_BODY_END -->

            <div><a href="https://cursor.com/agents/bc-1">Open in Cursor</a></div>
            """
        #expect(ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "Title") == "- Sconeos no longer stalls at launch.")
        let empty = "# Release notes\n\n- \n\n# What changed?\n\n- "
        #expect(ReleaseInfo.notesMarkdown(body: empty, fallbackTitle: "Fix the map") == "- Fix the map")
    }

    /// Saga #45: the secret may hold the exported key text or that text base64-encoded again.
    @Test func sparkleKeySecretAcceptsSingleOrDoubleBase64() throws {
        let exported = Data(repeating: 7, count: 32).base64EncodedString()
        let doubled = Data(exported.utf8).base64EncodedString()
        #expect(try ReleasePipeline.edKeyFile(fromSecret: exported) == Data(exported.utf8))
        let wrapped = "\(doubled.prefix(20))\n\(doubled.dropFirst(20))"
        #expect(try ReleasePipeline.edKeyFile(fromSecret: wrapped) == Data(exported.utf8))
        #expect(throws: ToolError.self) { try ReleasePipeline.edKeyFile(fromSecret: "not base64!") }
    }

    /// Saga #52: `## Summary` with `### Changes` under it was cut at the subheading, and reviewer sections leaked in.
    @Test func notesKeepDeeperSubheadingsButSkipReviewerSections() {
        let body = """
            ## Summary
            Covers in the editor.
            ### Changes
            - Paste a cover image.
            ### Test plan
            - [x] Pasted three covers.
            #### Notes for the test plan
            - Uses the sample library.
            ### Details
            - Drop a cover file.
            ## Release info
            - [x] Minor
            """
        let notes = ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "")
        #expect(
            notes
                == "Covers in the editor.\n### Changes\n- Paste a cover image.\n### Details\n- Drop a cover file.")
        #expect(ReleaseInfo.section("Description", in: "# Description\n- Faster sync.") == "- Faster sync.")
        let html = NotesFormatter().html(notes, version: "1.0.0")
        #expect(html.contains("Paste a cover image.") && html.contains("Drop a cover file."))
        #expect(!html.contains("Pasted three covers") && !html.contains("Changes"))
    }

    @Test func commitMessageDropsThePRNumber() {
        let message = CommitMessage("Fix the map drag (#4)\n\n# Release notes\n\n- Map drags smoothly.\n")
        #expect(message.subject == "Fix the map drag")
        #expect(message.body.hasPrefix("# Release notes"))
    }
}

@Suite struct CumulativeNotesTests {
    private func feed(_ items: [(version: String, build: Int, description: String)]) throws -> [AppcastItem] {
        let body = items.map { item in
            "<item><title>\(item.version)</title><sparkle:version>\(item.build)</sparkle:version>"
                + "<description><![CDATA[\(item.description)]]></description></item>"
        }
        return try Appcast.items(in: Data(sparkleFeed(body.joined()).utf8), source: "feed")
    }

    /// The committed feed wins over a stale live one, placeholder notes drop out, and `Version`/`v` prefixes on
    /// legacy headings are normalized.
    @Test func mergesFeedsNewestFirstDedupedAndCapped() throws {
        let committed = try feed([
            ("1.0.12", 29, "<h3>1.0.12</h3><ul><li>Twelve</li></ul><h3>1.0.11</h3><ul><li>Eleven</li></ul>"),
        ])
        let live = try feed([
            ("1.0.11", 28, "<h3>1.0.11</h3><ul><li>Stale eleven</li></ul>"),
            ("1.0.7", 20, "<p>Release v1.0.7</p>"),
            ("1.0.6", 19, "<h3>Version 1.0.6</h3><ul><li>Older &amp; wiser.</li></ul><h3>v1.0.5</h3><ul><li>Five</li></ul>"),
        ])
        func versions(_ html: String) -> [String] { html.matches(of: /<h3[^>]*>([^<]+)<\/h3>/).map { String($0.1) } }

        let new = "<ul><li>New</li></ul>"
        let all = CumulativeNotes.html(version: "1.0.13", build: "30", newNotes: new, history: [committed, live])
        #expect(versions(all) == ["1.0.13", "1.0.12", "1.0.11", "1.0.6", "1.0.5"])
        #expect(all.contains("Eleven") && !all.contains("Stale") && !all.contains("Release v1.0.7"))
        #expect(all.contains("Older &amp; wiser."))
        let capped = CumulativeNotes.html(
            version: "1.0.13", build: "30", newNotes: new, history: [committed, live], maxVersions: 3)
        #expect(versions(capped) == ["1.0.13", "1.0.12", "1.0.11"])
    }

    @Test func stampsSectionsWithBuildsAndReadsThemBack() throws {
        func feed(_ version: String, build: String, description: String) throws -> [AppcastItem] {
            let xml = sparkleFeed(
                """
                <item>
                <title>\(version)</title><sparkle:version>\(build)</sparkle:version>
                <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
                <description><![CDATA[\(description)]]></description>
                </item>
                """)
            return try Appcast.items(in: Data(xml.utf8), source: "feed")
        }
        let li = #"<li style="\#(NotesFormatter.bulletStyle)">"#
        let legacy = "<h3>1.0.9</h3><ul><li>Nine</li></ul><h3>1.0.8</h3><ul><li>Eight</li></ul>"
            + "<h3>1.0.7</h3><p>Release v1.0.7</p><h3>1.0.6</h3><ul><li>Six</li></ul>"
        let first = CumulativeNotes.html(
            version: "1.0.10", build: "27", newNotes: "<ul><li>Ten</li></ul>",
            history: [try feed("1.0.9", build: "24", description: legacy)], knownBuilds: ["1.0.8": "22", "1.0.7": "20"])
        let top = CumulativeNotes.topHeadingStyle
        let previous = CumulativeNotes.previousHeadingStyle
        #expect(
            first == """
                <style>.sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }</style>
                <section data-sparkle-version="27">
                <h3 style="\(top)">1.0.10</h3>
                <ul><li>Ten</li></ul>
                </section>
                <section data-sparkle-version="24">
                <h3 style="\(previous)">1.0.9</h3>
                <ul>\(li)Nine</li></ul>
                </section>
                <section data-sparkle-version="22">
                <h3 style="\(previous)">1.0.8</h3>
                <ul>\(li)Eight</li></ul>
                </section>
                <section data-sparkle-version="20" data-version="1.0.7"></section>
                <section>
                <h3 style="\(previous)">1.0.6</h3>
                <ul>\(li)Six</li></ul>
                </section>
                """)

        let second = CumulativeNotes.html(
            version: "1.0.11", build: "30", newNotes: "<ul><li>Eleven</li></ul>",
            history: [try feed("1.0.10", build: "27", description: first)], maxVersions: 5)
        #expect(second.components(separatedBy: "<style>").count == 2)
        let stamps = second.matches(of: /<section( data-sparkle-version="(\d+)")?/).map { $0.2.map(String.init) ?? "-" }
        #expect(stamps == ["30", "27", "24", "22", "20"])
        #expect(second.contains("<h3 style=\"\(previous)\">1.0.10</h3>\n<ul>\(li)Ten</li></ul>"))
        #expect(second.hasSuffix(#"<section data-sparkle-version="20" data-version="1.0.7"></section>"#))
    }

    @Test func parsesTheLiveAppcast() throws {
        let item = try #require(Appcast.items(at: fixtures.appending(path: "sconeos-appcast.xml")).first)
        #expect(item.displayVersion == "1.0.9")
        #expect(item.build == 24)
        #expect(item.minimumSystemVersion == "14.0")
        #expect(item.enclosureURL == "https://sconeos.gattey.com/Sconeos-1.0.9.zip")
        #expect(item.edSignature?.isEmpty == false)
        #expect(item.enclosureLength ?? 0 > 0)
        #expect(item.publishedAt == (try Date("2026-10-16T22:42:54Z", strategy: .iso8601)))
        #expect(item.hardwareRequirements.isEmpty)
    }
}

@Suite struct VersioningTests {
    private func feed() throws -> [AppcastItem] { try Appcast.items(at: fixtures.appending(path: "sconeos-appcast.xml")) }

    @Test func currentVersionIsTheHighestKnown() throws {
        #expect(ReleasePipeline.currentVersion(published: try feed(), tags: ["v1.0.5"]).description == "1.0.9")
        #expect(ReleasePipeline.currentVersion(published: [], tags: ["v2.0.0", "junk"]).description == "2.0.0")
        #expect(ReleasePipeline.currentVersion(published: [], tags: []).description == "1.0.0")
    }

    @Test func buildNumberStaysAboveThePublishedOne() throws {
        #expect(ReleasePipeline.nextBuild(commitCount: 10, published: try feed()) == 25)
        #expect(ReleasePipeline.nextBuild(commitCount: 300, published: try feed()) == 300)
    }

    /// GitHub re-runs whole jobs, so a run that already tagged HEAD replans that release instead of bumping past it.
    @Test func aReleaseTagAtHeadResumesThatRelease() throws {
        let published = try feed()
        let v109 = try #require(AppVersion("1.0.9"))
        let v110 = try #require(AppVersion("1.1.0"))
        func plan(_ headTags: [String]) -> ReleasePipeline.Plan {
            ReleasePipeline.plan(
                headTags: headTags, tags: ["v1.0.5", "v1.0.9"] + headTags, published: published, commitCount: 10,
                bump: .minor)
        }
        #expect(plan(["v1.0.9"]) == .resumed(v109, build: 24))
        #expect(plan(["nightly", "v1.1.0"]) == .resumed(v110, build: 25))
        #expect(plan(["nightly"]) == .next(v110, build: 25, bumpedFrom: v109))
    }

    /// A release that shipped after this one was planned would be undercut; an equal build is a publish re-run.
    @Test func publishRefusesABuildBelowThePublishedOne() throws {
        let published = [AppcastItem(build: 30), AppcastItem(build: 31)]
        #expect(throws: ToolError.self) {
            try ReleasePipeline.refuseRegression(staged: [AppcastItem(build: 30)], published: published)
        }
        try ReleasePipeline.refuseRegression(staged: [AppcastItem(build: 31)], published: published)
        try ReleasePipeline.refuseRegression(staged: [AppcastItem(build: 32)], published: published)
        try ReleasePipeline.refuseRegression(staged: [AppcastItem(build: 1)], published: [])
        #expect(throws: ToolError.self) { try ReleasePipeline.refuseRegression(staged: [], published: published) }
    }

    @Test func parsesOrdersAndBumpsVersions() throws {
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("1.0.9-beta") == AppVersion(major: 1, minor: 0, patch: 9))
        #expect(AppVersion("1.x") == nil)
        #expect(try #require(AppVersion("1.0.10")) > #require(AppVersion("1.0.9")))
        let version = try #require(AppVersion("1.4.9"))
        #expect(version.bumped(.patch).description == "1.4.10")
        #expect(version.bumped(.minor).description == "1.5.0")
        #expect(version.bumped(.major).description == "2.0.0")
    }
}

@Suite struct InfoPlistTests {
    @Test func derivesTheAppKeysFromTheManifest() throws {
        let manifest = try DylAppManifest.load(root: appRoot)
        let key = try String(contentsOf: appRoot.appending(path: "sparkle-public-key.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = InfoPlist.contents(
            manifest: manifest, identity: .release, shortVersion: "1.2.3", build: "45", sparklePublicKey: key)
        #expect(generated["CFBundleIdentifier"] == .string(manifest.app.bundleId))
        #expect(generated["CFBundleShortVersionString"] == .string("1.2.3"))
        #expect(generated["CFBundleVersion"] == .string("45"))
        #expect(generated["LSMinimumSystemVersion"] == .string(manifest.app.platforms.macos))
        #expect(generated["SUFeedURL"] == .string(manifest.release.feedURL))
        #expect(generated["SUPublicEDKey"] == .string(key))
        #expect(generated["NSBonjourServices"] == .array([.string("_sample._tcp")]))
        #expect(generated["NSLocalNetworkUsageDescription"]?.string?.isEmpty == false)
        guard case .array(let urlTypes) = generated["CFBundleURLTypes"], case .dictionary(let urlType) = urlTypes.first
        else { Issue.record("no CFBundleURLTypes"); return }
        #expect(urlType["CFBundleURLSchemes"] == .array([.string("sample")]))
        let roundTrip = try PropertyListDecoder().decode(Plist.self, from: try InfoPlist.data(generated))
        #expect(roundTrip == generated)
    }
}

@Suite struct DevIdentityTests {
    @Test func devBuildsNeverClaimTheInstalledApp() throws {
        let manifest = try DylAppManifest.load(root: appRoot)
        let generated = InfoPlist.contents(
            manifest: manifest, identity: .dev, shortVersion: "1.2.3", build: "45", sparklePublicKey: "key")
        #expect(generated["CFBundleIdentifier"] == .string("com.dylkit.Sample.dev"))
        #expect(generated["CFBundleName"] == .string("Sample Dev"))
        #expect(generated["CFBundleDisplayName"] == .string("Sample Dev"))
        for key in ["SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUScheduledCheckInterval"] {
            #expect(generated[key] == nil, "\(key)")
        }
        guard case .array(let urlTypes) = generated["CFBundleURLTypes"], case .dictionary(let urlType) = urlTypes.first
        else { Issue.record("no CFBundleURLTypes"); return }
        #expect(urlType["CFBundleURLSchemes"] == .array([.string("sample-dev")]))
        #expect(urlType["CFBundleURLName"] == .string("com.dylkit.sample.callback-dev"))
    }
}

@Suite struct EdSignatureTests {
    @Test func rejectsATamperedArchive() throws {
        #if canImport(CryptoKit)
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("the archive".utf8)
        let signature = try key.signature(for: archive).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        #expect(EdSignature.verify(archive: archive, signature: signature, publicKey: publicKey) == .valid)
        var tampered = archive
        tampered[0] ^= 0xff
        switch EdSignature.verify(archive: tampered, signature: signature, publicKey: publicKey) {
        case .invalid: break
        case .valid, .unverifiable:
            Issue.record("a tampered archive must not verify")
        }
        #else
        let signature = Data(count: 64).base64EncodedString()
        let key = Data(count: 32).base64EncodedString()
        #expect(EdSignature.verify(archive: Data(), signature: signature, publicKey: key) == .unverifiable)
        #endif
        #expect(EdSignature.verify(archive: Data(), signature: "short", publicKey: "short") != .valid)
    }
}

/// Runs the tier 3 checks over a scratch copy of the SampleApp, synced as `devkit sync` leaves it, plus `extra` files.
@Suite struct ReleaseChecksTests {
    private func scratchWorkspace(_ extra: [String: String] = [:]) throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appending(path: "dylkit-checks-\(UUID().uuidString)")
        let appFiles = [
            "DylApp.toml", "Package.swift", "sparkle-public-key.txt", "Sample.entitlements", "server/package.json",
            "server/vercel.json", ".github/workflows/verify.yml",
        ]
        for path in appFiles {
            let destination = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: appRoot.appending(path: path), to: destination)
        }
        _ = try SharedFiles.sync(root: root)
        for (path, text) in extra {
            let destination = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: destination)
        }
        return try Workspace.locate(root.path)
    }

    private func errors(_ report: CheckReport) -> [String: [String]] {
        Dictionary(grouping: report.findings.filter { $0.severity == .error }, by: \.rule)
            .mapValues { $0.map(\.message) }
    }

    private func errorFiles(_ report: CheckReport) -> [String: [String]] {
        Dictionary(grouping: report.findings.filter { $0.severity == .error }, by: \.rule)
            .mapValues { $0.compactMap(\.file) }
    }

    @Test func committedWorkflowsPass() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(errors(ReleaseChecks(workspace: workspace).run()).isEmpty)
    }

    private static let downloadPrefix = "https://github.com/o/r/releases/download/v1.0.9/"

    /// Stages `item` as the appcast `appcast` writes, and checks it against `published`.
    private func checkStaged(_ item: String, published: [AppcastItem]) throws -> [String: [String]] {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let pipeline = ReleasePipeline(workspace: workspace)
        try FileManager.default.createDirectory(at: pipeline.stagingDir, withIntermediateDirectories: true)
        try Data(sparkleFeed(item).utf8).write(to: pipeline.stagedAppcast)
        let staged = ReleaseChecks.StagedRelease(
            appcast: pipeline.stagedAppcast, archive: pipeline.stagingDir.appending(path: "Sample-1.0.9.zip"),
            downloadPrefix: Self.downloadPrefix, published: published)
        return errors(ReleaseChecks(workspace: workspace).run(staged: staged))
    }

    /// A re-run of a release that went out stages its build and version again; any other build at or below the
    /// published one would undercut it.
    @Test func stagedBuildBeatsThePublishedOneUnlessItsARerun() throws {
        let staged = #"<item><title>1.0.9</title><sparkle:version>24</sparkle:version>"#
            + #"<enclosure url="\#(Self.downloadPrefix)Sample-1.0.9.zip"/></item>"#
        func published(_ version: String, _ build: Int) -> [AppcastItem] {
            var item = AppcastItem(build: build)
            item.shortVersion = version
            return [item]
        }
        #expect(try checkStaged(staged, published: published("1.0.8", 23))["build_number_monotonic"] == nil)
        #expect(try checkStaged(staged, published: published("1.0.9", 24))["build_number_monotonic"] == nil)
        #expect(try checkStaged(staged, published: published("1.0.8", 24))["build_number_monotonic"]?.count == 1)
        #expect(try checkStaged(staged, published: published("1.0.9", 25))["build_number_monotonic"]?.count == 1)
    }

    /// Every check that reads the staged appcast fails on an item without an integer build instead of skipping it.
    @Test func aStagedItemWithoutAnIntegerBuildFailsEveryCheckThatReadsIt() throws {
        let staged = #"<item><title>1.0.9</title><sparkle:version>24b</sparkle:version>"#
            + #"<enclosure url="\#(Self.downloadPrefix)Sample-1.0.9.zip"/></item>"#
        let failed = try checkStaged(staged, published: [AppcastItem(build: 1)])
        for rule in ["min_os_consistency", "appcast_signature", "staged_release"] {
            #expect(failed[rule]?.count == 1 && failed[rule]?.first?.contains("24b") == true, "\(rule): \(failed)")
        }
    }

    /// Photos #9: library validation must be off to load Sparkle ad-hoc. DylKit apps have no Xcode project.
    @Test func libraryValidationOffAndNoXcodeProject() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let entitlements = workspace.url("Sample.entitlements")
        let text = try String(contentsOf: entitlements, encoding: .utf8)
        try Data(text.replacing("disable-library-validation", with: "allow-jit").utf8).write(to: entitlements)
        let project = workspace.url("Sample.xcodeproj/project.pbxproj")
        try FileManager.default.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: project)

        let swiftPMWorkspace = workspace.url(".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata")
        try FileManager.default.createDirectory(
            at: swiftPMWorkspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: swiftPMWorkspace)

        let report = ReleaseChecks(workspace: workspace).run()
        #expect(errors(report)["library_validation"]?.count == 1)
        #expect(errorFiles(report)["swiftpm_only"] == ["Sample.xcodeproj"])
    }

    /// A fix to a shared file reaches every app only if none keeps its own copy.
    @Test func sharedFilesMatchDylKit() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let check = workspace.url(".github/workflows/pr-check.yml")
        let stale = try String(contentsOf: check, encoding: .utf8).replacing(", synchronize]", with: "]")
        try Data(stale.utf8).write(to: check)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: workspace.url("run").path)
        try FileManager.default.removeItem(at: workspace.url(".github/workflows/release.yml"))

        let report = ReleaseChecks(workspace: workspace).run()
        #expect(errors(report)["shared_files"] == [
            "isn't executable; run `./run dev sync`",
            "differs from DylKit's copy; run `./run dev sync`",
            "missing; run `./run dev sync`",
        ])

        #expect(
            try SharedFiles.sync(root: workspace.root)
                == ["run", ".github/workflows/pr-check.yml", ".github/workflows/release.yml"])
        #expect(errors(ReleaseChecks(workspace: workspace).run())["shared_files"] == nil)
        #expect(try SharedFiles.sync(root: workspace.root).isEmpty)
    }

    /// DylKit's own release reads the same Release info box, so its PRs start from the apps' template and run their
    /// check.
    @Test func dylKitChecksItsOwnReleaseInfo() throws {
        for file in [SharedFiles.prCheck, SharedFiles.prTemplate] {
            let own = packageRoot.appending(path: file.path)
            #expect(try String(contentsOf: own, encoding: .utf8) == file.contents, "\(file.path)")
        }
    }

    /// Saga #45: Vercel's ignoreCommand must still deploy release commits and the shared web package.
    @Test func siteDeploySkipsOnlyWhatTheSiteDoesntRead() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let config = #"{ "ignoreCommand": "git diff --quiet HEAD^ HEAD -- app" }"#
        try Data(config.utf8).write(to: workspace.url("server/vercel.json"))

        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["site_deploy"] == [
            "server/vercel.json", "server/vercel.json",
        ])
    }

    @Test func legacyWorkflowFails() throws {
        let legacy = """
            name: release-macos
            on:
              push:
                branches: [main]
            jobs:
              release:
                runs-on: macos-26
                steps:
                  - uses: actions/github-script@v7
                  - run: ./scripts/package-release.sh && gh release create "v$VERSION"
                    env:
                      GH_TOKEN: ${{ secrets.GH_TOKEN }}
                      SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY_BASE64 }}
            """
        let workspace = try scratchWorkspace([".github/workflows/release-macos.yml": legacy])
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let workflow = ".github/workflows/release-macos.yml"
        let files = errorFiles(ReleaseChecks(workspace: workspace).run())
        #expect(files["forge_neutral"] == [workflow, workflow])
        #expect(files["unused_ci_secret"] == [workflow, workflow])
    }

    @Test func appScriptsNeverTalkToTheForge() throws {
        let lookup = "curl -fsSL https://api.github.com/repos/o/r/commits/abc/pulls\n"
        let workspace = try scratchWorkspace(["ci/github/lookup.sh": lookup, "scripts/lookup.sh": lookup])
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(
            errorFiles(ReleaseChecks(workspace: workspace).run())["forge_neutral"]
                == ["scripts/lookup.sh", "ci/github/lookup.sh"])
    }

    /// Apps no longer vendor release-kit's sources, so the forge_neutral scan can't see them; check them here.
    @Test func releaseKitNeverTalksToTheForge() throws {
        let sources = packageRoot.appending(path: "Sources")
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        let allowed = [
            "ReleaseKit/GitHubAdapter.swift", "ReleaseKit/OriginAdapter.swift",
            // pr-check.yml's text, which isn't a release workflow.
            "ReleaseKit/SharedFiles.swift",
        ]
        var scanned = 0
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift"), !allowed.contains(relative) else { continue }
            let text = try String(contentsOf: sources.appending(path: relative), encoding: .utf8)
            #expect(ReleaseChecks.forgeCalls(in: text).isEmpty, "Sources/\(relative)")
            scanned += 1
        }
        #expect(scanned > 0)
        #expect(ReleaseChecks.forgeCalls(in: "gh release create v1") == ["calls the gh CLI"])
    }

    /// Photos: a `file:` @dylkit/web points into `.build/checkouts`, which Vercel never has.
    @Test func fileDependencyOnTheWebPackageSaysToUseTheTarball() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = workspace.url("server/package.json")
        let text = try String(contentsOf: package, encoding: .utf8)
            .replacing(/"@dylkit\/web": "[^"]+"/, with: #""@dylkit/web": "file:../.build/checkouts/dyl-kit/web""#)
        try Data(text.utf8).write(to: package)

        let messages = errors(ReleaseChecks(workspace: workspace).run())["site_deploy"] ?? []
        #expect(messages.count == 1)
        #expect(messages.first?.contains("releases/download/v<version>/dylkit-web-<version>.tgz") == true)
    }

    /// Saga: SwiftPM copies an un-excluded `.xcdatamodeld` raw into the resource bundle.
    @Test func bundledResourcesMustBeExcludedFromTheTarget() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let manifest = workspace.url("DylApp.toml")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(
            of: "entitlements = \"Sample.entitlements\"\n",
            with: "entitlements = \"Sample.entitlements\"\nresources = [\"Sources/SampleApp/Model.xcdatamodeld\", \"Resources/Assets.xcassets\"]\n")
        try Data(text.utf8).write(to: manifest)
        #expect(errors(ReleaseChecks(workspace: try Workspace.locate(workspace.root.path)).run())["resource_not_excluded"]?.count == 1)

        let packageFile = workspace.url("Package.swift")
        let package = try String(contentsOf: packageFile, encoding: .utf8)
            .replacingOccurrences(of: "name: \"SampleApp\",\n", with: "name: \"SampleApp\",\n            exclude: [\"Model.xcdatamodeld\"],\n")
        try Data(package.utf8).write(to: packageFile)
        #expect(errors(ReleaseChecks(workspace: try Workspace.locate(workspace.root.path)).run())["resource_not_excluded"] == nil)
    }

    @Test func localValuesFileMustBeIgnoredAndUntracked() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let manifest = workspace.url("DylApp.toml")
        let text = try String(contentsOf: manifest, encoding: .utf8)
            + "\n[local-values]\nfile = \"Config.xcconfig\"\nkeys = { Token = \"TOKEN\" }\n"
        try Data(text.utf8).write(to: manifest)
        _ = try Shell.capture(["git", "init", "--quiet"], cwd: workspace.root)
        func ruleErrors() throws -> [String]? {
            errors(ReleaseChecks(workspace: try Workspace.locate(workspace.root.path)).run())["local_values_ignored"]
        }
        #expect(try ruleErrors() == ["isn't in .gitignore"])
        try Data("Config.xcconfig\n".utf8).write(to: workspace.url(".gitignore"))
        #expect(try ruleErrors() == nil)
        try Data("TOKEN = secret\n".utf8).write(to: workspace.url("Config.xcconfig"))
        _ = try Shell.capture(["git", "add", "-f", "Config.xcconfig"], cwd: workspace.root)
        #expect(try ruleErrors()?.first?.contains("is committed") == true)
    }
}

/// `release.yml` appends `release-kit version`'s stdout to `$GITHUB_OUTPUT`, which accepts only `key=value` lines.
/// The scone-os #14 release failed when a `git ls-remote` ref leaked into it.
@Suite struct VersionOutputTests {
    private final class Marker {}

    /// Where SwiftPM put `release-kit`, which this test target depends on so it's built.
    private var releaseKit: URL {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "release-kit")
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        _ = try Shell.capture(["git"] + arguments, cwd: directory)
    }

    @Test func stdoutIsOnlyTheOutputs() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let origin = scratch.appending(path: "origin.git")
        let app = scratch.appending(path: "app")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: appRoot, to: app)
        try git(["init", "--quiet", "--bare", origin.path], in: scratch)
        try git(["init", "--quiet", "-b", "main"], in: app)
        try git(["add", "."], in: app)
        let message = "Add a thing (#2)\n\n# Release notes\n\n- A thing.\n\n# Release info\n\n- [ ] Major\n- [x] Minor\n"
        try git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", message],
            in: app)
        try git(["remote", "add", "origin", origin.path], in: app)
        try git(["push", "--quiet", "origin", "main"], in: app)

        let process = Process()
        process.executableURL = releaseKit
        process.arguments = ["version", "--root", app.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(output == "version=1.1.0\nbuild=1\nsite=https://dgattey.github.io/dyl-kit-sample\n")
    }

    /// DylKit has no app or feed: the latest tag and the merged PR's box plan its version, and a rerun resumes it.
    @Test func aLibraryPlansFromTagsAlone() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let origin = scratch.appending(path: "origin.git")
        let library = scratch.appending(path: "library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--bare", origin.path], in: scratch)
        try git(["init", "--quiet", "-b", "main"], in: library)
        let commit = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "--allow-empty"]
        try git(commit + ["-m", "First"], in: library)
        try git(["tag", "v0.1.0"], in: library)
        try git(commit + ["-m", "Release flow (#2)\n\n# Release info\n\n- [ ] Major\n- [x] Minor\n- [ ] Patch\n"], in: library)
        try git(["remote", "add", "origin", origin.path], in: library)
        try git(["push", "--quiet", "--tags", "origin", "main"], in: library)

        func version() throws -> String {
            let process = Process()
            process.executableURL = releaseKit
            process.arguments = ["library", "version", "--github", "o/library", "--root", library.path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return output
        }

        #expect(try version() == "version=0.2.0\n")
        try git(["tag", "v0.2.0"], in: library)
        #expect(try version() == "version=0.2.0\n")
    }
}
