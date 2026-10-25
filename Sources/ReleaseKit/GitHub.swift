import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What release-kit asks the forge for: a merged PR's body, and the repo's releases when `release-kit history` backfills
/// `history.json`. Releases run on GitHub Actions, which names the repo in `GITHUB_REPOSITORY`; the workflow passes
/// `GITHUB_TOKEN`.
struct GitHub: Sendable {
    static let tokenVariable = "GITHUB_TOKEN"

    let repo: String
    let token: String
    let api: String
    let transport: any HTTPTransport

    init(environment: [String: String], transport: any HTTPTransport) throws {
        guard let repo = environment["GITHUB_REPOSITORY"], !repo.isEmpty else {
            throw ToolError("GITHUB_REPOSITORY isn't set")
        }
        guard let token = environment[Self.tokenVariable], !token.isEmpty else {
            throw ToolError("\(Self.tokenVariable) isn't set")
        }
        self.repo = repo
        self.token = token
        api = environment["GITHUB_API_URL"] ?? "https://api.github.com"
        self.transport = transport
    }

    private struct Pull: Decodable {
        var body: String?
    }

    struct Release: Decodable, Equatable, Sendable {
        var tagName: String
        var body: String?
        var publishedAt: Date?
        var draft: Bool
        var prerelease: Bool
    }

    private struct Failure: Decodable {
        var message: String
    }

    func pullRequestBody(number: Int) async throws -> String {
        try JSONDecoder().decode(Pull.self, from: try await get("/repos/\(repo)/pulls/\(number)")).body ?? ""
    }

    /// Every release, newest first, a page of 100 at a time.
    func releases() async throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        var all: [Release] = []
        for page in 1... {
            let batch = try decoder.decode(
                [Release].self, from: try await get("/repos/\(repo)/releases?per_page=100&page=\(page)"))
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    private func get(_ path: String) async throws -> Data {
        let url = api + path
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        var request = URLRequest(url: parsed)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data)).map { ": \($0.message)" } ?? ""
            throw ToolError("GitHub answered HTTP \(response.statusCode) to GET \(url)\(message)")
        }
        return data
    }
}
