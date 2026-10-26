import DylToolSupport
import Foundation
import Testing

@testable import ReleaseKit

/// Sparkle's tools fall back to the login Keychain's shared `ed25519` account, which on a Mac with several apps holds
/// another app's key, so release-kit signs only from the app's own account, a key file or the CI secret.
@Suite struct SparkleKeyTests {
    private let perApp = SparkleKey.Location.keychain(account: "com.dylkit.Sample")

    @Test func aMatchingKeyIsUsedThroughItsAccount() throws {
        #expect(perApp.arguments == ["--account", "com.dylkit.Sample"])
        let chosen = try SparkleKey.resolve(perApp, publicKey: "pub", bundleId: "com.dylkit.Sample") { location in
            #expect(location == perApp)
            return .matches
        }
        #expect(chosen == perApp)
    }

    @Test func aMismatchSaysWhatTheLocationHeldAndHowToStoreTheKey() throws {
        let missing = #expect(throws: ToolError.self) {
            try SparkleKey.resolve(perApp, publicKey: "pub", bundleId: "com.dylkit.Sample") { _ in .unavailable("no key") }
        }
        #expect(
            missing?.description == """
                no Sparkle private key matches the app's SUPublicEDKey pub (Keychain account com.dylkit.Sample: no \
                key). Store the app's key with Sparkle's `generate_keys --account com.dylkit.Sample -f <exported \
                key>`, or pass --ed-key-file.
                """)
        let other = #expect(throws: ToolError.self) {
            try SparkleKey.resolve(
                .file(URL(fileURLWithPath: "/tmp/a.key"), label: "--ed-key-file a.key"), publicKey: "pub",
                bundleId: "com.dylkit.Sample"
            ) { _ in .differs }
        }
        #expect(other?.description.contains("(--ed-key-file a.key: a different key, not this app's)") == true)
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
