import DylToolSupport
import Foundation
import Testing

@testable import ReleaseKit

/// Sparkle's tools fall back to the login Keychain's shared `ed25519` account, which on a Mac with several apps holds
/// another app's key, and `generate_appcast` then writes an unsigned appcast.
@Suite struct SparkleKeyTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test func candidatesUseTheSlugAndAPerAppKeychainAccountBeforeTheSharedOne() throws {
        let workspace = try Workspace.locate(appRoot.path)
        let labels = SparkleKey.candidates(workspace: workspace, home: home).map(\.label)
        #expect(
            labels == [
                ".cert/sparkle_ed.key", "sparkle_private.key", "~/.config/sample/sparkle_ed.key",
                "Keychain account com.dylkit.Sample",
            ])
        let perApp = SparkleKey.Location.keychain(account: "com.dylkit.Sample")
        #expect(perApp.arguments == ["--account", "com.dylkit.Sample"])
    }

    @Test func theFirstMatchingKeyWinsAndTheSharedAccountIsNeverTried() throws {
        let candidates: [SparkleKey.Location] = [
            .file(home.appending(path: "missing.key"), label: "missing.key"),
            .file(home.appending(path: "other.key"), label: "other.key"),
            .keychain(account: "com.dylkit.Sample"),
        ]
        var probed: [SparkleKey.Location] = []
        let chosen = try SparkleKey.resolve(
            candidates, publicKey: "pub", bundleId: "com.dylkit.Sample",
            sharedHoldsKey: { Issue.record("looked up the shared account after a match"); return true }
        ) { location in
            probed.append(location)
            switch location {
            case .file(_, let label): return label == "missing.key" ? .unavailable("no file") : .differs
            case .keychain: return .matches
            }
        }
        #expect(chosen == .keychain(account: "com.dylkit.Sample"))
        #expect(probed == candidates)
    }

    /// The shared account is only looked up, never read or probed, to explain a failure: reading another binary's
    /// item raises a Keychain prompt that blocks a headless run.
    @Test func theSharedAccountIsLookedUpNotRead() throws {
        let workspace = try Workspace.locate(appRoot.path)
        let candidates = SparkleKey.candidates(workspace: workspace, home: home)
        let error = #expect(throws: ToolError.self) {
            try SparkleKey.resolve(
                candidates, publicKey: "pub", bundleId: "com.dylkit.Sample", sharedHoldsKey: { true }
            ) { location in
                #expect(location != .keychain(account: SparkleKey.sharedAccount))
                return .unavailable("none")
            }
        }
        #expect(
            error?.description.contains(
                "Keychain account ed25519 (Sparkle's default, shared by every app on this Mac): holds a key, which "
                    + "release-kit never reads or signs from; if it's this app's, move it with "
                    + "`generate_keys -x <file>`, `generate_keys --account com.dylkit.Sample -f <file>`, then delete "
                    + "<file>") == true)
        let explicit = #expect(throws: ToolError.self) {
            try SparkleKey.resolve(
                [.file(home.appending(path: "a.key"), label: "--ed-key-file a.key")], publicKey: "pub",
                bundleId: "com.dylkit.Sample", sharedHoldsKey: nil
            ) { _ in .differs }
        }
        #expect(explicit?.description.contains("ed25519") == false)
    }

    @Test func noMatchListsEveryLocationChecked() throws {
        let workspace = try Workspace.locate(appRoot.path)
        let candidates = SparkleKey.candidates(workspace: workspace, home: home)
        let error = #expect(throws: ToolError.self) {
            try SparkleKey.resolve(
                candidates, publicKey: "pub", bundleId: "com.dylkit.Sample", sharedHoldsKey: { false }
            ) { location in
                if case .keychain = location { return .unavailable("no key") }
                return .unavailable("no file")
            }
        }
        #expect(
            error?.description == """
                no Sparkle private key matches the app's SUPublicEDKey pub. Checked:
                  - .cert/sparkle_ed.key: no file
                  - sparkle_private.key: no file
                  - ~/.config/sample/sparkle_ed.key: no file
                  - Keychain account com.dylkit.Sample: no key
                  - Keychain account ed25519 (Sparkle's default, shared by every app on this Mac): no key
                Store the app's key with Sparkle's `generate_keys --account com.dylkit.Sample -f <exported key>`, pass \
                --ed-key-file, or rehearse with `release-kit appcast --throwaway-key`.
                """)
    }

    /// A Keychain account with no item is skipped on its attributes alone, before sign_update could raise a prompt.
    @Test func aMissingKeychainItemIsNeverProbed() throws {
        let account = "com.dylkit.missing-\(UUID().uuidString)"
        #expect(try !SparkleKey.keychainHasItem(account: account))
        let probe = try SparkleKey.probe(
            .keychain(account: account), signUpdate: URL(fileURLWithPath: "/nonexistent/sign_update"),
            archive: URL(fileURLWithPath: "/nonexistent/a.zip"), publicKey: "pub")
        #expect(probe == .unavailable("no key"))
    }

    @Test func aRehearsalSignsItsOneEnclosure() throws {
        let unsigned = #"<item><enclosure url="https://x/a.zip" length="3" type="application/octet-stream"/></item>"#
        #expect(
            try SparkleKey.addingSignature("c2ln", to: unsigned)
                == #"<item><enclosure sparkle:edSignature="c2ln" url="https://x/a.zip" length="3" "#
                + #"type="application/octet-stream"/></item>"#)
        #expect(throws: ToolError.self) { try SparkleKey.addingSignature("c2ln", to: unsigned + unsigned) }
        #expect(throws: ToolError.self) {
            try SparkleKey.addingSignature("c2ln", to: try SparkleKey.addingSignature("c2ln", to: unsigned))
        }
    }

    #if canImport(CryptoKit)
    @Test func aThrowawayKeysSignatureVerifiesOnlyAgainstItsOwnPublicKey() throws {
        let pair = try SparkleKey.throwaway()
        #expect(Data(base64Encoded: pair.privateKey)?.count == 32)
        let archive = Data("zip".utf8)
        let signature = try SparkleKey.sign(archive, privateKey: pair.privateKey)
        #expect(EdSignature.verify(archive: archive, signature: signature, publicKey: pair.publicKey) == .valid)
        let other = try SparkleKey.throwaway().publicKey
        #expect(EdSignature.verify(archive: archive, signature: signature, publicKey: other) != .valid)
    }
    #endif
}

@Suite struct QuietShellTests {
    @Test func aFailureCarriesTheHeldBackOutput() throws {
        try Shell.runQuietly(["sh", "-c", "echo '<plist/>'; echo '{}' >&2"])
        let error = #expect(throws: ToolError.self) {
            try Shell.runQuietly(["sh", "-c", "echo 'actool: bad icon' >&2; exit 3"])
        }
        #expect(
            error?.description == "`sh -c echo 'actool: bad icon' >&2; exit 3` exited with status 3:\nactool: bad icon")
    }
}
