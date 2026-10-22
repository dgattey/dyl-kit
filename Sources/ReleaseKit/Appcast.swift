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
    public var build: Int
    public var minimumSystemVersion: String?
    /// `sparkle:hardwareRequirements`, such as `arm64`.
    public var hardwareRequirements: [String] = []
    public var publishedAt: Date?
    public var description = ""
    public var enclosureURL: String?
    public var enclosureLength: Int?
    public var edSignature: String?

    /// `shortVersionString`, falling back to the title like Sparkle does.
    public var displayVersion: String { shortVersion ?? title }

    public init(build: Int) { self.build = build }
}

extension [AppcastItem] {
    /// The item with the highest `sparkle:version`, the one Sparkle offers.
    public var newest: AppcastItem? { self.max { $0.build < $1.build } }
}

public enum Appcast {
    /// The items in document order; Sparkle feeds list the newest first. Throws, naming `source` and the line, when
    /// the XML doesn't parse or an item has no integer `sparkle:version`: a truncated feed must never read as a short
    /// one, and every build check needs the build.
    public static func items(in data: Data, source: String) throws -> [AppcastItem] {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let failure = delegate.failure { throw ToolError("\(source):\(failure)") }
        guard parsed else {
            throw ToolError("\(source):\(parser.lineNumber): \(parser.parserError?.localizedDescription ?? "doesn't parse")")
        }
        return delegate.items
    }

    /// - Blocking: reads the file.
    public static func items(at url: URL) throws -> [AppcastItem] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolError("can't read \(url.path): \(error.localizedDescription)")
        }
        return try items(in: data, source: url.path)
    }

    private static let downloads = URLSession.bounded(requestTimeout: 120)

    /// `url`'s body after redirects, or an error naming what failed. For `check --live`'s enclosure download.
    public static func download(_ url: String) async throws -> Data {
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        let (data, response) = try await downloads.data(from: parsed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ToolError("\(url) answered HTTP \(status)") }
        return data
    }

    /// What updaters polling `url` see right now. Only a 404 reads as empty, since nothing has been published there
    /// yet. Anything else short of a feed with items throws: a release planned from a feed that merely failed to load
    /// would reuse a shipped build number and drop the notes before it.
    public static func published(_ url: String, transport: any HTTPTransport) async throws -> [AppcastItem] {
        guard let parsed = URL(string: url) else { throw ToolError("\(url) isn't a URL") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(URLRequest(url: parsed))
        } catch {
            throw ToolError("can't read the published feed \(url): \(error.localizedDescription)")
        }
        let status = response.statusCode
        switch status {
        case 404:
            return []
        case 200..<300:
            let items = try items(in: data, source: "the published feed \(url) (HTTP \(status))")
            guard !items.isEmpty else {
                throw ToolError("the published feed \(url) answered HTTP \(status) with no <item>")
            }
            return items
        default:
            throw ToolError("the published feed \(url) answered HTTP \(status)")
        }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        /// The first problem, as `line: reason`. FoundationXML on Linux returns true from `parse()` for a truncated or
        /// malformed document and reports the error only here.
        private(set) var failure: String?
        private var current: AppcastItem?
        private var build: String?
        private var text = ""
        private let rfc822: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return formatter
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            if elementName == "item" {
                current = AppcastItem(build: 0)
                build = nil
            }
            if elementName == "enclosure", current != nil {
                current?.enclosureURL = attributeDict["url"]
                current?.enclosureLength = attributeDict["length"].flatMap { Int($0) }
                current?.edSignature = attributeDict["sparkle:edSignature"]
            }
        }

        private func fail(_ parser: XMLParser, _ reason: String) {
            if failure == nil { failure = "\(parser.lineNumber): \(reason)" }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            fail(parser, parseError.localizedDescription)
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
            case "sparkle:version": build = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "sparkle:hardwareRequirements":
                current?.hardwareRequirements = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            case "pubDate": current?.publishedAt = rfc822.date(from: value)
            case "description": current?.description = text
            case "item":
                guard var item = current, let number = build.flatMap({ Int($0) }) else {
                    fail(
                        parser,
                        "item \(items.count + 1) has sparkle:version \(build.map { "`\($0)`" } ?? "missing"), "
                            + "not an integer build")
                    parser.abortParsing()
                    return
                }
                item.build = number
                items.append(item)
                current = nil
            default: break
            }
        }
    }
}
