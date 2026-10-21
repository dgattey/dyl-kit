import DylCore
import DylManifest
import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a release's tag, assets and PR bodies live. Every forge call release-kit makes goes through one of these, so
/// workflows and app scripts never talk to a forge.
public protocol ForgeAdapter: Sendable {
    /// The URL the release's zip is served from once `publish` uploads it, ending in `/`.
    func downloadPrefix(tag: String) -> String
    /// The newest published release's `appcast.xml`, which moves to each release as it publishes.
    var latestAppcastURL: String { get }
    func pullRequestBody(number: Int) async throws -> String
    /// Hosts `assets` as the release `tag`, which `publish` has already pushed. Safe to repeat.
    func publish(tag: String, title: String, notes: String, assets: ReleaseAssets) async throws
}

public struct ReleaseAssets: Sendable {
    public var zip: URL
    public var appcast: URL
    public var releaseJSON: URL

    public init(zip: URL, appcast: URL, releaseJSON: URL) {
        self.zip = zip
        self.appcast = appcast
        self.releaseJSON = releaseJSON
    }

    var all: [URL] { [zip, appcast, releaseJSON] }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private static let session = URLSession.bounded(requestTimeout: 30, resourceTimeout: 600)

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ToolError("\(request.url?.absoluteString ?? "the request") didn't answer over HTTP")
        }
        return (data, response)
    }
}

public func forgeAdapter(
    for forge: DylAppManifest.Forge, environment: [String: String], transport: any HTTPTransport
) -> any ForgeAdapter {
    switch forge {
    case .github(let repo):
        GitHubAdapter(repo: repo, environment: environment, transport: transport)
    case .origin(let repo, let assets):
        OriginAdapter(repo: repo, assets: assets, environment: environment, transport: transport)
    }
}
