import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Origin has no release objects or asset hosting: the pushed tag is the release, and the assets go to the public
/// Vercel Blob store at `assets` through the `vercel` CLI. Untested; no app releases from Origin yet.
struct OriginAdapter: ForgeAdapter {
    static let tokenVariable = "ORIGIN_TOKEN"
    static let blobTokenVariable = "BLOB_READ_WRITE_TOKEN"

    let repo: String
    let assets: String
    let environment: [String: String]
    let transport: any HTTPTransport

    init(repo: String, assets: String, environment: [String: String], transport: any HTTPTransport) {
        self.repo = repo
        self.assets = assets
        self.environment = environment
        self.transport = transport
    }

    func downloadPrefix(tag: String) -> String { "\(assets)/releases/\(tag)/" }

    var latestAppcastURL: String { "\(assets)/appcast.xml" }

    private struct Pull: Decodable {
        var body: String?
    }

    func pullRequestBody(number: Int) async throws -> String {
        let url = "https://api.cursor.com/v1/origin/repos/\(repo)/pulls/\(number)"
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        var request = URLRequest(url: parsed)
        request.setValue("Bearer \(try token(Self.tokenVariable))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ToolError("Origin answered HTTP \(response.statusCode) to GET \(url)")
        }
        return try JSONDecoder().decode(Pull.self, from: data).body ?? ""
    }

    /// The zip first, under its tag, so the feed and `release.json` at the store root never name a missing archive.
    /// The `vercel` CLI reads `BLOB_READ_WRITE_TOKEN` itself; it's checked here so a missing one fails before any upload.
    func publish(tag: String, title: String, notes: String, assets: ReleaseAssets) async throws {
        _ = try token(Self.blobTokenVariable)
        try put(assets.zip, at: "releases/\(tag)/\(assets.zip.lastPathComponent)", maxAge: 31_536_000)
        try put(assets.appcast, at: "appcast.xml", maxAge: 60)
        try put(assets.releaseJSON, at: "release.json", maxAge: 60)
        Log.step("published \(tag) to \(self.assets)")
    }

    /// - Blocking: runs the `vercel` CLI.
    private func put(_ file: URL, at pathname: String, maxAge: Int) throws {
        try Shell.run([
            "vercel", "blob", "put", file.path, "--pathname", pathname, "--access", "public", "--allow-overwrite",
            "--cache-control-max-age", String(maxAge),
        ])
    }

    private func token(_ variable: String) throws -> String {
        guard let token = environment[variable], !token.isEmpty else { throw ToolError("\(variable) isn't set") }
        return token
    }
}
