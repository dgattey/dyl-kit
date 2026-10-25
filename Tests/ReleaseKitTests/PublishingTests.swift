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

    @Test func notFoundIsNothingPublished() async throws {
        #expect(try await Appcast.published(url, transport: FakeTransport { _ in (404, "") }) == nil)
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

    /// Installs are offered the site's feed or the Blob store's latest, and either can be ahead.
    @Test func publishedFeedsReadsTheSiteAndTheStoresLatestStrictly() async throws {
        let workspace = try Workspace.locate(appRoot.path)
        let both = FakeTransport { request in
            switch request.url?.absoluteString {
            case Self.site: (200, sparkleFeed(item("1.0.0", build: 3)))
            case Self.latest: (200, sparkleFeed(item("1.1.0", build: 5)))
            default: (404, "")
            }
        }
        #expect(try await ReleasePipeline(workspace: workspace, transport: both).publishedFeeds().map(\.build) == [3, 5])

        let storeDown = FakeTransport { request in request.url?.absoluteString == Self.latest ? (502, "") : (404, "") }
        await #expect(throws: ToolError.self) {
            try await ReleasePipeline(workspace: workspace, transport: storeDown).publishedFeeds()
        }
    }

    /// Agent checkouts fetch only their branch, so their tags stop at an old release (scone-os showed 1.1.0 with 1.2.0
    /// out). Dev builds take the feeds' version, and the tags when the feeds can't be read.
    @Test func shippedVersionReadsTheFeedsThenTheTags() async throws {
        let root = try Self.minorMerge(after: "v1.1.0")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.locate(root.path)
        func shippedVersion(_ transport: FakeTransport) async throws -> String {
            try await ReleasePipeline(workspace: workspace, transport: transport).shippedVersion().description
        }

        #expect(try await shippedVersion(FakeTransport { _ in (200, sparkleFeed(item("1.2.0", build: 48))) }) == "1.2.0")
        #expect(try await shippedVersion(FakeTransport { _ in throw URLError(.notConnectedToInternet) }) == "1.1.0")
    }

    /// Sudylko #5: tagged v1.0.0 with nothing published, then a Minor merge. Before the site's first deploy its host
    /// doesn't resolve; once deployed, its route answers 503 until the store has a feed. The store's 404 says nothing
    /// has shipped either way, so the tags plan 1.1.0.
    @Test(arguments: [nil, 503] as [Int?])
    func aSiteWithoutAFeedPlansFromTheTagsWhileTheStoreHasNone(_ site: Int?) async throws {
        let plan = try await Self.version(site: Self.answer(site), store: Self.answer(404))
        #expect(plan.version == "1.1.0")
        #expect(plan.build == 2)
    }

    /// An app with releases has a feed in the store, so a site that can't serve it is an outage, not a first release.
    @Test(arguments: [500, 502, 503, nil] as [Int?])
    func aSiteOutageFailsOnceTheStoreHasAFeed(_ site: Int?) async throws {
        let store = Self.answer(200, sparkleFeed(item("1.2.0", build: 40)))
        let error = await #expect(throws: ToolError.self) {
            try await Self.version(site: Self.answer(site), store: store)
        }
        #expect(error?.message.contains(Self.site) == true)
    }

    /// Only the store's own 404 says nothing has shipped, so any other answer from it fails, whatever the site says.
    @Test(arguments: [500, 503, nil] as [Int?])
    func aStoreOutageFails(_ store: Int?) async throws {
        let error = await #expect(throws: ToolError.self) {
            try await Self.version(site: Self.answer(503), store: Self.answer(store))
        }
        #expect(error?.message.contains(Self.latest) == true)
    }

    /// A published feed outranks the tags and raises the build, and the site's feed counts even while the store's
    /// latest reads 404.
    @Test func anExistingFeedPlansPastIt() async throws {
        let feed = Self.answer(200, sparkleFeed(item("1.2.0", build: 40)))
        let plan = try await Self.version(site: feed, store: feed)
        #expect(plan.version == "1.3.0")
        #expect(plan.build == 41)
        #expect(try await Self.version(site: feed, store: Self.answer(404)) == plan)
    }

    private static let site = "https://dgattey.github.io/dyl-kit-sample/appcast.xml"
    private static let latest = "https://dylkitsample.public.blob.vercel-storage.com/appcast.xml"

    private typealias Answer = @Sendable () throws -> (status: Int, body: String)

    /// `status` with `body`, or for nil, a host that doesn't resolve.
    private static func answer(_ status: Int?, _ body: String = "") -> Answer {
        guard let status else { return { throw URLError(.cannotFindHost) } }
        return { (status, body) }
    }

    /// `release-kit version` on SampleApp tagged v1.0.0 then merged as Minor, with the feeds answering as given.
    private static func version(site: @escaping Answer, store: @escaping Answer) async throws -> ReleasePipeline.State {
        let root = try minorMerge(after: "v1.0.0")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport { request in
            switch request.url?.absoluteString {
            case Self.site: try site()
            case Self.latest: try store()
            default: (404, "")
            }
        }
        return try await ReleasePipeline(workspace: try Workspace.locate(root.path), transport: transport)
            .version(explicitBump: nil, pullRequest: nil)
    }

    /// A scratch checkout of SampleApp's manifest: one commit tagged `tag`, then a Minor merge. Delete it when done.
    private static func minorMerge(after tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "dylkit-feeds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: appRoot.appending(path: "DylApp.toml"), to: root.appending(path: "DylApp.toml"))
        let commit = ["-c", "user.name=t", "-c", "user.email=t@invalid", "commit", "-q", "--allow-empty", "-m"]
        let merge = "Add a thing (#2)\n\n# Release notes\n\n- A thing.\n\n# Release info\n\n- [ ] Major\n- [x] Minor\n"
        for arguments in [["init", "--quiet"], commit + ["1"], ["tag", tag], commit + [merge]] {
            _ = try Shell.capture(["git"] + arguments, cwd: root)
        }
        return root
    }
}

