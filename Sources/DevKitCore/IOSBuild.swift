import DylToolSupport
import Foundation
import ReleaseKit

/// Builds the SwiftPM product for the iOS Simulator with `xcodebuild` (which resolves the package graph, DylKit
/// included), wraps it in `build/<App>-iOS.app`, and runs it on a simulator without opening Simulator.app.
public struct IOSBuild: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    private var derivedData: URL { workspace.buildDir.appending(path: "ios/DerivedData") }
    public var appURL: URL { workspace.buildDir.appending(path: "\(workspace.manifest.app.name)-iOS.app") }
    private var bundleId: String { workspace.manifest.ios?.bundleId ?? workspace.manifest.app.bundleId }

    /// - Blocking: runs `xcodebuild`, `actool` and `codesign`.
    @discardableResult
    public func build() throws -> URL {
        let manifest = workspace.manifest
        guard let minimumOS = manifest.app.platforms.ios else {
            throw ToolError("DylApp.toml has no [app] platforms.ios")
        }
        let product = manifest.build.product
        Log.step("xcodebuild \(product) for the iOS Simulator")
        try Shell.run(
            [
                "xcodebuild", "build", "-quiet", "-scheme", product, "-destination", "generic/platform=iOS Simulator",
                "-derivedDataPath", derivedData.path, "-skipPackagePluginValidation", "-skipMacroValidation",
            ],
            cwd: workspace.root
        )
        let products = derivedData.appending(path: "Build/Products/Debug-iphonesimulator")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: appURL)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: products.appending(path: product), to: appURL.appending(path: product))
        for name in try fileManager.contentsOfDirectory(atPath: products.path) where name.hasSuffix(".bundle") {
            try fileManager.copyItem(at: products.appending(path: name), to: appURL.appending(path: name))
        }

        var plist = InfoPlist.iOSContents(manifest: manifest, bundleId: bundleId, minimumOS: minimumOS)
        if let catalog = try Bundler(workspace: workspace).generateIcons() {
            let partial = workspace.buildDir.appending(path: "ios/assetcatalog_generated_info.plist")
            try Shell.run(
                [
                    "xcrun", "actool", catalog.path, "--compile", appURL.path, "--platform", "iphonesimulator",
                    "--minimum-deployment-target", minimumOS, "--app-icon", "AppIcon",
                    "--output-partial-info-plist", partial.path,
                ],
                allowFailure: true
            )
            plist.merge(InfoPlist.read(partial) ?? [:]) { _, generated in generated }
            try? fileManager.removeItem(at: partial)
        }
        try InfoPlist.data(plist).write(to: appURL.appending(path: "Info.plist"))
        try Shell.run(["codesign", "--force", "--sign", "-", appURL.path])
        Log.step("built \(appURL.path)")
        return appURL
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
    public func run(options: LaunchOptions) throws -> String {
        guard let name = workspace.manifest.ios?.simulator else {
            throw ToolError("DylApp.toml has no [ios] simulator")
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
        try Shell.run(["xcrun", "simctl", "install", device.udid, appURL.path])
        let prefix = workspace.manifest.launchPrefix
        let environment = Dictionary(
            uniqueKeysWithValues: options.environment(prefix: prefix).map { ("SIMCTL_CHILD_\($0.key)", $0.value) })
        try Shell.run(
            ["xcrun", "simctl", "launch", "--terminate-running-process", device.udid, bundleId],
            environment: environment
        )
        Log.step("launched \(bundleId) on \(name) (\(device.udid))")
        return device.udid
    }

    /// - Blocking: runs `simctl io`.
    public func screenshot(udid: String, to output: URL) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Shell.run(["xcrun", "simctl", "io", udid, "screenshot", output.path])
        Log.step("captured \(output.path)")
    }
}
