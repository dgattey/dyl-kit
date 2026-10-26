import DylToolSupport
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// The Sparkle private key `release-kit appcast` signs with. Every candidate is tried against the public key the
/// staged app trusts before `generate_appcast` runs, because Sparkle's own fallback, the login Keychain's shared
/// `ed25519` account, holds whichever app's key was generated last on that Mac.
public enum SparkleKey {
    /// Sparkle's default Keychain account, which every app on a Mac shares.
    static let sharedAccount = "ed25519"

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
    /// slug, the Keychain account named after the bundle ID, then Sparkle's shared default.
    static func candidates(workspace: Workspace, home: URL) -> [Location] {
        let manifest = workspace.manifest
        let perUser = ".config/\(manifest.app.slug)/sparkle_ed.key"
        return [
            .file(workspace.url(".cert/sparkle_ed.key"), label: ".cert/sparkle_ed.key"),
            .file(workspace.url("sparkle_private.key"), label: "sparkle_private.key"),
            .file(home.appending(path: perUser), label: "~/\(perUser)"),
            .keychain(account: manifest.app.bundleId),
            .keychain(account: sharedAccount),
        ]
    }

    /// The first of `candidates` whose key signs for `publicKey`. Throws, listing what each location held, when none
    /// does.
    static func resolve(
        _ candidates: [Location], publicKey: String, bundleId: String, probe: (Location) throws -> Probe
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
        throw ToolError(
            (["no Sparkle private key matches the app's SUPublicEDKey \(publicKey). Checked:"]
                + checked.map { "  - \($0)" }
                + [
                    "Store the app's key with Sparkle's `generate_keys --account \(bundleId) -f <exported key>`, pass "
                        + "--ed-key-file, or rehearse with `release-kit appcast --throwaway-key`."
                ]).joined(separator: "\n"))
    }

    /// Signs `archive` with `location`'s key through Sparkle's `sign_update` and checks the signature against
    /// `publicKey`, so any key format Sparkle reads works.
    ///
    /// - Blocking: runs sign_update, which may read the Keychain.
    static func probe(_ location: Location, signUpdate: URL, archive: URL, publicKey: String) throws -> Probe {
        if case .file(let url, _) = location, !FileManager.default.fileExists(atPath: url.path) {
            return .unavailable("no file")
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