@Suite struct GitHubTests {
    private let actions = ["GITHUB_REPOSITORY": "o/app", "GITHUB_TOKEN": "t0ken"]

    @Test func readsThePullRequestBody() async throws {
        let transport = FakeTransport { request in
            request.url?.path == "/repos/o/app/pulls/7" ? (200, #"{"body": "- [x] Minor"}"#) : (200, #"{"body": null}"#)
        }
        let github = try GitHub(environment: actions, transport: transport)
        #expect(try await github.pullRequestBody(number: 7) == "- [x] Minor")
        #expect(try await github.pullRequestBody(number: 8) == "")
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
    }

    @Test func failuresNameTheRequest() async throws {
        let rejecting = FakeTransport { _ in (422, #"{"message": "Validation Failed"}"#) }
        do {
            _ = try await GitHub(environment: actions, transport: rejecting).pullRequestBody(number: 7)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)" == "GitHub answered HTTP 422 to GET https://api.github.com/repos/o/app/pulls/7: Validation Failed")
        }
        for missing in ["GITHUB_REPOSITORY", "GITHUB_TOKEN"] {
            #expect(throws: ToolError.self) {
                try GitHub(environment: actions.filter { $0.key != missing }, transport: rejecting)
            }
        }
    }
}

@Suite struct BlobStoreTests {
    private let store = "https://abc123.public.blob.vercel-storage.com"

    private func stagedFiles() throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dylkit-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = ["App-1.2.0.zip", "appcast.xml", "release.json"].map { directory.appending(path: $0) }
        for file in files { try Data("contents of \(file.lastPathComponent)".utf8).write(to: file) }
        return files
    }

    /// Answers each upload the way Vercel Blob does, from the store `url`.
    private func blob(_ url: String) -> FakeTransport {
        FakeTransport { request in
            let pathname = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "pathname" }?.value ?? ""
            return (200, #"{"url": "\#(url)/\#(pathname)", "pathname": "\#(pathname)"}"#)
        }
    }

