import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub Releases: the assets attach to the release for the tag, and `releases/latest/download/` follows the newest
/// published release.
struct GitHubAdapter: ForgeAdapter {
    static let tokenVariable = "GITHUB_TOKEN"

    let repo: String
    let token: String?
    let api: String
    let transport: any HTTPTransport

    init(repo: String, environment: [String: String], transport: any HTTPTransport) {
        self.repo = repo
        token = environment[Self.tokenVariable]
        api = environment["GITHUB_API_URL"] ?? "https://api.github.com"
        self.transport = transport
    }

    func downloadPrefix(tag: String) -> String { "https://github.com/\(repo)/releases/download/\(tag)/" }

    var latestAppcastURL: String { "https://github.com/\(repo)/releases/latest/download/appcast.xml" }

    private struct Pull: Decodable {
        var body: String?
    }

    func pullRequestBody(number: Int) async throws -> String {
        let pull: Pull = try await call("GET", "/repos/\(repo)/pulls/\(number)")
        return pull.body ?? ""
    }

    private struct Release: Decodable {
        var id: Int
        var tagName: String
        var uploadUrl: String
        var assets: [Asset]
    }

    private struct Asset: Decodable {
        var id: Int
        var name: String
    }

    private struct Draft: Encodable {
        var tagName: String
        var name: String
        var body: String
        var draft = true
    }

    private struct Publication: Encodable {
        var draft = false
        var makeLatest = "true"
    }

    /// Finds the tag's release (drafts included) or drafts one, replaces its assets of the same names with the staged
    /// ones, then publishes it as the latest. A re-run rebuilds the zip with new bytes and a new edSignature, and an
    /// interrupted upload leaves a broken asset under its name, so nothing already there is kept.
    func publish(tag: String, title: String, notes: String, files: [URL]) async throws {
        let releases: [Release] = try await call("GET", "/repos/\(repo)/releases?per_page=100")
        let release: Release
        if let existing = releases.first(where: { $0.tagName == tag }) {
            release = existing
        } else {
            release = try await call("POST", "/repos/\(repo)/releases", json: Draft(tagName: tag, name: title, body: notes))
        }
        let uploads = release.uploadUrl.replacing(pattern: #"\{[^}]*\}$"#, with: "")
        for file in files {
            let name = file.lastPathComponent
            for asset in release.assets where asset.name == name {
                _ = try await send(try request("DELETE", "\(api)/repos/\(repo)/releases/assets/\(asset.id)"))
            }
            let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            var upload = try request("POST", "\(uploads)?name=\(query)")
            upload.setValue(Self.contentType(of: file), forHTTPHeaderField: "Content-Type")
            upload.httpBody = try Data(contentsOf: file)
            _ = try await send(upload)
            Log.step("uploaded \(name) to \(tag)")
        }
        let _: Release = try await call("PATCH", "/repos/\(repo)/releases/\(release.id)", json: Publication())
        Log.step("published \(tag) on github.com/\(repo)")
    }

    static func contentType(of file: URL) -> String {
        switch file.pathExtension {
        case "zip": "application/zip"
        case "xml": "application/xml"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    private func request(_ method: String, _ url: String) throws -> URLRequest {
        guard let token, !token.isEmpty else { throw ToolError("\(Self.tokenVariable) isn't set") }
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func call<Response: Decodable>(_ method: String, _ path: String, json: (any Encodable)? = nil)
        async throws -> Response
    {
        var request = try request(method, api + path)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(json)
        }
        return try Self.decoder.decode(Response.self, from: try await send(request))
    }

    private struct Failure: Decodable {
        var message: String
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data)).map { ": \($0.message)" } ?? ""
            throw ToolError(
                "GitHub answered HTTP \(response.statusCode) to \(request.httpMethod ?? "GET") "
                    + "\(request.url?.absoluteString ?? "")\(message)")
        }
        return data
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
