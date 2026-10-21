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
    public var sizeBytes: Int?
    /// Newest first, versions without notes left out, styles stripped for the site's own CSS.
    public var notes: [Notes]

    public init(_ item: AppcastItem) throws {
        guard let minimumSystemVersion = item.minimumSystemVersion, let download = item.enclosureURL else {
            throw ToolError(
                "the staged item \(item.displayVersion) needs sparkle:minimumSystemVersion and an enclosure for "
                    + "release.json")
        }
        version = item.displayVersion
        build = item.build
        self.minimumSystemVersion = minimumSystemVersion
        appleSiliconOnly = item.hardwareRequirements.contains("arm64")
        publishedAt = item.publishedAt
        self.download = download
        sizeBytes = item.enclosureLength
        notes = CumulativeNotes.sections(item).compactMap { entry in
            let html = entry.body
                .replacing(pattern: #"(?is)<style\b[^>]*>.*?</style>"#, with: "")
                .replacing(pattern: #"(?i)\s+style\s*=\s*"[^"]*""#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return html.isEmpty ? nil : Notes(version: entry.version, html: html)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, build, minimumSystemVersion, appleSiliconOnly, publishedAt, download, sizeBytes, notes
    }

    /// Absent values are written as `null`, which the site's type spells out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(build, forKey: .build)
        try container.encode(minimumSystemVersion, forKey: .minimumSystemVersion)
        try container.encode(appleSiliconOnly, forKey: .appleSiliconOnly)
        try container.encode(publishedAt?.formatted(.iso8601), forKey: .publishedAt)
        try container.encode(download, forKey: .download)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(notes, forKey: .notes)
    }

    /// - Blocking: writes the file.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url)
    }
}
