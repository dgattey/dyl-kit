import Foundation

/// The schema of an app's `DylApp.toml`. Host tools, CI wrappers (through `devkit manifest get`), and the
/// app's site all read this one file.
public struct DylAppManifest: Codable, Equatable, Sendable {
    public var app: App
    public var build: Build
    public var bundle: Bundle
    public var ios: IOS?
    public var release: Release
    public var launch: Launch?
    public var site: Site?

    public struct App: Codable, Equatable, Sendable {
        public var name: String
        public var bundleId: String
        public var platforms: Platforms
        public var category: String
    }

    public struct Platforms: Codable, Equatable, Sendable {
        public var macos: String
        public var ios: String?
    }

    public struct Build: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case swiftpm
            case xcodeproj
        }

        public var kind: Kind
        /// Executable product passed to `swift build --product`.
        public var product: String
        public var entitlements: String
        /// Swift script that writes `build/AppIcon.icon` and `build/AppIcon*.icns` when run with the repo root.
        public var iconGenerator: String?
        /// Frameworks SwiftPM builds next to the product that the bundle must embed and sign.
        public var embedFrameworks: [String]?
    }

    /// Info.plist content beyond what the bundler derives from `[app]` and `[release]`.
    public struct Bundle: Codable, Equatable, Sendable {
        public var urlSchemes: [String]?
        public var urlName: String?
        public var bonjourServices: [String]?
        public var usage: [String: String]?
    }

    public struct IOS: Codable, Equatable, Sendable {
        public var bundleId: String?
        public var simulator: String?
    }

    public struct Release: Codable, Equatable, Sendable {
        public var sparklePublicKey: String
        public var siteUrl: String
        public var artifactsDir: String
        public var checkInterval: Int?
        public var notesMaxVersions: Int?
        /// Repo globs whose changes produce a release. Everything else merges without one.
        public var inputs: [String]

        public var feedURL: String { siteUrl.hasSuffix("/") ? "\(siteUrl)appcast.xml" : "\(siteUrl)/appcast.xml" }
    }

    /// Prefix for the launch-override environment variables (`<PREFIX>_INITIAL_VIEW`, `<PREFIX>_APPEARANCE`, ...).
    public struct Launch: Codable, Equatable, Sendable {
        public var envPrefix: String
    }

    public struct Site: Codable, Equatable, Sendable {
        public var tagline: String?
        public var gatekeeperNote: Bool?
    }
}

public struct ManifestError: Error, CustomStringConvertible, Sendable {
    public let path: String
    public let line: Int?
    public let message: String

    public var description: String {
        if let line { return "\(path):\(line): error: \(message)" }
        return "\(path): error: \(message)"
    }
}

extension DylAppManifest {
    public static let fileName = "DylApp.toml"

    /// Reads and validates `DylApp.toml` from `root`.
    public static func load(root: URL) throws(ManifestError) -> (DylAppManifest, TOMLTable) {
        let url = root.appending(path: fileName)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ManifestError(
                path: url.path, line: nil, message: "cannot read \(fileName): \(error.localizedDescription)")
        }
        return try decode(text, path: url.path)
    }

    public static func decode(
        _ text: String, path: String = fileName
    ) throws(ManifestError) -> (DylAppManifest, TOMLTable) {
        let table: TOMLTable
        do {
            table = try TOML.parse(text)
        } catch {
            throw ManifestError(path: path, line: error.line, message: error.message)
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(CamelCased(.table(table)))
        } catch {
            throw ManifestError(path: path, line: nil, message: "cannot convert manifest: \(error)")
        }
        do {
            let manifest = try JSONDecoder().decode(DylAppManifest.self, from: data)
            try manifest.validate(table: table, path: path)
            return (manifest, table)
        } catch let error as ManifestError {
            throw error
        } catch let error as DecodingError {
            throw describe(error, table: table, path: path)
        } catch {
            throw ManifestError(path: path, line: nil, message: "\(error)")
        }
    }

    private func validate(table: TOMLTable, path: String) throws(ManifestError) {
        func fail(_ key: String, _ message: String) -> ManifestError {
            ManifestError(path: path, line: table.line(of: key), message: message)
        }
        if !app.bundleId.contains(".") {
            throw fail("app.bundle-id", "`app.bundle-id` must be reverse-DNS, got `\(app.bundleId)`")
        }
        guard release.siteUrl.hasPrefix("https://") else {
            throw fail("release.site-url", "`release.site-url` must be an https URL")
        }
        if release.inputs.isEmpty {
            throw fail("release.inputs", "`release.inputs` must list at least one glob")
        }
        for (key, version) in [("app.platforms.macos", app.platforms.macos), ("app.platforms.ios", app.platforms.ios)] {
            guard let version else { continue }
            if version.split(separator: ".").contains(where: { Int($0) == nil }) {
                throw fail(key, "`\(key)` must be a dotted version, got `\(version)`")
            }
        }
    }

    private static func describe(_ error: DecodingError, table: TOMLTable, path: String) -> ManifestError {
        func key(_ codingPath: [any CodingKey]) -> String {
            codingPath.map { kebabCase($0.stringValue) }.joined(separator: ".")
        }
        func nearestLine(_ dotted: String) -> Int? {
            var components = dotted.split(separator: ".").map(String.init)
            while !components.isEmpty {
                if let line = table.line(of: components.joined(separator: ".")) { return line }
                components.removeLast()
            }
            return nil
        }
        switch error {
        case .keyNotFound(let missing, let context):
            let parent = key(context.codingPath)
            let full = parent.isEmpty ? kebabCase(missing.stringValue) : "\(parent).\(kebabCase(missing.stringValue))"
            return ManifestError(path: path, line: nearestLine(parent), message: "missing required key `\(full)`")
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            let dotted = key(context.codingPath)
            return ManifestError(path: path, line: nearestLine(dotted), message: "`\(dotted)` must be \(type)")
        case .dataCorrupted(let context):
            let dotted = key(context.codingPath)
            return ManifestError(
                path: path, line: nearestLine(dotted), message: "`\(dotted)`: \(context.debugDescription)")
        @unknown default:
            return ManifestError(path: path, line: nil, message: "\(error)")
        }
    }
}

func camelCase(_ kebab: String) -> String {
    let parts = kebab.split(separator: "-")
    guard let first = parts.first else { return kebab }
    return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

func kebabCase(_ camel: String) -> String {
    var result = ""
    for character in camel {
        if character.isUppercase {
            result += "-" + character.lowercased()
        } else {
            result.append(character)
        }
    }
    return result
}

/// Encodes a TOML tree as JSON with table keys converted to camelCase so `JSONDecoder` can fill the schema.
/// Free-form string maps (`bundle.usage`) keep their keys.
private struct CamelCased: Encodable {
    let value: TOMLValue
    let convertKeys: Bool

    init(_ value: TOMLValue, convertKeys: Bool = true) {
        self.value = value
        self.convertKeys = convertKeys
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .string(let string): try container.encode(string)
        case .integer(let integer): try container.encode(integer)
        case .float(let double): try container.encode(double)
        case .boolean(let bool): try container.encode(bool)
        case .array(let items): try container.encode(items.map { CamelCased($0) })
        case .table(let table):
            var converted: [String: CamelCased] = [:]
            for (key, child) in table.entries {
                converted[convertKeys ? camelCase(key) : key] = CamelCased(child, convertKeys: key != "usage")
            }
            try container.encode(converted)
        }
    }
}
