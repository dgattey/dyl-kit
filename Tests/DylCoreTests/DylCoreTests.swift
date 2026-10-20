import Foundation
import Testing

@testable import DylCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

@Suite struct AppVersionTests {
    @Test func parsesAndOrders() throws {
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("1.2") == AppVersion(major: 1, minor: 2, patch: 0))
        #expect(AppVersion("1.0.9-beta") == AppVersion(major: 1, minor: 0, patch: 9))
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("") == nil)
        #expect(try #require(AppVersion("1.0.10")) > #require(AppVersion("1.0.9")))
    }

    @Test func bumps() throws {
        let version = try #require(AppVersion("1.4.9"))
        #expect(version.bumped(.patch).description == "1.4.10")
        #expect(version.bumped(.minor).description == "1.5.0")
        #expect(version.bumped(.major).description == "2.0.0")
    }

    @Test func appInfoTreatsBlankKeysAsMissing() {
        let info = AppInfo { key in
            switch key {
            case .shortVersion: "1.0.9"
            case .sparkleFeedURL: "https://example.com/appcast.xml"
            case .sparklePublicEDKey: "  "
            default: nil
            }
        }
        #expect(info.version == AppVersion(major: 1, minor: 0, patch: 9))
        #expect(info.sparklePublicEDKey == nil)
        #expect(!info.isReleaseConfigured)
    }
}

@Suite struct CodableFileStoreTests {
    struct Note: Codable, Equatable, Sendable { var text: String }

    let directory = FileManager.default.temporaryDirectory.appending(path: "dylcore-\(UUID().uuidString)")

    @Test func roundTripsAndOrdersAsyncWrites() async throws {
        let store = CodableFileStore(directory: directory)
        let slot = FileSlot<Note>(name: "note.json", isDisposable: false)
        #expect(store.load(slot).content == nil)
        for index in 0..<20 {
            try await store.saveAsync(Note(text: "\(index)"), to: slot)
        }
        #expect(await store.loadAsync(slot).content == Note(text: "19"))
    }

    @Test func quarantinesCorruptUserData() throws {
        let store = CodableFileStore(directory: directory)
        let slot = FileSlot<Note>(name: "pins.json", isDisposable: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.url(for: slot.name))
        guard case .quarantined(let fileName) = store.load(slot) else {
            Issue.record("expected quarantine")
            return
        }
        #expect(fileName.hasPrefix("pins.json.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: store.url(for: fileName).path))
    }

    @Test func deletesCorruptCaches() throws {
        let store = CodableFileStore(directory: directory)
        let slot = FileSlot<Note>(name: "cache.json", isDisposable: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: store.url(for: slot.name))
        #expect(store.load(slot).content == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: slot.name).path))
    }
}

@Suite struct LaunchOverridesTests {
    @Test func environmentWinsOverArguments() {
        let overrides = LaunchOverrides(
            prefix: "APP",
            environment: ["APP_APPEARANCE": "Dark", "APP_SHOW_QUEUE": "1"],
            arguments: ["/bin/app", "--appearance=light", "--initial-view", "Group", "--window-size=402x874"]
        )
        #expect(overrides.appearance == .dark)
        #expect(overrides.initialView == "group")
        #expect(overrides.windowSize == CGSize(width: 402, height: 874))
        #expect(overrides.flag("show-queue"))
        #expect(!overrides.flag("missing"))
    }

    @Test func ignoresMalformedValues() {
        let overrides = LaunchOverrides(prefix: "APP", environment: [:], arguments: ["--window-size=wide", "--tab"])
        #expect(overrides.windowSize == nil)
        #expect(overrides.value("tab") == nil)
        #expect(overrides.flag("tab"))
    }
}

@Suite struct ConcurrencyHelperTests {
    @Test func singleFlightCoalescesConcurrentCalls() async {
        let flight = SingleFlight<Int>()
        let counter = Counter()
        async let first = flight.run {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return 1
        }
        try? await Task.sleep(for: .milliseconds(10))
        async let second = flight.run {
            await counter.increment()
            return 2
        }
        #expect(await first == 1)
        #expect(await second == 1)
        #expect(await counter.value == 1)
    }

    @Test func generationGuardRejectsStaleTokens() {
        var guardrail = GenerationGuard()
        let stale = guardrail.advance()
        let fresh = guardrail.advance()
        #expect(!guardrail.isCurrent(stale))
        #expect(guardrail.isCurrent(fresh))
    }

    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}

#if canImport(CryptoKit)
@Suite struct SecureFileVaultTests {
    struct Secret: Codable, Equatable, Sendable { var token: String }

    @Test func sealsWith0600AndRekeysFromFallback() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)/v.enc")
        let old = SecureFileVault<Secret>.deriveKey(material: "old", salt: "s", info: "i")
        let new = SecureFileVault<Secret>.deriveKey(material: "new", salt: "s", info: "i")
        try SecureFileVault<Secret>(fileURL: url, key: old).write(Secret(token: "abc"))

        let vault = SecureFileVault<Secret>(fileURL: url, key: new, fallbackKeys: { [old] })
        #expect(vault.read() == Secret(token: "abc"))
        #expect(SecureFileVault<Secret>(fileURL: url, key: new).read() == Secret(token: "abc"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try await vault.updateAsync { $0?.token = "def" }
        #expect(await vault.readAsync() == Secret(token: "def"))
        await vault.clearAsync()
        #expect(vault.read() == nil)
    }
}
#endif
