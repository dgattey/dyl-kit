import DylCore
import DylToolSupport
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One `<item>` of a Sparkle appcast.
public struct AppcastItem: Equatable, Sendable {
    public var title = ""
    public var shortVersion: String?
    /// `sparkle:version`, the build number Sparkle compares.
    public var build: String?
    public var minimumSystemVersion: String?
    public var description = ""
    public var enclosureURL: String?
    public var enclosureLength: Int?
    public var edSignature: String?

    /// `shortVersionString`, falling back to the title like Sparkle does.
    public var displayVersion: String { shortVersion ?? title }
}

public enum Appcast {
    /// The items in document order; Sparkle feeds list the newest first.
    public static func items(in data: Data) -> [AppcastItem] {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    /// - Blocking: reads the file.
    public static func items(at url: URL) -> [AppcastItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return items(in: data)
    }

    private static let session = URLSession.bounded(requestTimeout: 20)
    private static let downloads = URLSession.bounded(requestTimeout: 120)

    /// `url`'s body after redirects, or an error naming what failed. For `check --live`, where a missing feed or
    /// enclosure is a finding rather than a first release.
    public static func download(_ url: String) async throws -> Data {
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        let (data, response) = try await downloads.data(from: parsed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ToolError("\(url) answered HTTP \(status)") }
        return data
    }

    /// What users' updaters see right now. A failed fetch reads as an empty feed: a first release has none.
    public static func fetch(_ url: String) async -> [AppcastItem] {
        guard let url = URL(string: url),
            let (data, response) = try? await session.data(from: url),
            let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return [] }
        return items(in: data)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            if elementName == "item" { current = AppcastItem() }
            if elementName == "enclosure", current != nil {
                current?.enclosureURL = attributeDict["url"]
                current?.enclosureLength = attributeDict["length"].flatMap { Int($0) }
                current?.edSignature = attributeDict["sparkle:edSignature"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            defer { text = "" }
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "title": current?.title = value
            case "sparkle:shortVersionString": current?.shortVersion = value
            case "sparkle:version": current?.build = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "description": current?.description = text
            case "item":
                if let item = current { items.append(item) }
                current = nil
            default: break
            }
        }
    }
}
