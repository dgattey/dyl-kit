import DylToolSupport
import Foundation
import Testing

@testable import ReleaseKit

private typealias Entry = ReleaseHistory.Entry

private func date(_ iso: String) throws -> Date { try Date(iso, strategy: .iso8601) }

/// One staged item the way `generate_appcast` writes it, with `description` as its embedded notes.
private func stagedItem(_ version: String, build: Int, description: String = "", day: Int = 1) throws -> AppcastItem {
    let rfc822 = DateFormatter()
    rfc822.locale = Locale(identifier: "en_US_POSIX")
    rfc822.timeZone = TimeZone(identifier: "UTC")
    rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    let pubDate = rfc822.string(from: try date("2026-10-\(String(format: "%02d", day))T12:00:00Z"))
    let xml = sparkleFeed(
        """
        <item><title>\(version)</title><sparkle:version>\(build)</sparkle:version>
        <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <pubDate>\(pubDate)</pubDate>
        <description><![CDATA[\(description)]]></description>
        </item>
        """)
    return try #require(Appcast.items(in: Data(xml.utf8), source: "feed").first)
}

/// Round-trips through `history.json` the way the next release reads what this one published.
private func published(_ history: ReleaseHistory) throws -> ReleaseHistory {
    let file = FileManager.default.temporaryDirectory.appending(path: "dylkit-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try history.write(to: file)
    return try ReleaseHistory.read(file)
}

@Suite struct ReleaseHistoryTests {
    @Test func fillingKeepsWhatsThereAndAddsWhatsMissing() {
        let history = ReleaseHistory(releases: [Entry(version: "1.1.0", build: 12, html: "<p>Kept</p>")])
            .filling([
                Entry(version: "1.1.0", build: 99, publishedAt: Date(timeIntervalSince1970: 0), html: "<p>Older</p>"),
                Entry(version: "1.10.0", html: "<p>Ten</p>"),
                Entry(version: "1.2.0"),
            ])
        #expect(history.releases.map(\.version) == ["1.10.0", "1.2.0", "1.1.0"])
        #expect(history.releases[2] == Entry(version: "1.1.0", build: 12, publishedAt: Date(timeIntervalSince1970: 0), html: "<p>Kept</p>"))
    }

    /// GitHub re-runs whole jobs, so publishing the same release twice must give the same file.
    @Test func aRerunReplacesItsOwnEntryAndConverges() throws {
        let earlier = try published(ReleaseHistory(releases: [Entry(version: "1.0.0", build: 1, html: "<p>One</p>")]))
        let first = try stagedItem("1.1.0", build: 2, description: "<ul><li>First try</li></ul>")
        let retry = try stagedItem("1.1.0", build: 2, description: "<ul><li>Second try</li></ul>")
        let once = try published(ReleaseHistory.next(published: earlier, staged: first, feeds: []))
        let twice = try published(ReleaseHistory.next(published: once, staged: retry, feeds: []))
        #expect(twice.releases.map(\.html) == ["<ul><li>Second try</li></ul>", "<p>One</p>"])
        #expect(try published(ReleaseHistory.next(published: twice, staged: retry, feeds: [])) == twice)
    }

    /// Gattey Photos' appcasts before 1.1.6 had no notes; their releases still belong in the history.
    @Test func anItemWithoutNotesIsStillARelease() throws {
        let entries = ReleaseHistory.entries(from: try stagedItem("1.0.3", build: 7, day: 5))
        #expect(entries == [Entry(version: "1.0.3", build: 7, publishedAt: try date("2026-10-05T12:00:00Z"))])
        #expect(ReleaseHistory.siteHTML(#"<p style="margin: 0;">Release v1.0.3</p>"#).isEmpty)
    }

    @Test func gitHubReleasesBecomeEntries() throws {
        let releases = [
            GitHub.Release(tagName: "v1.9.3", body: "- Shiny (#61).", publishedAt: try date("2026-10-22T19:37:49Z"), draft: false, prerelease: false),
            GitHub.Release(tagName: "v2.0.0", body: "- Soon", publishedAt: nil, draft: true, prerelease: false),
            GitHub.Release(tagName: "nightly", body: "- Nightly", publishedAt: nil, draft: false, prerelease: false),
            GitHub.Release(tagName: "v1.0.0", body: nil, publishedAt: nil, draft: false, prerelease: false),
        ]
        #expect(
            ReleaseHistory.entries(from: releases) == [
                Entry(version: "1.9.3", publishedAt: try date("2026-10-22T19:37:49Z"), html: "<ul>\n  <li>Shiny (#61).</li>\n</ul>"),
                Entry(version: "1.0.0"),
            ])
    }

    @Test func readsEveryPageOfGitHubReleases() async throws {
        let page = (1...100).map { #"{"tag_name": "v1.0.\#($0)", "draft": false, "prerelease": false}"# }
        let transport = FakeTransport { request in
            if request.url?.query?.hasSuffix("&page=1") == true { return (200, "[\(page.joined(separator: ","))]") }
            return (200, #"[{"tag_name": "v0.9.0", "body": "- Old", "published_at": "2026-01-02T03:04:05Z", "draft": false, "prerelease": false}]"#)
        }
        let releases = try await GitHub(environment: ["GITHUB_REPOSITORY": "o/app", "GITHUB_TOKEN": "t"], transport: transport)
            .releases()
        #expect(releases.count == 101)
        #expect(releases.last?.publishedAt == (try date("2026-01-02T03:04:05Z")))
        #expect(
            await transport.calls == [
                "GET https://api.github.com/repos/o/app/releases?per_page=100&page=1",
                "GET https://api.github.com/repos/o/app/releases?per_page=100&page=2",
            ])
    }

    /// Only a 404 is a first release: appending to a history that merely failed to load would drop every release.
    @Test func thePublishedHistoryIsReadStrictly() async throws {
        let url = "https://abc123.public.blob.vercel-storage.com/history.json"
        #expect(try await ReleaseHistory.published(url, transport: FakeTransport { _ in (404, "") }).releases.isEmpty)
        for (status, body) in [(500, ""), (200, "<html>Rate limited")] {
            await #expect(throws: ToolError.self) {
                try await ReleaseHistory.published(url, transport: FakeTransport { _ in (status, body) })
            }
        }
    }
}

