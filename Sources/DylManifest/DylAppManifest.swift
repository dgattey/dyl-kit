import Foundation

/// The schema of an app's `DylApp.toml`, which devkit and release-kit read.
public struct DylAppManifest: Equatable, Sendable {
    public var app: App
    public var build: Build
    public var bundle: Bundle
    public var ios: IOS?
    public var localValues: LocalValues?
    public var release: Release

    public struct App: Equatable, Sendable {
        public var name: String
        public var bundleId: String
        public var platforms: Platforms
        public var category: String
    }

    public struct Platforms: Equatable, Sendable {
        public var macos: String
        public var ios: String?
    }

    public struct Build: Equatable, Sendable {
        /// Executable product passed to `swift build --product`.
        public var product: String
        public var entitlements: String
        /// Swift script that writes `build/AppIcon.icon` and `build/AppIcon*.icns` when run with the repo root.
        public var iconGenerator: String?
        /// A committed Icon Composer `.icon` bundle, instead of `iconGenerator`.
        public var icon: String?
        /// The asset catalog color `actool` records as `NSAccentColorName`.
        public var accentColor: String?
        /// Committed `.xcdatamodeld`, `.xcmappingmodel` and `.xcassets` the bundler compiles into the main bundle.
        /// SwiftPM's command-line build copies them verbatim, so the app's target must `exclude:` them.
        public var resources: [String]

        fileprivate static let resourceExtensions: Set<String> = ["xcdatamodeld", "xcdatamodel", "xcmappingmodel", "xcassets"]
    }

    /// Info.plist content beyond what the bundler derives from `[app]` and `[release]`.
    public struct Bundle: Equatable, Sendable {
        public var urlSchemes: [String]?
        public var urlName: String?
        public var bonjourServices: [String]?
        public var usage: [String: String]?
        /// `[bundle.info]`: raw keys merged over the derived Info.plist, on macOS and iOS.
        public var info: [String: TOMLValue]
    }

    public struct IOS: Equatable, Sendable {
        public var bundleId: String?
        public var simulator: String?
        /// `[ios.info]`: raw keys merged over the iOS Info.plist, after `[bundle.info]`.
        public var info: [String: TOMLValue]
    }

    /// Info.plist strings for dev builds from a gitignored xcconfig, such as API credentials. Each value is the first
    /// of the environment variable, the variable in `file`, and the default; a key with none is left out.
    public struct LocalValues: Equatable, Sendable {
        public var file: String?
        /// Info.plist key to variable name.
        public var keys: [String: String]
        public var defaults: [String: String]
    }

    public struct Release: Equatable, Sendable {
        public var sparklePublicKey: String
        /// Without a trailing `/`.
        public var siteUrl: String
        public var artifactsDir: String
        public var checkInterval: Int?
        /// The public Vercel Blob store that holds every release's zip, `appcast.xml` and `release.json`, without a
        /// trailing `/`.
        public var assets: String

        public var feedURL: String { "\(siteUrl)/appcast.xml" }
    }

