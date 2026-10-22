import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The public Vercel Blob store every release's files go to, whichever forge tags it. A release's files live under
/// `releases/<tag>/`, and `appcast.xml` and `release.json` at the store root describe the newest release.
struct BlobStore: Sendable {
    static let tokenVariable = "BLOB_READ_WRITE_TOKEN"

    let token: String
    let transport: any HTTPTransport

    init(environment: [String: String], transport: any HTTPTransport) throws {
        guard let token = environment[Self.tokenVariable], !token.isEmpty else {
            throw ToolError("\(Self.tokenVariable) isn't set")
        }
        self.token = token
        self.transport = transport
    }

    /// Uploads `files` under `releases/<tag>/`, then `latest` to the store root, so the root never names a file that
    /// isn't up yet. Returns each file's public URL, in upload order. With `assets`, the first upload that lands in
    /// another store stops it before the root, where it would replace another app's latest release.
    func publish(tag: String, files: [URL], latest: [URL], assets: String?) async throws -> [String] {
        var urls: [String] = []
        let uploads = files.map { ($0, "releases/\(tag)/\($0.lastPathComponent)") }
            + latest.map { ($0, $0.lastPathComponent) }
        for (file, pathname) in uploads {
            let url = try await put(file, at: pathname)
            if let assets, !url.lowercased().hasPrefix(assets.lowercased() + "/") {
                throw ToolError(
                    "uploaded \(url), outside `release.assets` (\(assets)): \(Self.tokenVariable) belongs to "
                        + "another store")
            }
            urls.append(url)
        }
        return urls
    }

    private struct Blob: Decodable {
        var url: String
    }

    private struct Failure: Decodable {
        struct Detail: Decodable {
            var message: String
        }

        var error: Detail
    }

    /// Overwrites, because a re-run replaces the zip with new bytes and a new edSignature. For the same reason nothing
    /// is cached for more than a minute.
    private func put(_ file: URL, at pathname: String) async throws -> String {
        var components = URLComponents(string: "https://vercel.com/api/blob/")
        components?.queryItems = [URLQueryItem(name: "pathname", value: pathname)]
        guard let url = components?.url else { throw ToolError("\(pathname) isn't a Blob pathname") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (field, value) in [
            ("Authorization", "Bearer \(token)"), ("x-api-version", "13"), ("x-vercel-blob-access", "public"),
            ("x-content-type", Self.contentType(of: file)), ("x-allow-overwrite", "1"), ("x-add-random-suffix", "0"),
            ("x-cache-control-max-age", "60"),
        ] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Data(contentsOf: file)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data)).map { ": \($0.error.message)" } ?? ""
            throw ToolError("Vercel Blob answered HTTP \(response.statusCode) to PUT \(pathname)\(message)")
        }
        let blob = try JSONDecoder().decode(Blob.self, from: data)
        Log.step("uploaded \(blob.url)")
        return blob.url
    }

    static func contentType(of file: URL) -> String {
        switch file.pathExtension {
        case "zip": "application/zip"
        case "xml": "application/xml"
        case "json": "application/json"
        case "tgz": "application/gzip"
        default: "application/octet-stream"
        }
    }
}
