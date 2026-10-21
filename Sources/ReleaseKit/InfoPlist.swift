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
        return plist
    }

    /// The iOS Simulator dev build's `Info.plist`: the shared bundle keys without Sparkle or AppKit ones. `actool`'s
    /// partial plist adds `CFBundleIcons`.
    public static func iOSContents(manifest: DylAppManifest, bundleId: String, minimumOS: String) -> Plist {
        var plist = contents(
            manifest: manifest, identity: .release, shortVersion: "1.0", build: "1", sparklePublicKey: nil)
        for key in [
            "CFBundleIconFile", "LSMinimumSystemVersion", "LSApplicationCategoryType", "NSHighResolutionCapable",
            "NSPrincipalClass", "SUFeedURL", "SUEnableAutomaticChecks", "SUScheduledCheckInterval",
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
        return plist
    }

    /// A resource bundle SwiftPM emits without an `Info.plist`; codesign refuses to seal the app without one.
    public static func resourceBundle(identifier: String) -> Plist {
        [
            "CFBundleIdentifier": .string(identifier),
            "CFBundlePackageType": .string("BNDL"),
            "CFBundleVersion": .string("1"),
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
