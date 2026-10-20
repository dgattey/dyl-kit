import DylCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads what users' updaters see right now. Network failures read as an empty feed: a first release has none.
public enum LiveFeed {
    private static let session = URLSession.bounded(requestTimeout: 120, resourceTimeout: 300)

    public static func fetch(_ url: String, timeout: TimeInterval = 20) async -> [AppcastItem] {
        guard let data = await download(url, timeout: timeout) else { return [] }
        return Appcast.items(in: data)
    }

    /// The body of a 2xx response, or nil.
    public static func download(_ url: String, timeout: TimeInterval = 60) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: timeout)),
            let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return nil }
        return data
    }
}
