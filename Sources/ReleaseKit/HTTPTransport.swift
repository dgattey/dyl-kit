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
