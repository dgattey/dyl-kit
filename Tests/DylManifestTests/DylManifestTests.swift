import Foundation
import Testing

@testable import DylManifest

struct TOMLTests {
    @Test func parsesTablesDottedKeysAndInlineTables() throws {
        let table = try TOML.parse(
            """
            # comment
            [app]
            name = "Sconeos" # trailing
            platforms = { macos = "14.0", ios = '17.0' }
            [release]
            check-interval = 3_600
            inputs = [
                "Sources/**",
                "Package.swift", # trailing comma below
            ]
            a.b = true
            """)
        #expect(table.value(at: "app.name") == .string("Sconeos"))
        #expect(table.value(at: "app.platforms.ios") == .string("17.0"))
        #expect(table.value(at: "release.check-interval") == .integer(3600))
        #expect(table.value(at: "release.inputs") == .array([.string("Sources/**"), .string("Package.swift")]))
        #expect(table.value(at: "release.a.b") == .boolean(true))
        #expect(table.line(of: "release.inputs") == 7)
        #expect(table.line(of: "app.platforms.ios") == 4)
    }

    @Test func reportsTheLineOfAnError() {
        #expect(throws: TOMLError(line: 3, message: "duplicate key `app.name`")) {
            try TOML.parse("[app]\nname = \"a\"\nname = \"b\"\n")
        }
        #expect(throws: TOMLError(line: 2, message: "unterminated string")) {
            try TOML.parse("[app]\nname = \"a\n")
        }
    }

    @Test func decodesEscapes() throws {
        let table = try TOML.parse(#"s = "a\"b\\c\u00e9""#)
        #expect(table["s"] == .string("a\"b\\cé"))
    }
}

struct DylAppManifestTests {
    static let valid = """
        [app]
        name = "Demo"
        bundle-id = "com.example.Demo"
        platforms = { macos = "14.0" }
        category = "public.app-category.utilities"

        [build]
        kind = "swiftpm"
        product = "Demo"
        entitlements = "Demo.entitlements"

        [bundle]
        usage = { NSLocalNetworkUsageDescription = "Finds things." }

        [release]
        sparkle-public-key = "key.txt"
        site-url = "https://demo.gattey.com"
        artifacts-dir = "server/public"
        inputs = ["Sources/**"]
        """

    @Test func decodesKebabKeysAndKeepsUsageKeys() throws {
        let (manifest, _) = try DylAppManifest.decode(Self.valid)
        #expect(manifest.app.bundleId == "com.example.Demo")
        #expect(manifest.release.feedURL == "https://demo.gattey.com/appcast.xml")
        #expect(manifest.bundle.usage?["NSLocalNetworkUsageDescription"] == "Finds things.")
        #expect(manifest.ios == nil)
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

    @Test func rejectsNonHTTPSSiteURL() {
        let text = Self.valid.replacingOccurrences(of: "https://demo", with: "http://demo")
        do {
            _ = try DylAppManifest.decode(text, path: "DylApp.toml")
            Issue.record("expected an error")
        } catch {
            #expect(error.line == 17)
        }
    }
}
