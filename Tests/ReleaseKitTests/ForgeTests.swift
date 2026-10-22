import DylToolSupport
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import ReleaseKit

/// Answers every request from `respond` and keeps the requests in order.
actor FakeTransport: HTTPTransport {
    typealias Respond = @Sendable (URLRequest) throws -> (status: Int, body: String)

    private(set) var requests: [URLRequest] = []
    private let respond: Respond

    init(_ respond: @escaping Respond) { self.respond = respond }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try respond(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }

    var calls: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.absoluteString ?? "")" } }
}

private func item(_ version: String, build: Int) -> String {
    "<item><title>\(version)</title><sparkle:version>\(build)</sparkle:version></item>"
}

@Suite struct AppcastTests {
    @Test func parsesThePublishDateAndHardwareRequirements() throws {
        let xml = sparkleFeed(
            """
            <item><title>2.0.0</title><sparkle:version>40</sparkle:version>
            <pubDate>Tue, 20 Oct 2026 17:05:00 -0700</pubDate>
            <sparkle:hardwareRequirements>arm64, x86_64</sparkle:hardwareRequirements></item>
            """)
        let parsed = try #require(Appcast.items(in: Data(xml.utf8), source: "feed").first)
        #expect(parsed.publishedAt == (try Date("2026-10-21T00:05:00Z", strategy: .iso8601)))
        #expect(parsed.hardwareRequirements == ["arm64", "x86_64"])
    }

    /// A truncated or malformed feed must never read as a short one, and every build check needs the build. Errors
    /// name the line.
    @Test(arguments: [
        (String(sparkleFeed(item("1.0.0", build: 3) + item("1.1.0", build: 4)).dropLast(30)), "feed:1: "),
        ("<rss>\n<channel>\(item("1.0.0", build: 3))</item></channel></rss>", "feed:2: "),
        (sparkleFeed(item("1.0.0", build: 3)) + "\n<rss>", "feed:2: "),
        (sparkleFeed("<item><title>1.0.0</title></item>"), "item 1 has sparkle:version missing"),
        (sparkleFeed(item("1.0.0", build: 3) + "<item><sparkle:version>4a</sparkle:version></item>"), "item 2"),
    ])
    func aBrokenFeedThrows(_ xml: String, _ message: String) {
        do {
            _ = try Appcast.items(in: Data(xml.utf8), source: "feed")
            Issue.record("expected an error containing \(message)")
        } catch {
            #expect("\(error)".contains(message), "\(error)")
        }
    }
}

@Suite struct PublishedFeedTests {
    private let url = "https://example.com/appcast.xml"

    @Test func notFoundIsAFirstRelease() async throws {
        #expect(try await Appcast.published(url, transport: FakeTransport { _ in (404, "") }).isEmpty)
    }

    @Test func readsThePublishedItems() async throws {
        let transport = FakeTransport { _ in (200, sparkleFeed(item("1.0.0", build: 3))) }
        #expect(try await Appcast.published(url, transport: transport).map(\.build) == [3])
    }

    /// Planning from a feed that merely failed to load would reuse a shipped build and drop the notes before it.
    @Test(arguments: [
        (500, "", "answered HTTP 500"),
        (200, sparkleFeed(""), "answered HTTP 200 with no <item>"),
        (200, "<html><body>Rate limited", "(HTTP 200):"),
    ])
    func anythingButAFeedOrNotFoundThrows(_ status: Int, _ body: String, _ message: String) async {
        do {
            _ = try await Appcast.published(url, transport: FakeTransport { _ in (status, body) })
            Issue.record("expected an error containing \(message)")
        } catch {
            #expect("\(error)".contains(url) && "\(error)".contains(message), "\(error)")
        }
    }

    @Test func aNetworkErrorThrows() async {
        let offline = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: ToolError.self) { try await Appcast.published(url, transport: offline) }
    }

    /// Installs are offered the site's feed or the forge's latest, and either can be ahead.
    @Test func publishedFeedsReadsTheSiteAndTheForgesLatestStrictly() async throws {
        let workspace = try Workspace.locate(appRoot.path)
        let site = "https://dgattey.github.io/dyl-kit-sample/appcast.xml"
        let latest = "https://github.com/dgattey/dyl-kit-sample/releases/latest/download/appcast.xml"
        let both = FakeTransport { request in
            switch request.url?.absoluteString {
            case site: (200, sparkleFeed(item("1.0.0", build: 3)))
            case latest: (200, sparkleFeed(item("1.1.0", build: 5)))
            default: (404, "")
            }
        }
        #expect(try await ReleasePipeline(workspace: workspace, transport: both).publishedFeeds().map(\.build) == [3, 5])

        let forgeDown = FakeTransport { request in request.url?.absoluteString == latest ? (502, "") : (404, "") }
        await #expect(throws: ToolError.self) {
            try await ReleasePipeline(workspace: workspace, transport: forgeDown).publishedFeeds()
        }
    }
}

