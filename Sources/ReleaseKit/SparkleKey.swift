import DylToolSupport
import Foundation

/// The Sparkle private key `release-kit appcast` signs with. Each app keeps its own key in the login Keychain account
/// named after its bundle ID, so release-kit never signs from Sparkle's default `ed25519` account, which holds whichever
/// app's key was generated last on that Mac. The key is checked against the public key the staged app trusts before
/// `generate_appcast` runs.
public enum SparkleKey {
    /// The service `generate_keys` files its Keychain items under.
    static let keychainService = "https://sparkle-project.org"

    public enum Location: Equatable, Sendable {
        case file(URL, label: String)
        case keychain(account: String)

        /// What `sign_update` and `generate_appcast` take to sign with this key.
        var arguments: [String] {
            switch self {
            case .file(let url, _): ["--ed-key-file", url.path]
            case .keychain(let account): ["--account", account]
            }
        }

        var label: String {
            switch self {
            case .file(_, let label): label
            case .keychain(let account): "Keychain account \(account)"
            }
        }
    }

    public enum Probe: Equatable, Sendable {
        case matches
        case differs
        case unavailable(String)
    }

    /// `location` when its key signs for `publicKey`; otherwise throws, saying what it held and how to store the key.
    static func resolve(
        _ location: Location, publicKey: String, bundleId: String, probe: (Location) throws -> Probe
    ) throws -> Location {
        let held: String
        switch try probe(location) {
        case .matches:
            Log.step("signing with the Sparkle key in \(location.label)")
            return location
        case .differs: held = "a different key, not this app's"
        case .unavailable(let reason): held = reason
        }
        throw ToolError(
            "no Sparkle private key matches the app's SUPublicEDKey \(publicKey) (\(location.label): \(held)). "
                + "Store the app's key with Sparkle's `generate_keys --account \(bundleId) -f <exported key>`, or pass "
                + "--ed-key-file.")
    }

    /// Whether the login Keychain has Sparkle's item for `account`. It reads only the item's attributes, never the
    /// secret, so it can't raise the access prompt that blocks a headless run when another binary owns the item.
    ///
    /// - Blocking: runs security.
    static func keychainHasItem(account: String) throws -> Bool {
        try Shell.run(
            ["security", "find-generic-password", "-s", keychainService, "-a", account], quiet: true,
            allowFailure: true) == 0
    }

    /// Signs `archive` with `location`'s key through Sparkle's `sign_update` and checks the signature against
    /// `publicKey`, so any key format Sparkle reads works. A location with no file or Keychain item is skipped
    /// without running it.
    ///
    /// - Blocking: runs sign_update, which may read the Keychain.
    static func probe(_ location: Location, signUpdate: URL, archive: URL, publicKey: String) throws -> Probe {
        switch location {
        case .file(let url, _) where !FileManager.default.fileExists(atPath: url.path): return .unavailable("no file")
        case .keychain(let account) where try !keychainHasItem(account: account): return .unavailable("no key")
        default: break
        }
        let output = try Shell.capture(
            [signUpdate.path] + location.arguments + [archive.path], includeStderr: true, allowFailure: true)
        guard let signature = output.firstMatch(of: /sparkle:edSignature="([^"]+)"/).map({ String($0.1) }) else {
            if case .keychain = location { return .unavailable("no key") }
            return .unavailable("sign_update can't read it")
        }
        switch EdSignature.verify(archive: try Data(contentsOf: archive), signature: signature, publicKey: publicKey) {
        case .valid: return .matches
        case .invalid: return .differs
        case .unverifiable: throw ToolError("can't verify edSignature on this platform; release from macOS")
        }
    }
}
