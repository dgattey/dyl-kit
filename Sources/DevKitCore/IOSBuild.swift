import DylManifest
import DylToolSupport
import Foundation
import ReleaseKit

/// Builds the SwiftPM product for the iOS Simulator with `xcodebuild` (which resolves the package graph, DylKit
/// included), wraps it in `build/<App>-iOS.app`, and runs it on a simulator without opening Simulator.app.
public struct IOSBuild: Sendable {
    public let workspace: Workspace
    private let transport: any HTTPTransport

    public init(workspace: Workspace, transport: any HTTPTransport = URLSessionTransport(quick: true)) {
        self.workspace = workspace
        self.transport = transport
    }

    private var derivedData: URL { workspace.buildDir.appending(path: "ios/DerivedData") }
    public var appURL: URL { workspace.buildDir.appending(path: "\(workspace.manifest.app.name)-iOS.app") }
    private var bundleId: String { Self.devBundleId(workspace.manifest) }

    /// The `[ios]` bundle ID with `.dev`, so the simulator build never shares an identity with the release.
    static func devBundleId(_ manifest: DylAppManifest) -> String {
        "\(manifest.ios?.bundleId ?? manifest.app.bundleId).dev"
    }

    /// Stamped with the same version and build as the macOS dev build (see `DevVersion`).
    ///
    /// - Blocking: reads the published feeds, runs `xcodebuild`, `actool` and `codesign`.
    @discardableResult
    public func build() async throws -> URL {
        let manifest = workspace.manifest
        guard let minimumOS = manifest.app.platforms.ios else {
            throw ToolError("DylApp.toml has no [app] platforms.ios")
        }
        let version = try await DevVersion.current(workspace, transport: transport)
        let product = manifest.build.product
        let scheme = try Self.scheme(for: product, in: try schemes())
        let platform = ResourceCompiler.Platform.iOSSimulator
        let sdkVersion = try platform.sdkVersion()
        let linkerFlags = platform.platformVersionFlags(minimumOS: minimumOS, sdkVersion: sdkVersion)
        Log.step("xcodebuild \(scheme) for the iOS Simulator (SDK \(sdkVersion))")
        try Shell.run(
            Self.xcodebuildArguments(scheme: scheme, derivedData: derivedData, linkerFlags: linkerFlags),
            cwd: workspace.root)
        let products = derivedData.appending(path: "Build/Products/Debug-iphonesimulator")
        try ResourceCompiler.Platform.verifySDK(of: products.appending(path: product), sdkVersion: sdkVersion)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: appURL)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: products.appending(path: product), to: appURL.appending(path: product))
        for name in try fileManager.contentsOfDirectory(atPath: products.path) where name.hasSuffix(".bundle") {
            try fileManager.copyItem(at: products.appending(path: name), to: appURL.appending(path: name))
        }

        let generated = try ResourceCompiler(workspace: workspace)
            .compile(into: appURL, platform: .iOSSimulator, minimumOS: minimumOS)
        let localValues = ResolvedLocalValues.resolve(workspace)
        if manifest.localValues != nil { Log.step(localValues.summary) }
        let plist = InfoPlist.finalizing(
            InfoPlist.iOSContents(
                manifest: manifest, bundleId: bundleId, minimumOS: minimumOS, shortVersion: version.shortVersion,
                build: version.build),
            generated: generated, rawKeys: InfoPlist.rawKeys(manifest, iOS: true), localValues: localValues)
        try InfoPlist.data(plist).write(to: appURL.appending(path: "Info.plist"))
        try Shell.run(["codesign", "--force", "--sign", "-", appURL.path])
        Log.step("built \(appURL.path) (\(version.shortVersion), build \(version.build))")
        return appURL
    }

    /// `swift run` exports the macOS SDK as `SDKROOT`, and under it Xcode 27's clang warns that it links the simulator
    /// product against the macOS sysroot (`-Wincompatible-sysroot`, once per arch), so `env`, which `Shell` runs
    /// everything through, drops it.
    static func xcodebuildArguments(scheme: String, derivedData: URL, linkerFlags: [String]) -> [String] {
        [
            "-u", "SDKROOT",
            "xcodebuild", "build", "-quiet", "-scheme", scheme, "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path, "-skipPackagePluginValidation", "-skipMacroValidation",
            "OTHER_LDFLAGS=$(inherited) \(linkerFlags.joined(separator: " "))",
        ]
    }

    private struct SchemeList: Decodable {
        struct Workspace: Decodable { let schemes: [String] }
        let workspace: Workspace
    }

    /// - Blocking: runs `xcodebuild -list`.
    private func schemes() throws -> [String] {
        let json = try Shell.capture(["xcodebuild", "-list", "-json"], cwd: workspace.root)
        return try JSONDecoder().decode(SchemeList.self, from: Data(json.utf8)).workspace.schemes
    }

    /// Xcode names a package's scheme after the product when the package has several, but after the executable
    /// target when it's the only one, so the product name alone isn't always a scheme.
    static func scheme(for product: String, in schemes: [String]) throws -> String {
        if schemes.contains(product) { return product }
        let apps = schemes.filter { !$0.hasSuffix("-Package") }
        guard apps.count == 1, let only = apps.first else {
            throw ToolError("no Xcode scheme named \(product); schemes: \(schemes.joined(separator: ", "))")
        }
        return only
    }

    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }

        let devices: [String: [Device]]
    }

    /// Boots the manifest's simulator if needed (headless: Simulator.app stays closed), installs and launches the
    /// app with `options`. Returns the simulator's UDID.
    ///
    /// - Blocking: runs `simctl`.
    @discardableResult
    public func run(options: LaunchOptions, simulator: String? = nil) throws -> String {
        guard let name = simulator ?? workspace.manifest.ios?.simulator else {
            throw ToolError("pass --simulator or set [ios] simulator in DylApp.toml")
        }
        let json = try Shell.capture(["xcrun", "simctl", "list", "devices", "available", "--json"])
        let list = try JSONDecoder().decode(DeviceList.self, from: Data(json.utf8))
        let matches = list.devices.sorted { $0.key > $1.key }.flatMap(\.value).filter { $0.name == name }
        guard let device = matches.first(where: { $0.state == "Booted" }) ?? matches.first else {
            throw ToolError("no available simulator named \(name); set [ios] simulator in DylApp.toml")
        }
        if device.state != "Booted" {
            try Shell.run(["xcrun", "simctl", "boot", device.udid])
        }
        // The simulator's own setting, not the Mac's; without --appearance it stays as the last run left it.
        if let appearance = options.appearance {
            try Shell.run(["xcrun", "simctl", "ui", device.udid, "appearance", appearance.rawValue])
        }
        try Shell.run(["xcrun", "simctl", "install", device.udid, appURL.path])
        let environment = Dictionary(
            uniqueKeysWithValues: options.environment.map { ("SIMCTL_CHILD_\($0.key)", $0.value) })
        try Shell.run(
            ["xcrun", "simctl", "launch", "--terminate-running-process", device.udid, bundleId],
            environment: environment
        )
        Log.step("launched \(bundleId) on \(name) (\(device.udid))")
        return device.udid
    }

    /// Screenshots the simulator once the app stops changing, so a launch spinner never ends up in the capture.
    ///
    /// - Blocking: runs `simctl io`.
    public func screenshot(udid: String, to output: URL, settle: SettleWait = .init()) async throws {
        try await settle.capture(to: output) { frame in
            try Shell.run(["xcrun", "simctl", "io", udid, "screenshot", frame.path], quiet: true)
        }
        Log.step("captured \(output.path)")
    }
}
