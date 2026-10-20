import Foundation

/// The Info.plist values every DylKit app reads at runtime. Empty strings count as missing.
public struct AppInfo: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var version: String?
    public var build: String?
    public var sparkleFeedURL: URL?
    public var sparklePublicEDKey: String?

    public init(lookup: (String) -> String?) {
        func value(_ key: String) -> String? {
            guard let text = lookup(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text
        }
        bundleIdentifier = value("CFBundleIdentifier")
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
        sparkleFeedURL = value("SUFeedURL").flatMap(URL.init(string:))
        sparklePublicEDKey = value("SUPublicEDKey")
    }

    public static var main: AppInfo {
        AppInfo { Bundle.main.object(forInfoDictionaryKey: $0) as? String }
    }

    /// Sparkle needs both a feed and a public key; dev builds have neither and must not start the updater.
    public var isReleaseConfigured: Bool { sparkleFeedURL != nil && sparklePublicEDKey != nil }
}
