import DylManifest
import DylToolSupport
import Foundation
import Testing

#if canImport(CryptoKit)
import CryptoKit
#endif

@testable import ReleaseKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

private func fixture(_ path: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: path), encoding: .utf8)
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
    private func feed(_ items: [(version: String, description: String)]) -> [AppcastItem] {
        let body = items.map { item in
            "<item><title>\(item.version)</title><description><![CDATA[\(item.description)]]></description></item>"
        }
        return Appcast.items(in: Data("<rss><channel>\(body.joined())</channel></rss>".utf8))
    }

    /// The committed feed wins over a stale live one, version-less placeholders drop out, and `Version`/`v`
    /// prefixes on legacy headings are normalized.
    @Test func mergesFeedsNewestFirstDedupedAndCapped() {
        let committed = feed([("1.0.12", "<h3>1.0.12</h3><ul><li>Twelve</li></ul><h3>1.0.11</h3><ul><li>Eleven</li></ul>")])
        let live = feed([
            ("1.0.11", "<h3>1.0.11</h3><ul><li>Stale eleven</li></ul>"),
            ("1.0.7", "<p>Release v1.0.7</p>"),
            ("1.0.6", "<h3>Version 1.0.6</h3><ul><li>Older &amp; wiser.</li></ul><h3>v1.0.5</h3><ul><li>Five</li></ul>"),
        ])
        func versions(_ html: String) -> [String] { html.matches(of: /<h3[^>]*>([^<]+)<\/h3>/).map { String($0.1) } }

        let new = "<ul><li>New</li></ul>"
        let all = CumulativeNotes.html(version: "1.0.13", build: "30", newNotes: new, history: [committed, live])
        #expect(versions(all) == ["1.0.13", "1.0.12", "1.0.11", "1.0.6", "1.0.5"])
        #expect(all.contains("Eleven") && !all.contains("Stale") && !all.contains("1.0.7"))
        #expect(all.contains("Older &amp; wiser."))
        let capped = CumulativeNotes.html(
            version: "1.0.13", build: "30", newNotes: new, history: [committed, live], maxVersions: 3)
        #expect(versions(capped) == ["1.0.13", "1.0.12", "1.0.11"])
    }

    @Test func stampsSectionsWithBuildsAndReadsThemBack() throws {
        func feed(_ version: String, build: String, description: String) -> [AppcastItem] {
            let xml = """
                <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
                <title>\(version)</title><sparkle:version>\(build)</sparkle:version>
                <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
                <description><![CDATA[\(description)]]></description>
                </item></channel></rss>
                """
            return Appcast.items(in: Data(xml.utf8))
        }
        let li = #"<li style="\#(NotesFormatter.bulletStyle)">"#
        let legacy = "<h3>1.0.9</h3><ul><li>Nine</li></ul><h3>1.0.8</h3><ul><li>Eight</li></ul>"
            + "<h3>1.0.7</h3><p>Release v1.0.7</p><h3>1.0.6</h3><ul><li>Six</li></ul>"
        let first = CumulativeNotes.html(
            version: "1.0.10", build: "27", newNotes: "<ul><li>Ten</li></ul>",
            history: [feed("1.0.9", build: "24", description: legacy)], knownBuilds: ["1.0.8": "22", "1.0.7": "20"])
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
            history: [feed("1.0.10", build: "27", description: first)], maxVersions: 5)
        #expect(second.components(separatedBy: "<style>").count == 2)
        let stamps = second.matches(of: /<section( data-sparkle-version="(\d+)")?/).map { $0.2.map(String.init) ?? "-" }
        #expect(stamps == ["30", "27", "24", "22", "20"])
        #expect(second.contains("<h3 style=\"\(previous)\">1.0.10</h3>\n<ul>\(li)Ten</li></ul>"))
        #expect(second.hasSuffix(#"<section data-sparkle-version="20" data-version="1.0.7"></section>"#))
    }

    @Test func parsesTheLiveAppcast() throws {
        let item = try #require(Appcast.items(at: fixtures.appending(path: "sconeos-appcast.xml")).first)
        #expect(item.displayVersion == "1.0.9")
        #expect(item.build == "24")
        #expect(item.minimumSystemVersion == "14.0")
        #expect(item.enclosureURL == "https://sconeos.gattey.com/Sconeos-1.0.9.zip")
        #expect(item.edSignature?.isEmpty == false)
        #expect(item.enclosureLength ?? 0 > 0)
    }
}

@Suite struct VersioningTests {
    private let feed = Appcast.items(at: fixtures.appending(path: "sconeos-appcast.xml"))

    @Test func currentVersionIsTheHighestKnown() {
        #expect(ReleasePipeline.currentVersion(appcasts: [feed], tags: ["v1.0.5"]).description == "1.0.9")
        #expect(ReleasePipeline.currentVersion(appcasts: [], tags: ["v2.0.0", "junk"]).description == "2.0.0")
        #expect(ReleasePipeline.currentVersion(appcasts: [], tags: []).description == "1.0.0")
    }