    /// Info.plist keys DylKit derives itself, which `[bundle.info]` and `[ios.info]` can't override.
    fileprivate static let derivedInfoKeys: Set<String> = [
        "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "SUFeedURL", "SUPublicEDKey",
        "LSMinimumSystemVersion", "MinimumOSVersion", "CFBundleExecutable",
    ]
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
    ///
    /// - Blocking: reads the file.
    public static func load(root: URL) throws(ManifestError) -> DylAppManifest {
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

    public static func decode(_ text: String, path: String = fileName) throws(ManifestError) -> DylAppManifest {
        let document: TOMLDocument
        do {
            document = try TOML.parse(text)
        } catch {
            throw ManifestError(path: path, line: error.line, message: error.message)
        }
        let toml = Reader(document: document, path: path)
        let manifest = DylAppManifest(
            app: App(
                name: try toml.required("app.name"),
                bundleId: try toml.required("app.bundle-id"),
                platforms: Platforms(macos: try toml.required("app.platforms.macos"), ios: try toml.string("app.platforms.ios")),
                category: try toml.required("app.category")
            ),
            build: Build(
                product: try toml.required("build.product"),
                entitlements: try toml.required("build.entitlements"),
                iconGenerator: try toml.string("build.icon-generator"),
                icon: try toml.string("build.icon"),
                accentColor: try toml.string("build.accent-color"),
                resources: try toml.strings("build.resources") ?? []
            ),
            bundle: Bundle(
                urlSchemes: try toml.strings("bundle.url-schemes"),
                urlName: try toml.string("bundle.url-name"),
                bonjourServices: try toml.strings("bundle.bonjour-services"),
                usage: try toml.stringMap("bundle.usage"),
                info: document.children(of: "bundle.info")
            ),
            ios: document.lines["ios"] == nil && document.lines["ios.info"] == nil
                ? nil
                : IOS(
                    bundleId: try toml.string("ios.bundle-id"), simulator: try toml.string("ios.simulator"),
                    info: document.children(of: "ios.info")),
            localValues: document.lines["local-values"] == nil
                ? nil
                : LocalValues(
                    file: try toml.string("local-values.file"),
                    keys: try toml.stringMap("local-values.keys") ?? [:],
                    defaults: try toml.stringMap("local-values.defaults") ?? [:]),
            release: Release(
                sparklePublicKey: try toml.required("release.sparkle-public-key"),
                siteUrl: withoutTrailingSlash(try toml.required("release.site-url")),
                artifactsDir: try toml.required("release.artifacts-dir"),
                checkInterval: try toml.integer("release.check-interval"),
                assets: withoutTrailingSlash(try toml.required("release.assets"))
            )
        )
        try manifest.validate(toml)
        return manifest
    }

    private static func withoutTrailingSlash(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    private func validate(_ toml: Reader) throws(ManifestError) {
        if !app.bundleId.contains(".") {
            throw toml.fail("app.bundle-id", "`app.bundle-id` must be reverse-DNS, got `\(app.bundleId)`")
        }
        guard release.siteUrl.hasPrefix("https://") else {
            throw toml.fail("release.site-url", "`release.site-url` must be an https URL")
        }
        if release.assets.wholeMatch(of: /https:\/\/[a-z0-9]+\.public\.blob\.vercel-storage\.com/.ignoresCase()) == nil {
            throw toml.fail(
                "release.assets",
                "`release.assets` must be a public Blob store's URL, https://<store>.public.blob.vercel-storage.com")
        }
        if build.icon != nil, build.iconGenerator != nil {
            throw toml.fail("build.icon", "set `build.icon` or `build.icon-generator`, not both")
        }
        for resource in build.resources
        where !Build.resourceExtensions.contains((resource as NSString).pathExtension) {
            throw toml.fail(
                "build.resources",
                "`\(resource)` isn't a \(Build.resourceExtensions.sorted().map { ".\($0)" }.joined(separator: ", "))")
        }
        for (table, info) in [("bundle.info", bundle.info), ("ios.info", ios?.info ?? [:])] {
            if let key = info.keys.sorted().first(where: DylAppManifest.derivedInfoKeys.contains) {
                throw toml.fail("\(table).\(key)", "`\(table)` can't set \(key); DylKit derives it")
            }
        }
        if let localValues {
            if localValues.keys.isEmpty {
                throw toml.fail("local-values.keys", "`local-values.keys` must map at least one Info.plist key")
            }
            if let key = localValues.defaults.keys.sorted().first(where: { localValues.keys[$0] == nil }) {
                throw toml.fail("local-values.defaults", "`local-values.defaults.\(key)` isn't in `local-values.keys`")
            }
        }
        for (key, version) in [("app.platforms.macos", app.platforms.macos), ("app.platforms.ios", app.platforms.ios)] {
            guard let version else { continue }
            if version.split(separator: ".").contains(where: { Int($0) == nil }) {
                throw toml.fail(key, "`\(key)` must be a dotted version, got `\(version)`")
            }
        }
    }
}

/// Typed lookups that report the line of the key, or of its nearest enclosing table when the key is missing.
private struct Reader {
    let document: TOMLDocument
    let path: String

    func fail(_ key: String, _ message: String) -> ManifestError {
        var components = key.split(separator: ".")
        var line: Int?
        while line == nil, !components.isEmpty {
            line = document.lines[components.joined(separator: ".")]
            components.removeLast()
        }
        return ManifestError(path: path, line: line, message: message)
    }

    func required(_ key: String) throws(ManifestError) -> String {
        guard let value = try string(key) else { throw fail(key, "missing required key `\(key)`") }
        return value
    }

    func string(_ key: String) throws(ManifestError) -> String? {
        switch document[key] {
        case nil: return nil
        case .string(let value): return value
        default: throw fail(key, "`\(key)` must be a string")
        }
    }

    func integer(_ key: String) throws(ManifestError) -> Int? {
        switch document[key] {
        case nil: return nil
        case .integer(let value): return value
        default: throw fail(key, "`\(key)` must be an integer")
        }
    }

    func strings(_ key: String) throws(ManifestError) -> [String]? {
        guard let value = document[key] else { return nil }
        guard case .array(let items) = value else { throw fail(key, "`\(key)` must be an array of strings") }
        var result: [String] = []
        for item in items {
            guard case .string(let string) = item else { throw fail(key, "`\(key)` must be an array of strings") }
            result.append(string)
        }
        return result
    }

    func stringMap(_ key: String) throws(ManifestError) -> [String: String]? {
        guard let value = document[key] else { return nil }
        guard case .table(let entries) = value else { throw fail(key, "`\(key)` must be an inline table") }
        var result: [String: String] = [:]
        for (name, entry) in entries {
            guard case .string(let string) = entry else { throw fail(key, "`\(key).\(name)` must be a string") }
            result[name] = string
        }
        return result
    }
}
