import Foundation
import Testing

@testable import DylManifest

struct DylAppManifestTests {
    static let valid = """
        [app]
        name = "Demo"
        bundle-id = "com.example.Demo"
        platforms = { macos = "14.0" }
        category = "public.app-category.utilities"

        [build]
        product = "Demo"
        entitlements = "Demo.entitlements"

        [bundle]
        usage = { NSLocalNetworkUsageDescription = "Finds things." }

        [release]
        sparkle-public-key = "key.txt"
        site-url = "https://demo.gattey.com"
        artifacts-dir = "server/public"
        check-interval = 3600
        assets = "https://store.public.blob.vercel-storage.com"
        """

    @Test func decodesKebabKeysAndKeepsUsageKeys() throws {
        let manifest = try DylAppManifest.decode(Self.valid)
        #expect(manifest.app.bundleId == "com.example.Demo")
        #expect(manifest.release.feedURL == "https://demo.gattey.com/appcast.xml")
        #expect(manifest.release.assets == "https://store.public.blob.vercel-storage.com")
        #expect(manifest.release.checkInterval == 3600)
        #expect(manifest.bundle.usage?["NSLocalNetworkUsageDescription"] == "Finds things.")
        #expect(manifest.ios == nil)
    }

    @Test func parsesCommentsTrailingCommasAndInlineTables() throws {
        let manifest = try DylAppManifest.decode(
            """
            # comment
            [app]
            name = "Sconeos" # trailing
            bundle-id = "com.example.Sconeos"
            platforms = { macos = "14.0", ios = "17.0" }
            category = "public.app-category.utilities"

            [build]
            product = "Sconeos"
            entitlements = "Demo.entitlements"

            [release]
            sparkle-public-key = "key.txt"
            site-url = "https://demo.gattey.com/"
            artifacts-dir = "server/public"
            check-interval = 3600
            assets = "https://store.public.blob.vercel-storage.com/"

            [site]
            tagline = "Hello"
            accent = { light = "#fff", dark = "#000" }
            screenshots = [
                { src = "a.png", alt = "A" },
                { src = "b.png", alt = "B" }, # trailing comma
            ]
            """)
        #expect(manifest.app.name == "Sconeos")
        #expect(manifest.app.platforms.ios == "17.0")
        #expect(manifest.release.checkInterval == 3600)
        #expect(manifest.release.siteUrl == "https://demo.gattey.com")
        #expect(manifest.release.feedURL == "https://demo.gattey.com/appcast.xml")
        #expect(manifest.release.assets == "https://store.public.blob.vercel-storage.com")
    }

    @Test func reportsTheLineOfAnError() {
        do {
            _ = try DylAppManifest.decode("[app]\nname = \"a\"\nname = \"b\"\n", path: "DylApp.toml")
            Issue.record("expected an error")
        } catch {
            #expect(error.line == 3)
            #expect(error.message == "duplicate key `app.name`")
        }
        do {
            _ = try DylAppManifest.decode("[app]\nname = \"a\n", path: "DylApp.toml")
            Issue.record("expected an error")
        } catch {
            #expect(error.line == 2)
            #expect(error.message == "unterminated string")
        }
    }

    @Test func decodesEscapes() throws {
        let text = Self.valid.replacingOccurrences(of: "name = \"Demo\"", with: #"name = "a\"b\\c\n""#)
        #expect(try DylAppManifest.decode(text).app.name == "a\"b\\c\n")
    }

    @Test func missingKeyPointsAtItsTable() {
        let text = Self.valid.replacingOccurrences(of: "product = \"Demo\"\n", with: "")
        do {
            _ = try DylAppManifest.decode(text, path: "DylApp.toml")
            Issue.record("expected an error")
        } catch {
            #expect(error.description == "DylApp.toml:7: error: missing required key `build.product`")
        }
    }

    @Test func decodesTheSampleAppManifest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/SampleApp")
        let manifest = try DylAppManifest.load(root: root)
        #expect(manifest.app.name == "Sample")
        #expect(manifest.ios?.simulator == "iPhone 17 Pro")
    }