/// Dylan asked whether a Mac more than ten releases behind still sees what's latest. This publishes twenty releases
/// through the real notes, appcast and history code, then looks at them as an install of the fifth would.
@Suite struct OldClientTests {
    private let site = "https://dylkitsample.gattey.com"

    private struct Release {
        var feed: [AppcastItem]
        var history: ReleaseHistory
    }

    /// Each release's appcast holds only its own item, as `generate_appcast` writes it from a folder with one zip.
    private func publishTwentyReleases() throws -> Release {
        var feed: [AppcastItem] = []
        var history = ReleaseHistory()
        for patch in 1...20 {
            let notes = CumulativeNotes.html(
                version: "1.0.\(patch)", build: String(10 + patch), newNotes: "<ul><li>Fix \(patch)</li></ul>",
                history: feed, allNotesURL: site + "/releases")
            let item = try stagedItem("1.0.\(patch)", build: 10 + patch, description: notes, day: patch)
            history = try published(ReleaseHistory.next(published: history, staged: item, feeds: feed))
            feed = [item]
        }
        return Release(feed: feed, history: history)
    }

    /// Sparkle's choice (`SUAppcastDriver.bestItemFromAppcastItems`): the newest item this Mac can run, if it's newer.
    private func offered(_ feed: [AppcastItem], installedBuild: Int, macOS: String) -> AppcastItem? {
        feed.filter { item in
            item.build > installedBuild
                && (item.minimumSystemVersion ?? "0").compare(macOS, options: .numeric) != .orderedDescending
        }.newest
    }

    /// What the update dialog shows: Sparkle marks the installed build's section, and the installed-version style hides
    /// it and every older one. Anything outside the sections stays.
    private func dialog(_ item: AppcastItem, installedBuild: Int) -> (versions: [String], links: [String]) {
        var versions: [String] = []
        for section in item.description.matches(of: /(?s)<section data-sparkle-version="(\d+)">\s*<h3[^>]*>([^<]+)<\/h3>/) {
            if Int(section.1) == installedBuild { break }
            versions.append(String(section.2))
        }
        return (versions, item.description.matches(of: /<a href="([^"]+)">/).map { String($0.1) })
    }

    @Test func fifteenReleasesBehindGetsTheNewestBuildAndALinkToEveryVersion() throws {
        let release = try publishTwentyReleases()
        #expect(release.feed.count == 1)

        let installedBuild = 15
        let item = try #require(offered(release.feed, installedBuild: installedBuild, macOS: "14.6"))
        #expect(item.displayVersion == "1.0.20")

        let shown = dialog(item, installedBuild: installedBuild)
        #expect(shown.versions == (11...20).reversed().map { "1.0.\($0)" })
        #expect(shown.links == [site + "/releases"])

        let skipped = (6...20).map { "1.0.\($0)" }
        let history = Dictionary(uniqueKeysWithValues: release.history.releases.map { ($0.version, $0) })
        #expect(release.history.releases.count == 20)
        for version in skipped {
            #expect(history[version]?.html.contains("Fix") == true, "\(version) has no notes in history.json")
        }
        #expect(history["1.0.6"]?.publishedAt == (try date("2026-10-06T12:00:00Z")))
    }

    @Test func oneReleaseBehindSeesOnlyWhatsNew() throws {
        let release = try publishTwentyReleases()
        let item = try #require(offered(release.feed, installedBuild: 29, macOS: "15.0"))
        #expect(dialog(item, installedBuild: 29).versions == ["1.0.20"])
    }

    /// The feed has no older items to fall back on, so a Mac below the minimum is offered nothing: Sparkle tells it the
    /// system is too old.
    @Test func aMacBelowTheMinimumIsOfferedNothing() throws {
        #expect(offered(try publishTwentyReleases().feed, installedBuild: 15, macOS: "13.7") == nil)
    }

    @Test func theFullNotesLinkIsTheReleasesPageTheSiteMustServe() throws {
        let workspace = try Workspace.locate(appRoot.path)
        #expect(ReleasePipeline(workspace: workspace).allReleasesURL == workspace.manifest.release.siteUrl + "/releases")
        let report = ReleaseChecks(workspace: workspace).run()
        #expect(report.checked.contains("releases_page"))
        #expect(!report.findings.contains { $0.rule == "releases_page" })
    }
}
