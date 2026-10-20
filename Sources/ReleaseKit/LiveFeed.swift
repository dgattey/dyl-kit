import DylCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads what users' updaters see right now. Network failures read as an empty feed: a first release has none.
public enum LiveFeed {
    public static func fetch(_ url: String, timeout: TimeInterval = 20) async -> [AppcastItem] {
        guard let data = await download(url, timeout: timeout) else { return [] }
        return Appcast.items(in: data)
    }

    /// The body of a 2xx response, or nil.
    public static func download(_ url: String, timeout: TimeInterval = 60) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        let session = URLSession.bounded(requestTimeout: timeout, resourceTimeout: timeout * 4)
        guard let (data, response) = try? await session.data(from: url),
            let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return nil }
        return data
    }
}