    @Test func uploadsTheReleaseThenTheLatestFiles() async throws {
        let files = try stagedFiles()
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        let transport = blob(store)

        let icon = files[0].deletingLastPathComponent().appending(path: "icon.png")
        try Data("contents of icon.png".utf8).write(to: icon)
        let urls = try await BlobStore(environment: ["BLOB_READ_WRITE_TOKEN": "t0ken"], transport: transport)
            .publish(tag: "v1.2.0", files: [files[0]], icons: [icon], latest: Array(files[1...]), assets: store)

        let api = "https://vercel.com/api/blob/?pathname="
        #expect(
            await transport.calls == [
                "PUT \(api)releases/v1.2.0/App-1.2.0.zip", "PUT \(api)icons/icon.png", "PUT \(api)appcast.xml",
                "PUT \(api)release.json",
            ])
        #expect(
            urls == [
                "\(store)/releases/v1.2.0/App-1.2.0.zip", "\(store)/icons/icon.png", "\(store)/appcast.xml",
                "\(store)/release.json",
            ])
        let zip = try #require(await transport.requests.first)
        #expect(zip.httpBody == (try Data(contentsOf: files[0])))
        #expect(zip.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
        #expect(zip.value(forHTTPHeaderField: "x-vercel-blob-access") == "public")
        #expect(zip.value(forHTTPHeaderField: "x-content-type") == "application/zip")
        #expect(zip.value(forHTTPHeaderField: "x-allow-overwrite") == "1")
        #expect(zip.value(forHTTPHeaderField: "x-add-random-suffix") == "0")
        let iconRequest = try #require(await transport.requests.dropFirst().first)
        #expect(iconRequest.value(forHTTPHeaderField: "x-content-type") == "image/png")
    }

    /// Saga's token in Photos' release would otherwise replace Saga's latest feed with Photos'.
    @Test func aTokenForAnotherStoreStopsBeforeTheLatestFiles() async throws {
        let files = try stagedFiles()
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        let transport = blob("https://other.public.blob.vercel-storage.com")
        let blobStore = try BlobStore(environment: ["BLOB_READ_WRITE_TOKEN": "t0ken"], transport: transport)

        await #expect {
            try await blobStore.publish(tag: "v1.2.0", files: [files[0]], latest: Array(files[1...]), assets: store)
        } throws: { "\($0)".contains("belongs to another store") }
        #expect(await transport.calls.count == 1)
    }

    @Test func failuresNameTheUpload() async throws {
        let files = try stagedFiles()
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        let rejecting = FakeTransport { _ in (404, #"{"error": {"code": "store_not_found", "message": "Store not found"}}"#) }
        do {
            _ = try await BlobStore(environment: ["BLOB_READ_WRITE_TOKEN": "t0ken"], transport: rejecting)
                .publish(tag: "v1.2.0", files: [files[0]], latest: [], assets: nil)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)" == "Vercel Blob answered HTTP 404 to PUT releases/v1.2.0/App-1.2.0.zip: Store not found")
        }
        #expect(throws: ToolError.self) { try BlobStore(environment: [:], transport: rejecting) }
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

    /// What `@dylkit/web` renders: each version's notes without Sparkle's styles.
    @Test func carriesTheStagedItemForTheSite() throws {
        let release = try PublishedRelease(
            stagedItem(
                """
                <pubDate>Wed, 21 Oct 2026 09:30:00 +0000</pubDate>
                <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                <enclosure url="https://abc123.public.blob.vercel-storage.com/releases/v1.2.0/App-1.2.0.zip" length="2048"/>
                """))
        #expect(release.version == "1.2.0")
        #expect(release.build == 12)
        #expect(release.appleSiliconOnly)
        #expect(release.download == "https://abc123.public.blob.vercel-storage.com/releases/v1.2.0/App-1.2.0.zip")
        #expect(release.sizeBytes == 2048)
        #expect(
            release.notes == [
                .init(version: "1.2.0", html: "<ul><li>New</li></ul>"), .init(version: "1.0.0", html: "<p>First</p>"),
            ])
        let object = try json(release)
        #expect(object["publishedAt"] as? String == "2026-10-21T09:30:00Z")
        #expect(object["minimumSystemVersion"] as? String == "14.0")
    }

    @Test func needsAnEnclosureWithALength() throws {
        #expect(throws: ToolError.self) { try PublishedRelease(try stagedItem("")) }
        #expect(throws: ToolError.self) {
            try PublishedRelease(try stagedItem(#"<enclosure url="https://example.com/App-1.2.0.zip"/>"#))
        }
    }
}
