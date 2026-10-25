import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `history.json`: every release's notes, newest first and uncapped, published beside `release.json` so `@dylkit/web`
/// can show releases older than the ten the appcast carries. Each release appends to the published file, so a re-run
/// converges on the same history; `release-kit history` backfills it from older appcasts and GitHub Releases.
public struct ReleaseHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var version: String
        public var build: Int?
        public var publishedAt: Date?
        /// Empty for a version that shipped without notes. Styles are stripped for the site's own CSS.
        public var html: String

        public init(version: String, build: Int? = nil, publishedAt: Date? = nil, html: String = "") {
            self.version = version
            self.build = build
            self.publishedAt = publishedAt
            self.html = html
        }
    }

    public var releases: [Entry]

    public init(releases: [Entry] = []) {
        self.releases = Self.sorted(releases)
    }

    /// Adds the versions `entries` have that this history lacks, and fills in the build, date and notes of versions it
    /// has without them. What's already here wins, so an older source never overwrites a newer one.
    public func filling(_ entries: [Entry]) -> ReleaseHistory {
        var byVersion = Dictionary(releases.map { ($0.version, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries where !entry.version.isEmpty {
            guard var existing = byVersion[entry.version] else {
                byVersion[entry.version] = entry
                continue
            }
            existing.build = existing.build ?? entry.build
            existing.publishedAt = existing.publishedAt ?? entry.publishedAt
            if existing.html.isEmpty { existing.html = entry.html }
            byVersion[entry.version] = existing
        }
        return ReleaseHistory(releases: Array(byVersion.values))
    }

    /// `entry` in place of any entry with its version.
    public func replacing(_ entry: Entry) -> ReleaseHistory {
        ReleaseHistory(releases: releases.filter { $0.version != entry.version } + [entry])
    }

    /// The history after publishing `staged`: the published history, the staged release in place of any earlier run
    /// of it, then gaps filled from the staged item's earlier notes and the published feeds.
    static func next(published: ReleaseHistory, staged: AppcastItem, feeds: [AppcastItem]) -> ReleaseHistory {
        let stagedEntries = entries(from: staged)
        let version = CumulativeNotes.normalize(staged.displayVersion)
        var history = published
        if let release = stagedEntries.first(where: { $0.version == version }) { history = history.replacing(release) }
        return history.filling(stagedEntries + feeds.flatMap(entries(from:)))
    }

    /// Every version an appcast item describes: the item itself, dated and with its build even when it has no notes,
    /// then the earlier versions its cumulative notes carry.
    static func entries(from item: AppcastItem) -> [Entry] {
        let version = CumulativeNotes.normalize(item.displayVersion)
        var entries = CumulativeNotes.sections(item).map { section in
            Entry(version: section.version, build: section.build.flatMap { Int($0) }, html: siteHTML(section.body))
        }
        if let index = entries.firstIndex(where: { $0.version == version }) {
            entries[index].build = item.build
            entries[index].publishedAt = item.publishedAt
        } else if !version.isEmpty {
            entries.insert(Entry(version: version, build: item.build, publishedAt: item.publishedAt), at: 0)
        }
        return entries
    }

    /// Published GitHub Releases with a version tag, their Markdown bodies formatted like the appcast's notes.
    static func entries(from releases: [GitHub.Release], formatter: NotesFormatter = NotesFormatter()) -> [Entry] {
        releases.compactMap { release in
            let version = CumulativeNotes.normalize(release.tagName)
            guard !release.draft, !release.prerelease, version.matches(pattern: #"^\d+\.\d+\.\d+$"#) else { return nil }
            let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Entry(
                version: version, publishedAt: release.publishedAt,
                html: body.isEmpty ? "" : siteHTML(formatter.html(body, version: version)))
        }
    }

    /// Notes as the site renders them: no styles, and no "Release v1.2.3" placeholder standing in for missing notes.
    static func siteHTML(_ body: String) -> String {
        let html = body
            .replacing(pattern: #"(?is)<style\b[^>]*>.*?</style>"#, with: "")
            .replacing(pattern: #"(?i)\s+style\s*=\s*"[^"]*""#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return html.matches(pattern: #"(?i)^(?:<p\b[^>]*>)?\s*Release\s+v?[\d.]+\s*(?:</p>)?$"#) ? "" : html
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            CumulativeNotes.versionKey($1.version).lexicographicallyPrecedes(CumulativeNotes.versionKey($0.version))
        }
    }

    // MARK: Files

    /// The published history. Only a 404 reads as empty, since nothing has been published there yet; anything else
    /// throws, because appending to a history that merely failed to load would drop every release before it.
    static func published(_ url: String, transport: any HTTPTransport) async throws -> ReleaseHistory {
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(URLRequest(url: parsed))
        } catch {
            throw ToolError("can't read the published history \(url): \(error.localizedDescription)")
        }
        switch response.statusCode {
        case 404: return ReleaseHistory()
        case 200..<300:
            do {
                return try decoder.decode(ReleaseHistory.self, from: data)
            } catch {
                throw ToolError("the published history \(url) doesn't parse: \(error)")
            }
        default: throw ToolError("the published history \(url) answered HTTP \(response.statusCode)")
        }
    }

    /// - Blocking: reads the file.
    static func read(_ url: URL) throws -> ReleaseHistory {
        try decoder.decode(ReleaseHistory.self, from: Data(contentsOf: url))
    }

    /// - Blocking: writes the file.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(releases: try container.decode([Entry].self, forKey: .releases))
    }
}