    @Test func rejectsNonHTTPSSiteURL() {
        let text = Self.valid.replacingOccurrences(of: "https://demo", with: "http://demo")
        do {
            _ = try DylAppManifest.decode(text, path: "DylApp.toml")
            Issue.record("expected an error")
        } catch {
            #expect(error.line == 16)
        }
    }

    @Test func decodesBuildResourcesIconDockTileAndLocalValues() throws {
        let text = Self.valid
            .replacingOccurrences(
                of: "entitlements = \"Demo.entitlements\"\n",
                with: """
                    entitlements = "Demo.entitlements"
                    icon = "Resources/AppIcon.icon"
                    accent-color = "AccentColor"
                    resources = ["Sources/Demo/Demo.xcdatamodeld", "Resources/Assets.xcassets"]
                    dock-tile-plugin = { product = "DemoDockTile", principal-class = "DemoDockTilePlugIn" }

                    """)
            + """

                [local-values]
                file = "Config.xcconfig"
                keys = { ContentfulSpaceID = "CONTENTFUL_SPACE_ID", ContentfulToken = "CONTENTFUL_TOKEN" }
                defaults = { ContentfulSpaceID = "placeholder" }
                """
        let manifest = try DylAppManifest.decode(text)
        #expect(manifest.build.icon == "Resources/AppIcon.icon")
        #expect(manifest.build.accentColor == "AccentColor")
        #expect(manifest.build.resources == ["Sources/Demo/Demo.xcdatamodeld", "Resources/Assets.xcassets"])
        #expect(
            manifest.build.dockTilePlugin
                == DylAppManifest.DockTilePlugin(product: "DemoDockTile", principalClass: "DemoDockTilePlugIn"))
        #expect(manifest.localValues?.file == "Config.xcconfig")
        #expect(manifest.localValues?.keys["ContentfulToken"] == "CONTENTFUL_TOKEN")
        #expect(manifest.localValues?.defaults == ["ContentfulSpaceID": "placeholder"])
    }

    @Test(arguments: [
        ("product = \"Demo\"\n", "product = \"Demo\"\nicon = \"A.icon\"\nicon-generator = \"g.swift\"\n", "not both"),
        ("product = \"Demo\"\n", "product = \"Demo\"\nresources = [\"Sources/Demo/Model.momd\"]\n", "isn't a"),
        ("[release]\n", "[bundle.info]\nCFBundleVersion = \"9\"\n\n[release]\n", "can't set CFBundleVersion"),
        ("[release]\n", "[bundle.info]\nNSDockTilePlugIn = \"X\"\n\n[release]\n", "can't set NSDockTilePlugIn"),
        ("product = \"Demo\"\n", "product = \"Demo\"\ndock-tile-plugin = { product = \"T\" }\n", "needs `product`"),
        ("[release]\n", "[local-values]\nkeys = { A = \"A\" }\ndefaults = { B = \"b\" }\n\n[release]\n", "isn't in"),
        ("assets = \"https://store.public.blob.vercel-storage.com\"", "", "missing required key `release.assets`"),
        ("store.public.blob", "store.private.blob", "must be a public Blob store's URL"),
        ("https://store.public", "http://store.public", "must be a public Blob store's URL"),
        ("[release]\n", "[bundle.info]\n\"a.b\" = true\n\n[release]\n", "can't contain `.`"),
    ])
    func rejectsInvalidAdditions(_ find: String, _ replacement: String, _ message: String) {
        do {
            _ = try DylAppManifest.decode(Self.valid.replacingOccurrences(of: find, with: replacement))
            Issue.record("expected an error containing \(message)")
        } catch {
            #expect(error.message.contains(message), "\(error.message)")
        }
    }
}
