import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one thing release-kit asks the forge for: a merged PR's body. Releases run on GitHub Actions, which names the
/// repo in `GITHUB_REPOSITORY`; the workflow passes `GITHUB_TOKEN`.
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

    private struct Failure: Decodable {
        var message: String
    }

    func pullRequestBody(number: Int) async throws -> String {
        let url = "\(api)/repos/\(repo)/pulls/\(number)"
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
        return try JSONDecoder().decode(Pull.self, from: data).body ?? ""
    }
}
