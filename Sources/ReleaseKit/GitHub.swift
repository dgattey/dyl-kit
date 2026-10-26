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
            throw ToolError("\(Self.tokenVariable) isn't set; set it, or sign in with `gh auth login`")
        }
        self.repo = repo
        self.token = token
        api = environment["GITHUB_API_URL"] ?? "https://api.github.com"
        self.transport = transport
    }

    /// GitHub Actions sets the repo and token. Run locally, `environment` lacks them, so the repo comes from `root`'s
    /// `origin` remote and the token from `gh auth token`.
    ///
    /// - Blocking: runs git and gh.
    static func filling(_ environment: [String: String], from root: URL) -> [String: String] {
        var environment = environment
        if environment["GITHUB_REPOSITORY", default: ""].isEmpty,
            let remote = try? Shell.capture(["git", "remote", "get-url", "origin"], cwd: root, allowFailure: true),
            let repo = repository(fromRemote: remote)
        {
            environment["GITHUB_REPOSITORY"] = repo
        }
        if environment[tokenVariable, default: ""].isEmpty, Shell.which("gh") != nil,
            let token = try? Shell.capture(["gh", "auth", "token"], cwd: root, allowFailure: true), !token.isEmpty
        {
            environment[tokenVariable] = token
        }
        return environment
    }

    /// `owner/name` from a github.com remote URL, HTTPS or SSH, with or without `.git`.
    static func repository(fromRemote url: String) -> String? {
        let pattern = #/
            (?: https?://(?:[^@/]+@)?github\.com/ | (?:ssh://)?git@github\.com[:/] )
            ([^/\s]+/[^/\s]+?) (?:\.git)? /?
            /#
        return url.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: pattern).map { String($0.1) }
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

    private struct Repository: Decodable {
        var defaultBranch: String
    }

    private struct Rule: Decodable {
        struct Parameters: Decodable {
            var requiredStatusChecks: [RequiredCheck]?
        }
        var type: String
        var parameters: Parameters?
    }

    func defaultBranch() async throws -> String {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Repository.self, from: try await get("/repos/\(repo)")).defaultBranch
    }

    /// The status checks every active ruleset on `branch` requires. Classic branch protection isn't readable with
    /// the default Actions token, so it isn't included.
    func requiredChecks(branch: String) async throws -> [RequiredCheck] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return try decoder.decode([Rule].self, from: try await get("/repos/\(repo)/rules/branches/\(escaped)"))
            .filter { $0.type == "required_status_checks" }.flatMap { $0.parameters?.requiredStatusChecks ?? [] }
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
