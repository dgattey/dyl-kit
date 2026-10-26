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
                "Keychain account ed25519 (Sparkle's default, shared by every app on this Mac)",
            ])
        let perApp = SparkleKey.Location.keychain(account: "com.dylkit.Sample")
        #expect(perApp.arguments == ["--account", "com.dylkit.Sample"])
    }

    @Test func theFirstMatchingKeyWinsOverAnotherAppsKey() throws {
        let candidates: [SparkleKey.Location] = [
            .file(home.appending(path: "missing.key"), label: "missing.key"),
            .keychain(account: "com.dylkit.Sample"),
            .keychain(account: SparkleKey.sharedAccount),
        ]
        var probed: [SparkleKey.Location] = []
        let chosen = try SparkleKey.resolve(candidates, publicKey: "pub", bundleId: "com.dylkit.Sample") { location in
            probed.append(location)
            switch location {
            case .file: return .unavailable("no file")
            case .keychain(let account): return account == "com.dylkit.Sample" ? .matches : .differs
            }
        }
        #expect(chosen == .keychain(account: "com.dylkit.Sample"))
        #expect(probed.count == 2)
    }

    @Test func noMatchListsEveryLocationChecked() throws {
        let workspace = try Workspace.locate(appRoot.path)
        let candidates = SparkleKey.candidates(workspace: workspace, home: home)
        let error = #expect(throws: ToolError.self) {
            try SparkleKey.resolve(candidates, publicKey: "pub", bundleId: "com.dylkit.Sample") { location in
                if case .keychain(let account) = location, account == SparkleKey.sharedAccount { return .differs }
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
                  - Keychain account ed25519 (Sparkle's default, shared by every app on this Mac): a different key, \
                not this app's
                Store the app's key with Sparkle's `generate_keys --account com.dylkit.Sample -f <exported key>`, pass \
                --ed-key-file, or rehearse with `release-kit appcast --throwaway-key`.
                """)
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
