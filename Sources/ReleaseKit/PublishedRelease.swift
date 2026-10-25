import DylToolSupport
import Foundation

/// `release.json`, published beside each release's `appcast.xml` so `@dylkit/web` shows the release without parsing
/// the feed's HTML.
struct PublishedRelease: Encodable, Equatable, Sendable {
    struct Notes: Encodable, Equatable, Sendable {
        var version: String
        var html: String
    }

    var version: String
    var build: Int
    var minimumSystemVersion: String
    var appleSiliconOnly: Bool
    var publishedAt: Date?
    var download: String
    var sizeBytes: Int
    /// Newest first, versions without notes left out, styles stripped for the site's own CSS.
    var notes: [Notes]

    init(_ item: AppcastItem) throws {
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
            let html = ReleaseHistory.siteHTML(entry.body)
            return html.isEmpty ? nil : Notes(version: entry.version, html: html)
        }
    }

    /// - Blocking: writes the file.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url)
    }
}