@Suite struct GitHubAdapterTests {
    private func github(_ transport: FakeTransport, token: String? = "t0ken") -> GitHubAdapter {
        GitHubAdapter(
            repo: "o/app", environment: token.map { ["GITHUB_TOKEN": $0] } ?? [:], transport: transport)
    }

    @Test func servesEachReleaseFromItsTag() {
        let forge = github(FakeTransport { _ in (404, "") })
        #expect(forge.downloadPrefix(tag: "v1.2.0") == "https://github.com/o/app/releases/download/v1.2.0/")
        #expect(forge.latestAppcastURL == "https://github.com/o/app/releases/latest/download/appcast.xml")
    }

    @Test func readsThePullRequestBody() async throws {
        let transport = FakeTransport { request in
            request.url?.path == "/repos/o/app/pulls/7" ? (200, #"{"body": "- [x] Minor"}"#) : (200, #"{"body": null}"#)
        }
        #expect(try await github(transport).pullRequestBody(number: 7) == "- [x] Minor")
        #expect(try await github(transport).pullRequestBody(number: 8) == "")
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    private func stagedFiles() throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dylkit-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = ["App-1.2.0.zip", "appcast.xml", "release.json"].map { directory.appending(path: $0) }
        for file in files { try Data("contents of \(file.lastPathComponent)".utf8).write(to: file) }
        return files
    }

    /// Asset `n` of release `id` has id `id * 100 + n`.
    private static func release(id: Int, tag: String, assets: [String]) -> String {
        let names = assets.enumerated().map { #"{"id": \#(id * 100 + $0.offset), "name": "\#($0.element)"}"# }
            .joined(separator: ", ")
        return #"""
            {"id": \#(id), "tag_name": "\#(tag)", "assets": [\#(names)],
             "upload_url": "https://uploads.github.com/repos/o/app/releases/\#(id)/assets{?name,label}"}
            """#
    }

    /// The tag's release, if one exists, and how GitHub answers the rest of a publish.
    private func forge(existing: [String]) -> FakeTransport {
        FakeTransport { request in
            switch (request.httpMethod, request.url?.host) {
            case ("GET"?, _): (200, "[\(existing.joined(separator: ", "))]")
            case ("POST"?, "api.github.com"?): (201, Self.release(id: 9, tag: "v1.2.0", assets: []))
            case ("POST"?, _): (201, "{}")
            case ("DELETE"?, _): (204, "")
            default: (200, Self.release(id: 9, tag: "v1.2.0", assets: []))
            }
        }
    }

    private struct Sent: Decodable, Equatable {
        var tagName: String?
        var name: String?
        var body: String?
        var draft: Bool?
        var makeLatest: String?
    }

    private func sent(_ request: URLRequest) throws -> Sent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Sent.self, from: try #require(request.httpBody))
    }

    @Test func draftsUploadsThenPublishesANewRelease() async throws {
        let transport = forge(existing: [Self.release(id: 1, tag: "v1.1.0", assets: ["App-1.1.0.zip"])])
        let files = try stagedFiles()
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }

        try await github(transport).publish(tag: "v1.2.0", title: "App 1.2.0", notes: "- New", files: files)

        let uploads = "https://uploads.github.com/repos/o/app/releases/9/assets"
        #expect(
            await transport.calls == [
                "GET https://api.github.com/repos/o/app/releases?per_page=100",
                "POST https://api.github.com/repos/o/app/releases",
                "POST \(uploads)?name=App-1.2.0.zip",
                "POST \(uploads)?name=appcast.xml",
                "POST \(uploads)?name=release.json",
                "PATCH https://api.github.com/repos/o/app/releases/9",
            ])
        let requests = await transport.requests
        #expect(try sent(requests[1]) == Sent(tagName: "v1.2.0", name: "App 1.2.0", body: "- New", draft: true))
        #expect(requests[2...4].map { $0.value(forHTTPHeaderField: "Content-Type") } == [
            "application/zip", "application/xml", "application/json",
        ])
        #expect(requests[2].httpBody == (try Data(contentsOf: files[0])))
        #expect(try sent(requests[5]) == Sent(draft: false, makeLatest: "true"))
    }

    /// A re-run rebuilds the zip, so it replaces the assets an earlier run uploaded (whole or interrupted) on the same
    /// release instead of drafting another, and leaves assets it doesn't stage alone.
    @Test func aRerunReplacesTheStagedAssetsAndKeepsTheRest() async throws {
        let existing = Self.release(id: 9, tag: "v1.2.0", assets: ["App-1.2.0.zip", "dSYMs.zip", "appcast.xml"])
        let transport = forge(existing: [existing])
        let files = try stagedFiles()
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }

        try await github(transport).publish(tag: "v1.2.0", title: "App 1.2.0", notes: "- New", files: files)

        let uploads = "https://uploads.github.com/repos/o/app/releases/9/assets"
        #expect(
            await transport.calls == [
                "GET https://api.github.com/repos/o/app/releases?per_page=100",
                "DELETE https://api.github.com/repos/o/app/releases/assets/900",
                "POST \(uploads)?name=App-1.2.0.zip",
                "DELETE https://api.github.com/repos/o/app/releases/assets/902",
                "POST \(uploads)?name=appcast.xml",
                "POST \(uploads)?name=release.json",
                "PATCH https://api.github.com/repos/o/app/releases/9",
            ])
        let requests = await transport.requests
        #expect(requests[2].httpBody == (try Data(contentsOf: files[0])))
        #expect(try sent(requests[6]) == Sent(draft: false, makeLatest: "true"))
    }

    @Test func failuresNameTheRequest() async throws {
        let rejecting = FakeTransport { _ in (422, #"{"message": "Validation Failed"}"#) }
        do {
            _ = try await github(rejecting).pullRequestBody(number: 7)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)" == "GitHub answered HTTP 422 to GET https://api.github.com/repos/o/app/pulls/7: Validation Failed")
        }
        let untouched = FakeTransport { _ in (200, "{}") }
        await #expect(throws: ToolError.self) { try await github(untouched, token: nil).pullRequestBody(number: 7) }
        #expect(await untouched.requests.isEmpty)
    }
}

@Suite struct PublishedReleaseTests {
    private func stagedItem(_ extra: String) throws -> AppcastItem {
        let description = CumulativeNotes.installedVersionStyle + #"""
            <section data-sparkle-version="12">
            <h3 style="margin: 0 0 6px 0;">1.2.0</h3>
            <ul><li style="margin-bottom: 6px;">New</li></ul>
            </section>
            <section data-sparkle-version="11" data-version="1.1.0"></section>
            <section data-sparkle-version="10">
            <h3 style="opacity: 0.75;">1.0.0</h3>
            <p>First</p>
            </section>
            """#
        let xml = sparkleFeed(
            """
            <item><title>1.2.0</title><sparkle:version>12</sparkle:version>
            <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[\(description)]]></description>
            \(extra)
            </item>
            """)
        return try #require(Appcast.items(in: Data(xml.utf8), source: "feed").first)
    }

    private func json(_ release: PublishedRelease) throws -> [String: Any] {
        let file = FileManager.default.temporaryDirectory.appending(path: "dylkit-release-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try release.write(to: file)
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    /// What `@dylkit/web` renders: each version's notes without Sparkle's styles, and every key present.
    @Test func carriesTheStagedItemForTheSite() throws {
        let release = try PublishedRelease(
            stagedItem(
                """
                <pubDate>Wed, 21 Oct 2026 09:30:00 +0000</pubDate>
                <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                <enclosure url="https://github.com/o/app/releases/download/v1.2.0/App-1.2.0.zip" length="2048"/>
                """))
        #expect(release.version == "1.2.0")
        #expect(release.build == 12)
        #expect(release.appleSiliconOnly)
        #expect(release.download == "https://github.com/o/app/releases/download/v1.2.0/App-1.2.0.zip")
        #expect(release.sizeBytes == 2048)
        #expect(
            release.notes == [
                .init(version: "1.2.0", html: "<ul><li>New</li></ul>"), .init(version: "1.0.0", html: "<p>First</p>"),
            ])
        let object = try json(release)
        #expect(object["publishedAt"] as? String == "2026-10-21T09:30:00Z")
        #expect(object["minimumSystemVersion"] as? String == "14.0")
    }

    @Test func writesMissingValuesAsNull() throws {
        let release = try PublishedRelease(stagedItem(#"<enclosure url="https://example.com/App-1.2.0.zip"/>"#))
        #expect(!release.appleSiliconOnly)
        let object = try json(release)
        #expect(object["publishedAt"] is NSNull)
        #expect(object["sizeBytes"] is NSNull)
        #expect(
            Set(object.keys) == [
                "version", "build", "minimumSystemVersion", "appleSiliconOnly", "publishedAt", "download", "sizeBytes",
                "notes",
            ])
    }

    @Test func needsAnEnclosure() throws {
        #expect(throws: ToolError.self) { try PublishedRelease(try stagedItem("")) }
    }
}
