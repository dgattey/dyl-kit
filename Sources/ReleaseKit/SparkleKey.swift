import DylToolSupport
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// The Sparkle private key `release-kit appcast` signs with. Each app keeps its own key, so release-kit never signs
/// from Sparkle's default, the login Keychain's `ed25519` account, which holds whichever app's key was generated last
/// on that Mac. Every candidate is tried against the public key the staged app trusts before `generate_appcast` runs.
public enum SparkleKey {
    /// Sparkle's default Keychain account, which every app on a Mac shares.
    static let sharedAccount = "ed25519"
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
            case .keychain(let account) where account == SparkleKey.sharedAccount:
                "Keychain account \(account) (Sparkle's default, shared by every app on this Mac)"
            case .keychain(let account): "Keychain account \(account)"
            }
        }
    }

    public enum Probe: Equatable, Sendable {
        case matches
        case differs
        case unavailable(String)
    }

    /// Where an app's key may be, in the order they're tried: the repo's key files, the per-user file under the app's
    /// slug, then the Keychain account named after the bundle ID.
    static func candidates(workspace: Workspace, home: URL) -> [Location] {
        let manifest = workspace.manifest
        let perUser = ".config/\(manifest.app.slug)/sparkle_ed.key"
        return [
            .file(workspace.url(".cert/sparkle_ed.key"), label: ".cert/sparkle_ed.key"),
            .file(workspace.url("sparkle_private.key"), label: "sparkle_private.key"),
            .file(home.appending(path: perUser), label: "~/\(perUser)"),
            .keychain(account: manifest.app.bundleId),
        ]
    }

    /// The first of `candidates` whose key signs for `publicKey`. Throws, listing what each location held, when none
    /// does. `sharedHoldsKey`, when given, says whether Sparkle's shared account has an item; the list reports that,
    /// never reading the key, and says how to move the app's key out of it.
    static func resolve(
        _ candidates: [Location], publicKey: String, bundleId: String, sharedHoldsKey: (() throws -> Bool)?,
        probe: (Location) throws -> Probe
    ) throws -> Location {
        var checked: [String] = []
        for location in candidates {
            switch try probe(location) {
            case .matches:
                Log.step("signing with the Sparkle key in \(location.label)")
                return location
            case .differs: checked.append("\(location.label): a different key, not this app's")
            case .unavailable(let reason): checked.append("\(location.label): \(reason)")
            }
        }
        if let sharedHoldsKey {
            let shared = Location.keychain(account: sharedAccount).label
            checked.append(
                try sharedHoldsKey()
                    ? "\(shared): holds a key, which release-kit never reads or signs from; if it's this app's, move it "
                        + "with `generate_keys -x <file>`, `generate_keys --account \(bundleId) -f <file>`, then delete "
                        + "<file>"
                    : "\(shared): no key")
        }
        throw ToolError(
            (["no Sparkle private key matches the app's SUPublicEDKey \(publicKey). Checked:"]
                + checked.map { "  - \($0)" }
                + [
                    "Store the app's key with Sparkle's `generate_keys --account \(bundleId) -f <exported key>`, pass "
                        + "--ed-key-file, or rehearse with `release-kit appcast --throwaway-key`."
                ]).joined(separator: "\n"))
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

    /// `privateKey`'s signature on `archive`, base64 as the appcast carries it.
    static func sign(_ archive: Data, privateKey: String) throws -> String {
        #if canImport(CryptoKit)
        guard let seed = Data(base64Encoded: privateKey) else { throw ToolError("the throwaway key isn't base64") }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: archive).base64EncodedString()
        #else
        throw ToolError("a throwaway Sparkle key needs CryptoKit; rehearse on macOS")
        #endif
    }

    /// `appcast` with `sparkle:edSignature` added to its one enclosure. `generate_appcast` leaves an item unsigned when
    /// the key doesn't match the app's `SUPublicEDKey`, as a throwaway key never does.
    static func addingSignature(_ signature: String, to appcast: String) throws -> String {
        guard appcast.ranges(of: "<enclosure ").count == 1, !appcast.contains("sparkle:edSignature") else {
            throw ToolError("expected one unsigned enclosure in the rehearsal's appcast")
        }
        return appcast.replacing("<enclosure ", with: "<enclosure sparkle:edSignature=\"\(signature)\" ")
    }

    /// A fresh key for rehearsing a release without the app's: the base64 seed `--ed-key-file` reads, and its public
    /// key.
    static func throwaway() throws -> (privateKey: String, publicKey: String) {
        #if canImport(CryptoKit)
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
        #else
        throw ToolError("a throwaway Sparkle key needs CryptoKit; rehearse on macOS")
        #endif
    }
}
