import DylToolSupport
import Foundation

/// `release.json`, published beside each release's `appcast.xml` so `@dylkit/web` shows the release without parsing
/// the feed's HTML.
public struct PublishedRelease: Encodable, Equatable, Sendable {
    public struct Notes: Encodable, Equatable, Sendable {
        public var version: String
        public var html: String
    }

    public var version: String
    public var build: Int
    public var minimumSystemVersion: String
    public var appleSiliconOnly: Bool
    public var publishedAt: Date?
    public var download: String
    public var sizeBytes: Int
    /// Newest first, versions without notes left out, styles stripped for the site's own CSS.
    public var notes: [Notes]

    public init(_ item: AppcastItem) throws {
        guard let minimumSystemVersion = item.minimumSystemVersion, let download = item.enclosureURL,
            let sizeBytes = item.enclosureLength
        else {
            throw ToolError(
                "the staged item \(item.displayVersion) needs sparkle:minimumSystemVersion and an enclosure with a "
                    + "length for release.json")
        }
        version = item.displayVersion
        build = item.build
        self.minimumSystemVersion = minimumSystemVersion
        appleSiliconOnly = item.hardwareRequirements.contains("arm64")
        publishedAt = item.publishedAt
        self.download = download
        self.sizeBytes = sizeBytes
        notes = CumulativeNotes.sections(item).compactMap { entry in
            let html = entry.body
                .replacing(pattern: #"(?is)<style\b[^>]*>.*?</style>"#, with: "")
                .replacing(pattern: #"(?i)\s+style\s*=\s*"[^"]*""#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return html.isEmpty ? nil : Notes(version: entry.version, html: html)
        }
    }

    /// - Blocking: writes the file.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url)
    }
}
