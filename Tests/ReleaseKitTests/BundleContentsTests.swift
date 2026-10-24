import Foundation
import Testing

#if canImport(CryptoKit)
import CryptoKit
#endif

@testable import DylManifest
@testable import ReleaseKit

@Suite struct LocalValuesTests {
    private let config = DylAppManifest.LocalValues(
        file: "Config.xcconfig",
        keys: ["SpaceID": "SPACE_ID", "Token": "TOKEN", "Unset": "UNSET"],
        defaults: ["SpaceID": "placeholder", "Token": "placeholder"])

    @Test func environmentThenFileThenDefaults() {
        let resolved = ResolvedLocalValues.resolve(
            config, fileText: "// local\nSPACE_ID = from-file\nTOKEN = from-file // trailing\n",
            environment: ["TOKEN": "from-env"])
        #expect(resolved.values == ["SpaceID": "from-file", "Token": "from-env"])
        #expect(resolved.sources == ["SpaceID": "Config.xcconfig", "Token": "env"])
        #expect(resolved.summary == "2 local values from Config.xcconfig, env")
        #expect(!resolved.summary.contains("from-"))
    }

    /// CI and fresh clones have no file, and ship the placeholders.
    @Test func noFileFallsBackToDefaults() {
        let resolved = ResolvedLocalValues.resolve(config, fileText: nil, environment: [:])
        #expect(resolved.values == ["SpaceID": "placeholder", "Token": "placeholder"])
        #expect(resolved.summary == "2 local values from defaults")
    }

    @Test func xcconfigLastAssignmentWins() {
        #expect(XCConfig.parse("A = 1\n\nA = 2\n  B=three  \n= x\n") == ["A": "2", "B": "three"])
    }
}

@Suite struct InfoPlistMergeTests {
    private func manifest(_ extra: String) throws -> DylAppManifest {
        let text = try String(contentsOf: appRoot.appending(path: "DylApp.toml"), encoding: .utf8)
        return try DylAppManifest.decode(text + extra)
    }

    @Test func rawInfoMergesOverTheDerivedKeys() throws {
        let manifest = try manifest(
            """

            [bundle.info]
            ITSAppUsesNonExemptEncryption = false
            NSPrincipalClass = "SampleApplication"

            [ios.info]
            UIRequiresFullScreen = true
            UIApplicationSceneManifest = { UIApplicationSupportsMultipleScenes = true }
            "UISupportedInterfaceOrientations~iphone" = ["UIInterfaceOrientationPortrait"]
            """)
        let macOS = InfoPlist.contents(
            manifest: manifest, identity: .release, shortVersion: "1.0.0", build: "1", sparklePublicKey: nil)
        #expect(macOS["ITSAppUsesNonExemptEncryption"] == .boolean(false))
        #expect(macOS["NSPrincipalClass"] == .string("SampleApplication"))
        #expect(macOS["UIRequiresFullScreen"] == nil)

        let iOS = InfoPlist.iOSContents(
            manifest: manifest, bundleId: "com.dylkit.Sample.ios", minimumOS: "17.0", shortVersion: "1.2.0",
            build: "54")
        #expect(iOS["CFBundleShortVersionString"] == .string("1.2.0"))
        #expect(iOS["CFBundleVersion"] == .string("54"))
        #expect(iOS["ITSAppUsesNonExemptEncryption"] == .boolean(false))
        #expect(iOS["UIRequiresFullScreen"] == .boolean(true))
        let scenes: PlistValue = .dictionary(["UIApplicationSupportsMultipleScenes": .boolean(true)])
        #expect(iOS["UIApplicationSceneManifest"] == scenes)
        #expect(iOS["UISupportedInterfaceOrientations~iphone"] == .array([.string("UIInterfaceOrientationPortrait")]))
        #expect(InfoPlist.rawKeys(manifest, iOS: true).contains("UIRequiresFullScreen"))
        #expect(!InfoPlist.rawKeys(manifest, iOS: false).contains("UIRequiresFullScreen"))
    }

    /// The plug-in's identifier tracks the app's, so a dev build's plug-in finds the dev app's preferences.
    @Test func dockTilePluginFollowsTheAppIdentity() throws {
        let manifest = try manifest("")
        let plugin = try #require(manifest.build.dockTilePlugin)
        for (identity, bundleId) in [(AppIdentity.release, "com.dylkit.Sample"), (.dev, "com.dylkit.Sample.dev")] {
            let app = InfoPlist.contents(
                manifest: manifest, identity: identity, shortVersion: "1.2.0", build: "7", sparklePublicKey: nil)
            #expect(app["NSDockTilePlugIn"] == .string("SampleDockTile.docktileplugin"))
            let plist = InfoPlist.dockTilePlugin(
                plugin, manifest: manifest, identity: identity, shortVersion: "1.2.0", build: "7")
            #expect(plist["CFBundleIdentifier"] == .string("\(bundleId).docktile"))
            #expect(plist["CFBundlePackageType"] == .string("BNDL"))
            #expect(plist["CFBundleExecutable"] == .string("SampleDockTile"))
            #expect(plist["NSPrincipalClass"] == .string("SampleDockTilePlugIn"))
            #expect(plist["CFBundleVersion"] == .string("7"))
        }
        let iOS = InfoPlist.iOSContents(
            manifest: manifest, bundleId: "com.dylkit.Sample.ios", minimumOS: "17.0", shortVersion: "1.2.0", build: "7")
        #expect(iOS["NSDockTilePlugIn"] == nil)
    }

