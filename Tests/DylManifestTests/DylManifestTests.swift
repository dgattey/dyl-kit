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
        inputs = ["Sources/**"]
        check-interval = 3600
        """

    @Test func decodesKebabKeysAndKeepsUsageKeys() throws {
        let manifest = try DylAppManifest.decode(Self.valid)
        #expect(manifest.app.bundleId == "com.example.Demo")
        #expect(manifest.release.feedURL == "https://demo.gattey.com/appcast.xml")
        #expect(manifest.release.checkInterval == 3600)
        #expect(manifest.launchPrefix == "DEMO")
        #expect(manifest.bundle.usage?["NSLocalNetworkUsageDescription"] == "Finds things.")
        #expect(manifest.ios == nil)
    }

    @Test func launchPrefixKeepsLettersAndDigits() throws {
        let text = Self.valid.replacingOccurrences(of: "name = \"Demo\"", with: "name = \"Scone OS!\"")
        #expect(try DylAppManifest.decode(text).launchPrefix == "SCONEOS")
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
            inputs = [
                "Sources/**",
                "Package.swift", # trailing comma below
            ]

            [site]
            tagline = "Hello"
            accent = { light = "#fff", dark = "#000" }
            screenshots = [
                { src = "a.png", alt = "A" },
            ]
            """)
        #expect(manifest.app.name == "Sconeos")
        #expect(manifest.app.platforms.ios == "17.0")
        #expect(manifest.release.checkInterval == 3600)
        #expect(manifest.release.inputs == ["Sources/**", "Package.swift"])
        #expect(manifest.release.feedURL == "https://demo.gattey.com/appcast.xml")
        #expect(manifest.launchPrefix == "SCONEOS")
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
        #expect(manifest.launchPrefix == "SAMPLE")
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
}
