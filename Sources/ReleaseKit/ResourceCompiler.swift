import DylToolSupport
import Foundation

/// Compiles what SwiftPM's command-line build only copies: the manifest's Core Data models (`momc`, `mapc`), and its
/// asset catalogs plus the app icon in one `actool` call. Any failure fails the build, so a missing icon or model
/// never ships silently.
public struct ResourceCompiler: Sendable {
    public enum Platform: Sendable {
        case macOS, iOSSimulator

        var actoolArguments: [String] {
            switch self {
            case .macOS: ["--platform", "macosx"]
            case .iOSSimulator: ["--platform", "iphonesimulator", "--target-device", "iphone", "--target-device", "ipad"]
            }
        }

        var sdk: String {
            switch self {
            case .macOS: "macosx"
            case .iOSSimulator: "iphonesimulator"
            }
        }

        /// momc has one flag for the device and the simulator.
        var momcTarget: String {
            switch self {
            case .macOS: "--macosx-deployment-target"
            case .iOSSimulator: "--iphoneos-deployment-target"
            }
        }
    }

    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// Compiles into `resources` and returns `actool`'s partial Info.plist (empty when there's no catalog or icon).
    /// The icon is the committed `[build] icon`, else what the icon generator wrote to `build/`. actool prints only its
    /// warnings and errors.
    ///
    /// - Blocking: runs `momc`, `mapc` and `actool`.
    public func compile(into resources: URL, platform: Platform, minimumOS: String) throws -> Plist {
        let manifest = workspace.manifest
        let sources = manifest.build.resources.map(workspace.url)
        for source in sources where !FileManager.default.fileExists(atPath: source.path) {
            throw ToolError("[build] resources: \(source.path) doesn't exist")
        }
        let icon = try manifest.build.icon.map(workspace.url) ?? Bundler(workspace: workspace).generateIcons()
        if let icon, !FileManager.default.fileExists(atPath: icon.path) {
            throw ToolError("[build] icon \(icon.path) doesn't exist")
        }
        let catalogs = sources.filter { $0.pathExtension == "xcassets" } + (icon.map { [$0] } ?? [])
        guard !sources.isEmpty || !catalogs.isEmpty else { return [:] }
        guard Shell.which("xcrun") != nil else { throw ToolError("compiling resources needs Xcode's xcrun") }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        for model in sources {
            switch model.pathExtension {
            case "xcdatamodeld", "xcdatamodel":
                try Shell.run([
                    "xcrun", "--sdk", platform.sdk, "momc", platform.momcTarget, minimumOS, model.path,
                    resources.path + "/",
                ])
            case "xcmappingmodel":
                let output = resources.appending(path: model.deletingPathExtension().lastPathComponent + ".cdm")
                try Shell.run(["xcrun", "--sdk", platform.sdk, "mapc", model.path, output.path])
            default:
                continue
            }
        }
        guard !catalogs.isEmpty else { return [:] }

        let partial = FileManager.default.temporaryDirectory
            .appending(path: "dylkit-actool-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: partial) }
        let arguments = Self.actoolArguments(
            catalogs: catalogs.map(\.path), hasIcon: icon != nil, accentColor: manifest.build.accentColor,
            platform: platform, minimumOS: minimumOS, output: resources.path, partialPlist: partial.path)
        let report = try Shell.capture(arguments, includeStderr: true, allowFailure: true)
        let notices = report.split(separator: "\n").filter { $0.contains("error:") || $0.contains("warning:") }
        for notice in notices { Log.step(String(notice)) }
        guard let plist = InfoPlist.read(partial), !notices.contains(where: { $0.contains("error:") }) else {
            throw ToolError("`\(arguments.joined(separator: " "))` failed:\n\(report)")
        }
        return plist
    }

    static func actoolArguments(
        catalogs: [String], hasIcon: Bool, accentColor: String?, platform: Platform, minimumOS: String,
        output: String, partialPlist: String
    ) -> [String] {
        let groups: [[String]] = [
            ["xcrun", "actool"], catalogs, ["--compile", output], platform.actoolArguments,
            ["--minimum-deployment-target", minimumOS],
            hasIcon ? ["--app-icon", "AppIcon"] : [],
            accentColor.map { ["--accent-color", $0] } ?? [],
            ["--output-partial-info-plist", partialPlist, "--errors", "--warnings"],
            ["--output-format", "human-readable-text"],
        ]
        return groups.flatMap { $0 }
    }
}

/// macOS and iOS 26 draw an app's old design when its binary records an SDK below 26, and Swift Build records the
/// deployment target as the SDK. So builds hand the linker both versions and fail when the binary records another SDK.
extension ResourceCompiler.Platform {
    private var linkerName: String {
        switch self {
        case .macOS: "macos"
        case .iOSSimulator: "ios-simulator"
        }
    }

    /// The installed SDK's version, such as `26.2`.
    ///
    /// - Blocking: runs `xcrun`.
    public func sdkVersion() throws -> String {
        try Shell.capture(["xcrun", "--sdk", sdk, "--show-sdk-version"])
    }

    /// Compiler-driver arguments that make the linker record `minimumOS` and `sdkVersion` in `LC_BUILD_VERSION`.
    public func platformVersionFlags(minimumOS: String, sdkVersion: String) -> [String] {
        ["-platform_version", linkerName, minimumOS, sdkVersion].flatMap { ["-Xlinker", $0] }
    }

    /// Fails unless every slice of `binary` records `sdkVersion`.
    ///
    /// - Blocking: runs `vtool`.
    public static func verifySDK(of binary: URL, sdkVersion: String) throws {
        try verifySDK(
            vtoolOutput: try Shell.capture(["xcrun", "vtool", "-show-build", binary.path]),
            binary: binary.lastPathComponent, sdkVersion: sdkVersion)
    }

    static func verifySDK(vtoolOutput: String, binary: String, sdkVersion: String) throws {
        let recorded = vtoolOutput.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count == 2 && fields[0] == "sdk" ? String(fields[1]) : nil
        }
        guard recorded.isEmpty || recorded.contains(where: { components($0) != components(sdkVersion) }) else { return }
        let found = recorded.isEmpty ? "no SDK" : "SDK \(Set(recorded).sorted().joined(separator: ", "))"
        throw ToolError(
            "\(binary) records \(found) but the installed SDK is \(sdkVersion), so the OS would draw its old design")
    }

    private static func components(_ version: some StringProtocol) -> [Int] {
        var components = version.split(separator: ".").compactMap { Int($0) }
        while components.last == 0 { components.removeLast() }
        return components
    }
}