    @Test func actoolOutputYieldsToRawKeysAndLocalValuesWinOverAll() {
        let derived: Plist = ["CFBundleIconName": .string("AppIcon"), "NSAccentColorName": .string("Raw")]
        let generated: Plist = ["CFBundleIconName": .string("Generated"), "NSAccentColorName": .string("Generated")]
        var local = ResolvedLocalValues()
        local.values = ["Token": "secret"]
        let plist = InfoPlist.finalizing(
            derived, generated: generated, rawKeys: ["NSAccentColorName"], localValues: local)
        #expect(plist["CFBundleIconName"] == .string("Generated"))
        #expect(plist["NSAccentColorName"] == .string("Raw"))
        #expect(plist["Token"] == .string("secret"))
    }

    @Test func oneActoolCallForCatalogsIconAndAccent() {
        let arguments = ResourceCompiler.actoolArguments(
            catalogs: ["Assets.xcassets", "AppIcon.icon"], hasIcon: true, accentColor: "AccentColor",
            platform: .macOS, minimumOS: "14.0", output: "Resources", partialPlist: "partial.plist")
        for expected in ["Assets.xcassets", "AppIcon.icon", "--app-icon", "--accent-color", "macosx"] {
            #expect(arguments.contains(expected))
        }
    }
}

/// `check --live` over hand-built snapshots: a matching update passes, and each way Saga's releases broke fails.
@Suite struct LiveComparisonTests {
    #if canImport(CryptoKit)
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private let feedURL = "https://sample.example.com/appcast.xml"

    private func item(_ version: String, build: Int, archive: Data, signedBy signer: Curve25519.Signing.PrivateKey? = nil)
        throws -> AppcastItem
    {
        var item = AppcastItem(build: build)
        item.shortVersion = version
        item.enclosureURL = "https://sample.example.com/Sample-\(version).zip"
        item.enclosureLength = archive.count
        item.edSignature = try (signer ?? key).signature(for: archive).base64EncodedString()
        return item
    }

    private func snapshot(version: String, build: String, feed: [AppcastItem], archive: Data) -> ReleaseSnapshot {
        ReleaseSnapshot(
            info: [
                "CFBundleIdentifier": .string("com.dylkit.Sample"), "CFBundleExecutable": .string("Sample"),
                "SUPublicEDKey": .string(publicKey), "SUFeedURL": .string(feedURL),
                "LSMinimumSystemVersion": .string("14.0"), "CFBundleShortVersionString": .string(version),
                "CFBundleVersion": .string(build), "DTXcode": .string(build),
            ],
            designatedRequirement: "designated => identifier \"com.dylkit.Sample\"",
            entitlements: ["com.apple.security.cs.disable-library-validation": .boolean(true)],
            signature: "adhoc", feed: feed, archive: archive)
    }

    private func comparison(mutate: (inout ReleaseSnapshot, inout ReleaseSnapshot) throws -> Void = { _, _ in })
        throws -> LiveComparison
    {
        let liveArchive = Data("live".utf8)
        let stagedArchive = Data("staged".utf8)
        var live = snapshot(
            version: "1.0.0", build: "10", feed: [try item("1.0.0", build: 10, archive: liveArchive)], archive: liveArchive)
        var staged = snapshot(
            version: "1.1.0", build: "11", feed: [try item("1.1.0", build: 11, archive: stagedArchive)],
            archive: stagedArchive)
        try mutate(&live, &staged)
        return LiveComparison(
            live: live, staged: staged, manifestFeedURL: feedURL, stagedCodesignFailure: nil, redactedKeys: ["Token"])
    }

    private func rules(_ comparison: LiveComparison) -> [String] {
        comparison.findings().filter { $0.severity == .error }.map(\.rule)
    }

    @Test func aMatchingUpdatePasses() throws {
        #expect(rules(try comparison()).isEmpty)
    }

    /// Saga's feed moved off github.com; the staged app must point where DylApp.toml says.
    @Test func feedMoveIsCaught() throws {
        let moved = try comparison { _, staged in staged.info["SUFeedURL"] = .string("https://github.com/o/r/appcast.xml") }
        #expect(rules(moved) == ["live_feed_url"])
    }

    @Test func aRotatedKeyOrOldBuildFails() throws {
        let rotated = try comparison { _, staged in
            let other = Curve25519.Signing.PrivateKey()
            staged.feed[0] = try item("1.1.0", build: 11, archive: staged.archive, signedBy: other)
        }
        #expect(rules(rotated) == ["live_ed_signature"])
        let resized = try comparison { _, staged in staged.feed[0].enclosureLength = staged.archive.count + 1 }
        #expect(rules(resized) == ["live_ed_signature"])
        let stale = try comparison { _, staged in staged.info["CFBundleVersion"] = .string("10") }
        #expect(Set(rules(stale)) == ["live_build_increases", "staged_appcast_matches_app"])
    }

    @Test func signingChangesFailAndARaisedMinimumOSWarns() throws {
        let changed = try comparison { _, staged in
            staged.designatedRequirement = "designated => cdhash H\"00\""
            staged.entitlements = [:]
            staged.signature = "Developer ID"
            staged.info["LSMinimumSystemVersion"] = .string("15.0")
        }
        #expect(Set(rules(changed)) == ["live_designated_requirement", "live_entitlements", "live_signing_scheme"])
        #expect(changed.findings().contains { $0.rule == "live_min_os" && $0.severity == .warning })
    }

    @Test func diffSkipsBuildMachineKeysAndRedactsLocalValues() throws {
        let diff = try comparison { _, staged in staged.info["Token"] = .string("s3cret") }.infoDiff()
        #expect(diff.contains("CFBundleVersion: 10 → 11"))
        #expect(diff.contains("Token: (none) → <6 chars>"))
        #expect(!diff.contains { $0.hasPrefix("DT") || $0.contains("s3cret") })
    }
    #endif
}