    @Test func buildNumberStaysAboveThePublishedOne() {
        #expect(ReleasePipeline.nextBuild(commitCount: 10, appcasts: [feed]) == 25)
        #expect(ReleasePipeline.nextBuild(commitCount: 300, appcasts: [feed]) == 300)
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
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try DylAppManifest.load(root: root)
        let key = try String(contentsOf: root.appending(path: "sparkle-public-key.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = InfoPlist.contents(
            manifest: manifest, shortVersion: "1.2.3", build: "45", sparklePublicKey: key)
        #expect(generated["CFBundleIdentifier"] == .string(manifest.app.bundleId))
        #expect(generated["CFBundleShortVersionString"] == .string("1.2.3"))
        #expect(generated["CFBundleVersion"] == .string("45"))
        #expect(generated["LSMinimumSystemVersion"] == .string(manifest.app.platforms.macos))
        #expect(generated["SUFeedURL"] == .string(manifest.release.feedURL))
        #expect(generated["SUPublicEDKey"] == .string(key))
        #expect(generated["NSBonjourServices"] == .array([.string("_sonos._tcp")]))
        #expect(generated["NSLocalNetworkUsageDescription"]?.string?.isEmpty == false)
        guard case .array(let urlTypes) = generated["CFBundleURLTypes"], case .dictionary(let urlType) = urlTypes.first
        else { Issue.record("no CFBundleURLTypes"); return }
        #expect(urlType["CFBundleURLSchemes"] == .array([.string("sconeos")]))
        let roundTrip = try PropertyListDecoder().decode(Plist.self, from: try InfoPlist.data(generated))
        #expect(roundTrip == generated)
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

/// Runs the tier 3 checks over a scratch copy of this repo's release files with a chosen set of workflows.
@Suite struct ReleaseChecksTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static let committedWorkflows = ["release", "verify", "pr-check"].map { ".github/workflows/\($0).yml" }

    private func scratchWorkspace(workflows: [String: String]) throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appending(path: "dylkit-checks-\(UUID().uuidString)")
        for path in [
            "DylApp.toml", "Package.swift", "sparkle-public-key.txt", ".github/pull_request_template.md",
            "server/public", "Packages/DylKit/Package.swift",
            "Packages/DylKit/Sources/ReleaseKit/ReleasePipeline.swift", "ci/github/pr-body.sh",
            "Sconeos.local.entitlements", "server/package.json", "server/vercel.json",
        ] {
            let destination = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Self.repoRoot.appending(path: path), to: destination)
        }
        for (path, text) in workflows {
            let destination = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: destination)
        }
        return try Workspace.locate(root.path)
    }

    private func committed() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: Self.committedWorkflows.map {
            ($0, try String(contentsOf: Self.repoRoot.appending(path: $0), encoding: .utf8))
        })
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
        let workspace = try scratchWorkspace(workflows: try committed())
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(errors(ReleaseChecks(workspace: workspace).run()).isEmpty)
    }

    /// Photos #9: library validation must be off to load Sparkle ad-hoc. DylKit apps have no Xcode project.
    @Test func libraryValidationOffAndNoXcodeProject() throws {
        let workspace = try scratchWorkspace(workflows: try committed())
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let entitlements = workspace.url("Sconeos.local.entitlements")
        let text = try String(contentsOf: entitlements, encoding: .utf8)
        try Data(text.replacing("disable-library-validation", with: "allow-jit").utf8).write(to: entitlements)
        let project = workspace.url("Sconeos.xcodeproj/project.pbxproj")
        try FileManager.default.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: project)

        let swiftPMWorkspace = workspace.url(".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata")
        try FileManager.default.createDirectory(
            at: swiftPMWorkspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: swiftPMWorkspace)

        let report = ReleaseChecks(workspace: workspace).run()
        #expect(errors(report)["library_validation"]?.count == 1)
        #expect(errorFiles(report)["swiftpm_only"] == ["Sconeos.xcodeproj"])
    }

    /// Saga #45: Vercel's ignoreCommand must still deploy release commits and the shared web package.
    @Test func siteDeploySkipsOnlyWhatTheSiteDoesntRead() throws {
        let workspace = try scratchWorkspace(workflows: try committed())
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let config = #"{ "ignoreCommand": "git diff --quiet HEAD^ HEAD -- app" }"#
        try Data(config.utf8).write(to: workspace.url("server/vercel.json"))

        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["site_deploy"] == [
            "server/vercel.json", "server/vercel.json", "server/vercel.json",
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
        let workspace = try scratchWorkspace(workflows: [".github/workflows/release-macos.yml": legacy])
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let workflow = ".github/workflows/release-macos.yml"
        let files = errorFiles(ReleaseChecks(workspace: workspace).run())
        #expect(files["forge_neutral"] == [workflow, workflow])
        #expect(files["unused_ci_secret"] == [workflow])
        #expect(files["release_trigger_drift"] == [workflow])
    }

    @Test func onlyTheCIWrapperTalksToTheForge() throws {
        let lookup = "curl -fsSL https://api.github.com/repos/o/r/commits/abc/pulls\n"
        var workflows = try committed()
        workflows["ci/github/lookup.sh"] = lookup
        workflows["scripts/lookup.sh"] = lookup
        let workspace = try scratchWorkspace(workflows: workflows)
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["forge_neutral"] == ["scripts/lookup.sh"])
    }

    @Test func droppedReleaseInputDrifts() throws {
        var workflows = try committed()
        workflows[".github/workflows/release.yml"] = workflows[".github/workflows/release.yml"]?
            .replacingOccurrences(of: "      - 'DylApp.toml'\n", with: "")
        let workspace = try scratchWorkspace(workflows: workflows)
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(
            errorFiles(ReleaseChecks(workspace: workspace).run())["release_trigger_drift"]
                == [".github/workflows/release.yml"])
    }
}

