import DylManifest
import DylToolSupport
import Foundation
import Testing

#if canImport(CryptoKit)
import CryptoKit
#endif

@testable import ReleaseKit
import ReleaseNotes

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

private let appModules = ["DemoDomain", "DemoStore", "DemoUI", "DemoApp"]

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

            - Fixed the map (`Sources/DemoUI/MapView.swift`, `MapView.swift`) so it stops jumping.
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
              <li style="margin-bottom: 6px; line-height: 1.45;">star bullet with code</li>
            </ul>
            """#
        ),
    ]

    @Test(arguments: cases) func formatsTheNotesSection(_ body: String, _ html: String) {
        let formatter = NotesFormatter(pathRoots: NotesFormatter.defaultPathRoots + appModules)
        let extracted = ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "")
        #expect(formatter.html(extracted.isEmpty ? body : extracted, version: "2.3.4") == html)
    }
}

@Suite struct ReleaseNotesTests {
    @Test func releaseNotesWinOverWhatChangedWithoutCommentsOrFooters() {
        let body = """
            # What changed?

            - Builds with `--disable-get-task-allow-entitlement` in `Bundler.swift`.

            # Release notes
            <!-- Aim for 3 plain-English bullets, up to 5. -->

            - Dev builds no longer print code-signing warnings (#8).

            # Release info

            - [x] Patch
            """
        #expect(ReleaseNotes.markdown(body: body) == "- Dev builds no longer print code-signing warnings (#8).")
        #expect(ReleaseNotes.problems(inBody: body).isEmpty)
        let footer = "# Release notes\n\n- Faster sync.\n\n---\n\n- [Open in Cursor](https://cursor.com/agents/bc-1)"
        #expect(ReleaseNotes.markdown(body: footer) == "- Faster sync.")
    }

    @Test func whatChangedIsTheFallbackWhenReleaseNotesAreMissingOrEmpty() {
        let body = "# Release notes\n\n- \n\n# Highlights\n\n- Old heading.\n\n# What changed?\n\n- Map drags."
        #expect(ReleaseNotes.markdown(body: body) == "- Map drags.")
        #expect(ReleaseNotes.markdown(body: "# Summary\n\n- Faster sync.") == "- Faster sync.")
        #expect(ReleaseNotes.markdown(body: "<!-- # Release notes\n- Hidden. -->") == nil)
        #expect(ReleaseNotes.problems(inBody: "# What changed?\n\n- Map drags.") == [
            "there's no # Release notes section with content; add plain-English bullets above # Release info, aim for 3, up to 5"
        ])
    }

    @Test(arguments: [
        ("- Uses `shippedVersion()` now.", "backticked code `shippedVersion()`"),
        ("- Edited Sources/ReleaseKit/Bundler.swift.", "a file path Sources/ReleaseKit/Bundler.swift"),
        ("- Moved the check to web/src.", "a file path web/src"),
        ("- Reads DylApp.toml and package.json.", "a file path DylApp.toml, package.json"),
        ("- Builds with --disable-get-task-allow-entitlement.", "a command-line flag --disable-get-task-allow-entitlement"),
        ("- Calls shippedVersion() first.", "a code identifier shippedVersion()"),
        ("- Fixed Bundler.fixRpaths and state.externalPlayer.", "a code identifier Bundler.fixRpaths, state.externalPlayer"),
        ("- Sets BLOB_READ_WRITE_TOKEN and site_deploy.", "a code identifier BLOB_READ_WRITE_TOKEN, site_deploy"),
        ("- Ships @dylkit/web.", "a code identifier @dylkit/web"),
        ("- Drops .changelog__code styling.", "a CSS selector or dotfile .changelog__code"),
    ])
    func rejectsCode(_ notes: String, _ problem: String) {
        #expect(ReleaseNotes.problems(in: notes) == ["\(problem) in “\(notes)”"])
    }

    @Test func acceptsPlainEnglish() {
        let notes = """
            - The iOS and macOS apps show the same version, like v0.3.5, on iPhone's Settings screen (#10).
            - Node.js 22 builds of the download site at example.com work again, e.g. on Vercel — see [the PR](https://github.com/dgattey/dyl-kit/pull/9).
            - **Faster sync:** Apple silicon and Intel Macs re-sign the app once, 24/7 and/or on demand, since 10/24/2026.
            """
        #expect(ReleaseNotes.problems(in: notes).isEmpty)
        #expect(ReleaseNotes.problems(in: "One plain sentence for internal plumbing (#4).").isEmpty)
    }

    @Test func allowsUpToFiveBullets() {
        let five = "- One.\n- Two.\n- Three.\n- Four.\n- Five."
        #expect(ReleaseNotes.problems(in: five).isEmpty)
        #expect(ReleaseNotes.problems(in: five + "\n- Six.") == ["6 bullets; aim for 3, up to 5"])
    }

    /// A real PR put a component name in backticks in otherwise user-facing notes.
    @Test func aBacktickedComponentNameFailsTheRules() throws {
        let problems = ReleaseNotes.problems(inBody: try fixture("release-info/pr-7-body.md"))
        #expect(problems.count == 1 && problems[0].hasPrefix("backticked code `Playing on This computer`"))
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

    @Test func foldedMergesTakeTheLargestBumpAndEveryMergesNotesNewestFirst() {
        let site = "# Release notes\n\n- New site.\n\n# Release info\n\n- [x] Minor"
        let folded = ReleaseInfo.folded([
            .init(subject: "Site", body: site, bump: .minor),
            .init(subject: "Fix a thing", body: "No notes here", bump: .patch),
        ])
        #expect(folded.bump == .minor)
        #expect(ReleaseInfo.releaseType(in: folded.body) == .minor)
        #expect(ReleaseInfo.notesMarkdown(body: folded.body, fallbackTitle: "") == "- New site.\n- Fix a thing")
    }

    @Test func readsThePullRequestFromSquashAndMergeCommits() {
        #expect(ReleaseInfo.pullRequestNumber(in: "Composable download site (#12)\n\n* Shadow (#3)") == 12)
        #expect(ReleaseInfo.pullRequestNumber(in: "Merge pull request #7 from owner/site\n\nSite") == 7)
        #expect(ReleaseInfo.pullRequestNumber(in: "Bump the version\n\n(#4)") == nil)
    }

    /// A real PR checked Minor but shipped as 1.0.6: the squash commit carried only the commit list, and the old
    /// scripts defaulted to patch. Its body, verbatim, has prose and a rule before the heading and labels after each box.
    @Test func releasesAsMinorFromItsBodyAndNeverDefaultsToPatch() throws {
        let body = try fixture("release-info/pr-7-body.md")
        let squashMessage = try fixture("release-info/pr-7-merge-commit.txt")
        #expect(ReleaseInfo.releaseType(in: body) == .minor)
        #expect(ReleaseInfo.releaseType(in: body.replacingOccurrences(of: "\n", with: "\r\n")) == .minor)
        #expect(try ReleaseInfo.source(prBody: body, commitBody: squashMessage).bump == .minor)
        #expect(throws: ToolError.self) { try ReleaseInfo.source(prBody: nil, commitBody: squashMessage) }
        #expect(ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "").hasPrefix("- **One-click Spotify transfer:**"))
    }

    /// An agent-written body between markers, with a footer after them.
    @Test func notesComeFromTheFirstNonEmptySectionElseTheTitle() {
        let body = """
            <!-- CURSOR_AGENT_PR_BODY_BEGIN -->
            # Release notes

            - The app no longer stalls at launch.

            # What changed?

            - `Household.waitForTopology` stops spinning once cancelled.

            # Release info

            - [x] Patch
            <!-- CURSOR_AGENT_PR_BODY_END -->

            <div><a href="https://cursor.com/agents/bc-1">Open in Cursor</a></div>
            """
        #expect(ReleaseInfo.notesMarkdown(body: body, fallbackTitle: "Title") == "- The app no longer stalls at launch.")
        let empty = "# Release notes\n\n- \n\n# What changed?\n\n- "
        #expect(ReleaseInfo.notesMarkdown(body: empty, fallbackTitle: "Fix the map") == "- Fix the map")
    }

    /// The secret may hold the exported key text or that text base64-encoded again.
    @Test func sparkleKeySecretAcceptsSingleOrDoubleBase64() throws {
        let exported = Data(repeating: 7, count: 32).base64EncodedString()
        let doubled = Data(exported.utf8).base64EncodedString()
        #expect(try ReleasePipeline.edKeyFile(fromSecret: exported) == Data(exported.utf8))
        let wrapped = "\(doubled.prefix(20))\n\(doubled.dropFirst(20))"
        #expect(try ReleasePipeline.edKeyFile(fromSecret: wrapped) == Data(exported.utf8))
        #expect(throws: ToolError.self) { try ReleasePipeline.edKeyFile(fromSecret: "not base64!") }
    }

    /// `## Summary` with `### Changes` under it was cut at the subheading, and reviewer sections leaked in.
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
        #expect(ReleaseNotes.section("Description", in: "# Description\n- Faster sync.") == "- Faster sync.")
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

    /// The first feed wins over a stale later one, placeholder notes drop out, and `Version`/`v` prefixes on
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
        let all = CumulativeNotes.html(version: "1.0.13", build: "30", newNotes: new, history: committed + live)
        #expect(versions(all) == ["1.0.13", "1.0.12", "1.0.11", "1.0.6", "1.0.5"])
        #expect(all.contains("Eleven") && !all.contains("Stale") && !all.contains("Release v1.0.7"))
        #expect(all.contains("Older &amp; wiser."))
        let capped = CumulativeNotes.html(
            version: "1.0.13", build: "30", newNotes: new, history: committed + live, maxVersions: 3)
        #expect(versions(capped) == ["1.0.13", "1.0.12", "1.0.11"])
    }

    @Test func stampsSectionsWithBuildsAndReadsThemBack() throws {
        let li = #"<li style="\#(NotesFormatter.bulletStyle)">"#
        let legacy = "<h3>1.0.9</h3><ul><li>Nine</li></ul><h3>1.0.8</h3><ul><li>Eight</li></ul>"
            + "<h3>1.0.7</h3><p>Release v1.0.7</p><h3>1.0.6</h3><ul><li>Six</li></ul>"
        let first = CumulativeNotes.html(
            version: "1.0.10", build: "27", newNotes: "<ul><li>Ten</li></ul>",
            history: try feed([("1.0.9", 24, legacy), ("1.0.8", 22, ""), ("1.0.7", 20, "")]))
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
            history: try feed([("1.0.10", 27, first)]), maxVersions: 5)
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

/// Runs the tier 3 checks over a scratch copy of the SampleApp, plus `extra` files.
@Suite struct ReleaseChecksTests {
    private func scratchWorkspace(_ extra: [String: String] = [:]) throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appending(path: "dylkit-checks-\(UUID().uuidString)")
        let appFiles = [
            "DylApp.toml", "Package.swift", "sparkle-public-key.txt", "Sample.entitlements", "server/package.json",
            "server/vercel.json", "server/app/releases/page.tsx", ".github/pull_request_template.md",
            ".github/workflows/dylkit.yml",
            ".github/workflows/verify.yml", ".cursor/rules/changelog-release-notes.mdc",
        ]
        for path in appFiles {
            let destination = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: appRoot.appending(path: path), to: destination)
        }
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

    private static let downloadPrefix = "https://abc123.public.blob.vercel-storage.com/releases/v1.0.9/"

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

    @Test func prTemplateNeedsReleaseNotesAboveReleaseInfoAndTheRule() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let template = workspace.url(".github/pull_request_template.md")
        let original = try String(contentsOf: template, encoding: .utf8)
        func failures(_ text: String) throws -> [String]? {
            try Data(text.utf8).write(to: template)
            return errors(ReleaseChecks(workspace: workspace).run())["release_notes"]
        }
        #expect(try failures(original) == nil)
        #expect(try failures("# What changed?\n\n-\n\n# Release info\n\n- [x] Patch") != nil)
        #expect(try failures("<!-- # Release notes -->\n# Release info\n\n- [x] Patch") != nil)
        #expect(try failures("# Release info\n\n- [x] Patch\n\n## Release notes\n\n-") != nil)
        #expect(try failures("## Release notes\n\n-\n\n## Release info\n\n- [x] Patch") == nil)

        try FileManager.default.removeItem(at: workspace.url(".cursor/rules/changelog-release-notes.mdc"))
        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["release_notes"] == [
            ".cursor/rules/changelog-release-notes.mdc"
        ])
    }

    /// Library validation must be off to load Sparkle ad-hoc. DylKit apps have no Xcode project.
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

    /// The update dialog and Sparkle's Version History button link every version's notes at `/releases`.
    @Test func aDylKitSiteServesTheReleasesPage() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(errors(ReleaseChecks(workspace: workspace).run())["releases_page"] == nil)

        try FileManager.default.removeItem(at: workspace.url("server/app/releases/page.tsx"))
        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["releases_page"] == ["server/app/releases/page.tsx"])
    }

    /// Vercel's ignoreCommand must still deploy release commits and DylApp.toml, which withDylKit reads.
    @Test func siteDeploySkipsOnlyWhatTheSiteDoesntRead() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let command = ReleaseChecks.ignoreCommandPrefix.replacingOccurrences(of: "\"", with: #"\""#) + "app"
        let config = #"{ "ignoreCommand": "\#(command)" }"#
        try Data(config.utf8).write(to: workspace.url("server/vercel.json"))

        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["site_deploy"] == [
            "server/vercel.json", "server/vercel.json",
        ])
    }

    /// Diffing from HEAD^ can skip a site change Vercel never deployed, including on a branch's first
    /// deploy, when VERCEL_GIT_PREVIOUS_SHA is empty.
    @Test(arguments: [
        #"git diff --quiet HEAD^ HEAD -- . ../DylApp.toml"#,
        #"git diff --quiet \"${VERCEL_GIT_PREVIOUS_SHA:-HEAD^}\" HEAD -- . ../DylApp.toml"#,
    ])
    func siteDeployDiffsFromTheLastDeploy(command: String) throws {
        let workspace = try scratchWorkspace(["server/vercel.json": #"{ "ignoreCommand": "\#(command)" }"#])
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        #expect(errors(ReleaseChecks(workspace: workspace).run())["site_deploy"] == [
            #"diffs from HEAD^, which can skip a site change Vercel never deployed; use `"ignoreCommand": "#
                + #""git rev-parse --quiet --verify \"$VERCEL_GIT_PREVIOUS_SHA^{commit}\" && "#
                + #"git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- <paths>"`"#
        ])
    }

    /// The unguarded command fails every deploy after a rebase, so the check names the replacement with the app's
    /// paths.
    @Test func siteDeployNamesTheGuardedCommandForTheOldOne() throws {
        let old = #"[ -n \"$VERCEL_GIT_PREVIOUS_SHA\" ] && git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml"#
        let workspace = try scratchWorkspace(["server/vercel.json": #"{ "ignoreCommand": "\#(old)" }"#])
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        #expect(errors(ReleaseChecks(workspace: workspace).run())["site_deploy"] == [
            "exits 128 and fails the deploy when Vercel's clone lacks the last deployed commit, as after a force-push "
                + #"or rebase; use `"ignoreCommand": "git rev-parse --quiet --verify \"$VERCEL_GIT_PREVIOUS_SHA^{commit}\" "#
                + #"&& git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml"`"#
        ])
    }

    /// Vercel builds on exit 1, skips on 0 and fails the deploy on anything else. The previous SHA is missing after a
    /// force-push or rebase, and empty on a branch's first deploy.
    @Test func sampleIgnoreCommandBuildsWhenThePreviousCommitIsMissing() throws {
        let config = try String(contentsOf: appRoot.appending(path: "server/vercel.json"), encoding: .utf8)
        let command = try #require(
            try JSONDecoder().decode([String: String].self, from: Data(config.utf8))["ignoreCommand"])
        let repo = FileManager.default.temporaryDirectory.appending(path: "dylkit-ignore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let server = repo.appending(path: "server")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        func commit(_ path: String, _ text: String) throws -> String {
            try Data(text.utf8).write(to: repo.appending(path: path))
            _ = try Shell.capture(["git", "add", "."], cwd: repo)
            let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]
            _ = try Shell.capture(["git"] + identity + ["commit", "--quiet", "-m", path], cwd: repo)
            return try Shell.capture(["git", "rev-parse", "HEAD"], cwd: repo)
        }
        func ignore(previous: String) throws -> Int32 {
            try Shell.run(
                ["sh", "-c", command], cwd: server, environment: ["VERCEL_GIT_PREVIOUS_SHA": previous], quiet: true,
                allowFailure: true)
        }
        _ = try Shell.capture(["git", "init", "--quiet"], cwd: repo)
        _ = try commit("DylApp.toml", "a")
        let deployed = try commit("server/page.txt", "a")
        _ = try commit("notes.txt", "a")

        #expect(try ignore(previous: deployed) == 0)
        #expect(try ignore(previous: "0123456789abcdef0123456789abcdef01234567") == 1)
        #expect(try ignore(previous: "") == 1)
        _ = try commit("DylApp.toml", "b")
        #expect(try ignore(previous: deployed) == 1)
    }

    @Test func aSecretNothingReadsFails() throws {
        let verify = """
            jobs:
              verify:
                steps:
                  - run: swift test
                    env:
                      GH_TOKEN: ${{ secrets.GH_TOKEN }}
                      SPARKLE_ED_PRIVATE_KEY_BASE64: ${{ secrets.SPARKLE_ED_PRIVATE_KEY_BASE64 }}
            """
        let workflow = ".github/workflows/verify.yml"
        let workspace = try scratchWorkspace([workflow: verify])
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(errorFiles(ReleaseChecks(workspace: workspace).run())["unused_ci_secret"] == [workflow])
    }

    /// dylkit.yml hands app.yml the release secrets with `secrets: inherit`, so a script that uploads one is fine.
    @Test func secretsPassedToAppWorkflowCountAsUsed() throws {
        let upload = "gh secret set BLOB_READ_WRITE_TOKEN < token.txt\n"
        let workspace = try scratchWorkspace(["scripts/secrets.sh": upload])
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        #expect(errors(ReleaseChecks(workspace: workspace).run())["unused_ci_secret"] == nil)
    }

    @Test func appScriptsNeverTalkToTheForge() throws {
        let lookup = "curl -fsSL https://api.github.com/repos/o/r/commits/abc/pulls\n"
        let workspace = try scratchWorkspace(["scripts/lookup.sh": lookup, "scripts/run": "gh pr view 1\n"])
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let flagged = errorFiles(ReleaseChecks(workspace: workspace).run())["forge_neutral"]?.sorted()
        #expect(flagged == ["scripts/lookup.sh", "scripts/run"])
    }

    /// Apps no longer vendor release-kit's sources, so the forge_neutral scan can't see them; check them here.
    @Test func releaseKitNeverTalksToTheForge() throws {
        let sources = packageRoot.appending(path: "Sources")
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        let allowed = ["ReleaseKit/GitHub.swift"]
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

    /// A `file:` @dylkit/web points into `.build/checkouts`, which Vercel never has.
    @Test func fileDependencyOnTheWebPackageSaysToUseTheTarball() throws {
        let workspace = try scratchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = workspace.url("server/package.json")
        let text = try String(contentsOf: package, encoding: .utf8)
            .replacing(/"@dylkit\/web": "[^"]+"/, with: #""@dylkit/web": "file:../.build/checkouts/dyl-kit/web""#)
        try Data(text.utf8).write(to: package)

        let messages = errors(ReleaseChecks(workspace: workspace).run())["site_deploy"] ?? []
        #expect(messages.count == 1)
        #expect(messages.first?.contains("/releases/v<version>/dylkit-web-<version>.tgz") == true)
    }

    /// The fixture's site and workflow pin DylKit 0.3.0. A 0.2 app that migrates keeps no synced workflow beside
    /// dylkit.yml, which would release twice.
    @Test func everyPinMatchesTheResolvedDylKit() throws {
        func messages(_ state: String, _ extra: [String: String] = [:]) throws -> [String]? {
            let resolved = #"{ "pins": [{ "identity": "dyl-kit", "state": \#(state) }], "version": 3 }"#
            let workspace = try scratchWorkspace(extra.merging(["Package.resolved": resolved]) { $1 })
            defer { try? FileManager.default.removeItem(at: workspace.root) }
            return errors(ReleaseChecks(workspace: workspace).run())["dylkit_version"]
        }
        #expect(try messages(#"{ "version": "0.3.0" }"#) == nil)
        #expect(try messages(#"{ "branch": "main" }"#) == nil)
        #expect(
            try messages(#"{ "version": "0.3.1" }"#) == [
                "calls dgattey/dyl-kit/.github/workflows/app.yml@v0.3.0 but Package.resolved pins DylKit 0.3.1; "
                    + "use @v0.3.1",
                "@dylkit/web is 0.3.0 but Package.resolved pins DylKit 0.3.1; depend on "
                    + "\"https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v0.3.1/dylkit-web-0.3.1.tgz\"",
            ])
        let synced = "# Written by `devkit sync` from DylKit. Change DylKit's copy, not this one.\nname: release\n"
        #expect(
            try messages(
                #"{ "version": "0.3.0" }"#,
                [".github/workflows/dylkit.yml": "name: dylkit\n", ".github/workflows/release.yml": synced]) == [
                    "nothing calls dgattey/dyl-kit/.github/workflows/app.yml; copy .github/workflows/dylkit.yml from "
                        + "DylKit's SampleApp",
                    "is DylKit 0.2's synced copy, which dylkit.yml replaces; delete it",
                ])
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
/// A release once failed when a `git ls-remote` ref leaked into it.
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
        #expect(
            output
                == "version=1.1.0\nbuild=1\nsite=https://dgattey.github.io/dyl-kit-sample\n"
                + "assets=https://dylkitsample.public.blob.vercel-storage.com\n")
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

        let version = [releaseKit.path, "library", "version", "--root", library.path]
        #expect(try Shell.capture(version) == "version=0.2.0")
        try git(["tag", "v0.2.0"], in: library)
        #expect(try Shell.capture(version) == "version=0.2.0")
    }
}
