import DylCore
import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private static let standard = URLSession.bounded(requestTimeout: 30, resourceTimeout: 600)
    private static let quick = URLSession.bounded(requestTimeout: 5, resourceTimeout: 10)
    private let session: URLSession

    /// `quick` gives up within seconds, for reads a command can do without.
    public init(quick: Bool = false) { session = quick ? Self.quick : Self.standard }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ToolError("\(request.url?.absoluteString ?? "the request") didn't answer over HTTP")
        }
        return (data, response)
    }
}
