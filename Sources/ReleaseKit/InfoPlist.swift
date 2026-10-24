import DylManifest
import Foundation

/// A property-list value, so plists round-trip through `PropertyListEncoder` with types intact.
public enum PlistValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .boolean(bool)
        } else if let integer = try? container.decode(Int.self) {
            self = .integer(integer)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([PlistValue].self) {
            self = .array(array)
        } else {
            self = .dictionary(try container.decode([String: PlistValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public typealias Plist = [String: PlistValue]

/// Which app a bundle presents itself as. A dev build is `<bundle-id>.dev` named `<App> Dev`, with `-dev` URL schemes
/// and no Sparkle keys, so launching it never touches the installed release's preferences, updater state or URL
/// handlers.
public enum AppIdentity: Sendable {
    case release, dev

    public func bundleId(_ manifest: DylAppManifest) -> String {
        switch self {
        case .release: manifest.app.bundleId
        case .dev: "\(manifest.app.bundleId).dev"
        }
    }

    public func name(_ manifest: DylAppManifest) -> String {
        switch self {
        case .release: manifest.app.name
        case .dev: "\(manifest.app.name) Dev"
        }
    }

    func urlScheme(_ scheme: String) -> String {
        switch self {
        case .release: scheme
        case .dev: "\(scheme)-dev"
        }
    }
}

/// The app's `Info.plist`, derived entirely from `DylApp.toml` plus the version being built.
public enum InfoPlist {
    public static func contents(
        manifest: DylAppManifest, identity: AppIdentity, shortVersion: String, build: String,
        sparklePublicKey: String?
    )
        -> Plist
    {
        let app = manifest.app
        let bundleId = identity.bundleId(manifest)
        let name = identity.name(manifest)
        var plist: Plist = [
            "CFBundleDevelopmentRegion": .string("en"),
            "CFBundleExecutable": .string(manifest.build.product),
            "CFBundleIconFile": .string("AppIcon"),
            "CFBundleIconName": .string("AppIcon"),
            "CFBundleIdentifier": .string(bundleId),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundleName": .string(name),
            "CFBundleDisplayName": .string(name),
            "CFBundlePackageType": .string("APPL"),
            "CFBundleShortVersionString": .string(shortVersion),
            "CFBundleVersion": .string(build),
            "LSMinimumSystemVersion": .string(app.platforms.macos),
            "LSApplicationCategoryType": .string(app.category),
            "NSHighResolutionCapable": .boolean(true),
            "NSPrincipalClass": .string("NSApplication"),
        ]
        if let plugin = manifest.build.dockTilePlugin { plist["NSDockTilePlugIn"] = .string(plugin.bundleName) }
        for (key, text) in manifest.bundle.usage ?? [:] { plist[key] = .string(text) }
        if let services = manifest.bundle.bonjourServices, !services.isEmpty {
            plist["NSBonjourServices"] = .array(services.map(PlistValue.string))
        }
        if let schemes = manifest.bundle.urlSchemes, !schemes.isEmpty {
            plist["CFBundleURLTypes"] = .array([
                .dictionary([
                    "CFBundleTypeRole": .string("Editor"),
                    "CFBundleURLName": .string(manifest.bundle.urlName.map { identity.urlScheme($0) } ?? bundleId),
                    "CFBundleURLSchemes": .array(schemes.map { .string(identity.urlScheme($0)) }),
                ])
            ])
        }
        switch identity {
        case .release:
            plist["SUFeedURL"] = .string(manifest.release.feedURL)
            plist["SUEnableAutomaticChecks"] = .boolean(true)
            plist["SUScheduledCheckInterval"] = .integer(manifest.release.checkInterval ?? 86_400)
            if let sparklePublicKey, !sparklePublicKey.isEmpty { plist["SUPublicEDKey"] = .string(sparklePublicKey) }
        case .dev:
            break
        }
        return merging(manifest.bundle.info, into: plist)
    }

    /// `[bundle.info]`-style raw keys over `plist`. The manifest already refused keys DylKit derives.
    public static func merging(_ info: [String: TOMLValue], into plist: Plist) -> Plist {
        plist.merging(info.mapValues(value)) { _, raw in raw }
    }

    static func value(_ toml: TOMLValue) -> PlistValue {
        switch toml {
        case .string(let value): .string(value)
        case .integer(let value): .integer(value)
        case .boolean(let value): .boolean(value)
        case .array(let items): .array(items.map(value))
        case .table(let entries): .dictionary(entries.mapValues(value))
        }
    }

    /// Merges what `actool` generated (icon names, `NSAccentColorName`, `CFBundleIcons`) under the manifest's raw
    /// keys, then the local values over everything.
    public static func finalizing(
        _ plist: Plist, generated: Plist, rawKeys: Set<String>, localValues: ResolvedLocalValues
    ) -> Plist {
        var result = plist
        for (key, value) in generated where !rawKeys.contains(key) { result[key] = value }
        for (key, value) in localValues.values { result[key] = .string(value) }
        return result
    }

    /// The iOS Simulator dev build's `Info.plist`: the shared bundle keys without Sparkle or AppKit ones. `actool`'s
    /// partial plist adds `CFBundleIcons`.
    public static func iOSContents(
        manifest: DylAppManifest, bundleId: String, minimumOS: String, shortVersion: String, build: String
    ) -> Plist {
        var plist = contents(
            manifest: manifest, identity: .release, shortVersion: shortVersion, build: build, sparklePublicKey: nil)
        for key in [
            "CFBundleIconFile", "LSMinimumSystemVersion", "LSApplicationCategoryType", "NSHighResolutionCapable",
            "NSPrincipalClass", "SUFeedURL", "SUEnableAutomaticChecks", "SUScheduledCheckInterval", "NSDockTilePlugIn",
        ] {
            plist[key] = nil
        }
        plist["CFBundleIdentifier"] = .string(bundleId)
        plist["CFBundleSupportedPlatforms"] = .array([.string("iPhoneSimulator")])
        plist["MinimumOSVersion"] = .string(minimumOS)
        plist["LSRequiresIPhoneOS"] = .boolean(true)
        plist["UIDeviceFamily"] = .array([.integer(1), .integer(2)])
        plist["UILaunchScreen"] = .dictionary([:])
        plist["UISupportedInterfaceOrientations"] = .array(
            ["Portrait", "LandscapeLeft", "LandscapeRight"].map { .string("UIInterfaceOrientation\($0)") })
        return merging(manifest.bundle.info.merging(manifest.ios?.info ?? [:]) { $1 }, into: plist)
    }

    /// Keys the manifest sets raw, which win over what `actool` generates.
    public static func rawKeys(_ manifest: DylAppManifest, iOS: Bool) -> Set<String> {
        var keys = Set(manifest.bundle.info.keys)
        if iOS, let info = manifest.ios?.info { keys.formUnion(info.keys) }
        return keys
    }

    /// A resource bundle SwiftPM emits without an `Info.plist`; codesign refuses to seal the app without one.
    public static func resourceBundle(identifier: String) -> Plist {
        [
            "CFBundleIdentifier": .string(identifier),
            "CFBundlePackageType": .string("BNDL"),
            "CFBundleVersion": .string("1"),
        ]
    }

    /// The dock tile plug-in's `Info.plist`. Its identifier is the app's plus `.docktile`, so a plug-in finds the
    /// app's preferences domain by dropping that suffix from its own, `<bundle-id>.dev` in dev builds.
    public static func dockTilePlugin(
        _ plugin: DylAppManifest.DockTilePlugin, manifest: DylAppManifest, identity: AppIdentity,
        shortVersion: String, build: String
    ) -> Plist {
        [
            "CFBundleExecutable": .string(plugin.product),
            "CFBundleIdentifier": .string("\(identity.bundleId(manifest)).docktile"),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundleName": .string(plugin.product),
            "CFBundlePackageType": .string("BNDL"),
            "CFBundleShortVersionString": .string(shortVersion),
            "CFBundleVersion": .string(build),
            "NSPrincipalClass": .string(plugin.principalClass),
        ]
    }

    public static func data(_ plist: Plist) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(plist)
    }

    /// - Blocking: reads the file.
    public static func read(_ url: URL) -> Plist? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Plist.self, from: data)
    }
}
