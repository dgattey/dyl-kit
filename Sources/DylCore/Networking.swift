import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif

extension URLSession {
    /// The app-wide bounded session. Give a request a tighter deadline with `URLRequest.timeoutInterval`.
    public static let boundedShared = bounded()

    /// A session that fails fast when a host is offline or stalls: it never waits for connectivity, and requests and
    /// resources have bounded timeouts. Pass `cache` for image or asset loads that should reuse responses. Each session
    /// has its own connection pool, so build one per app or service in a `static let` (dyl-lint `session_alloc`).
    public static func bounded(
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 60,
        cache: URLCache? = nil
    ) -> URLSession {
        let configuration = URLSessionConfiguration.default
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = cache
        configuration.requestCachePolicy = cache == nil ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }
}

extension JSONDecoder {
    /// Decodes `type`, or logs the `DecodingError` and returns nil, so schema drift shows up in the log instead of
    /// vanishing as a silent nil.
    public func decodeOrLog<T: Decodable>(_ type: T.Type, from data: Data, context: String = #function) -> T? {
        do {
            return try decode(type, from: data)
        } catch {
            DecodeLog.report("\(context): \(T.self) failed to decode: \(error)")
            return nil
        }
    }
}

enum DecodeLog {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DylKit", category: "decode")
    #endif

    static func report(_ message: String) {
        #if canImport(OSLog)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data((message + "\n").utf8))
        #endif
    }
}
