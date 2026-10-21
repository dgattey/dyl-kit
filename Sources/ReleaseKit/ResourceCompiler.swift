import DylToolSupport
import Foundation

/// Compiles what SwiftPM's command-line build only copies: the manifest's Core Data models (`momc`, `mapc`), and its
/// asset catalogs plus the app icon in one `actool` call. Any failure fails the build, so a missing icon or model
/// never ships silently.
public struct ResourceCompiler: Sendable {
    public enum Platform: Sendable {
        case macOS, iOSSimulator, iOS

        var actoolArguments: [String] {
            switch self {
            case .macOS: ["--platform", "macosx"]
            case .iOSSimulator: ["--platform", "iphonesimulator", "--target-device", "iphone", "--target-device", "ipad"]
            case .iOS: ["--platform", "iphoneos", "--target-device", "iphone", "--target-device", "ipad"]
            }
        }

        var sdk: String {
            switch self {
            case .macOS: "macosx"
            case .iOSSimulator: "iphonesimulator"
            case .iOS: "iphoneos"
            }
        }

        /// momc has one flag for the device and the simulator.
        var momcTarget: String {
            switch self {
            case .macOS: "--macosx-deployment-target"
            case .iOSSimulator, .iOS: "--iphoneos-deployment-target"
            }
        }
    }

    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// The icon `actool` compiles: the committed `[build] icon`, else what the icon generator wrote to `build/`.
    ///
    /// - Blocking: may run the icon generator.
    public func iconSource() throws -> URL? {
        if let icon = workspace.manifest.build.icon {
            let url = workspace.url(icon)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("[build] icon \(icon) doesn't exist")
            }
            return url
        }
        return try Bundler(workspace: workspace).generateIcons()
    }

    /// Compiles into `resources` and returns `actool`'s partial Info.plist (empty when there's no catalog or icon).
    ///
    /// - Blocking: runs `momc`, `mapc` and `actool`.
    public func compile(into resources: URL, platform: Platform, minimumOS: String) throws -> Plist {
        let manifest = workspace.manifest
        let sources = manifest.build.resources.map(workspace.url)
        for source in sources where !FileManager.default.fileExists(atPath: source.path) {
            throw ToolError("[build] resources: \(source.path) doesn't exist")
        }
        let icon = try iconSource()
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
        return try Self.runActool(arguments, partialPlist: partial)
    }

    /// Runs `actool`, showing only its warnings and errors rather than every file it compiled, and returns the
    /// partial Info.plist it wrote.
    ///
    /// - Blocking: runs `actool`.
    public static func runActool(_ arguments: [String], partialPlist: URL) throws -> Plist {
        let report = try Shell.capture(arguments, includeStderr: true, allowFailure: true)
        let notices = report.split(separator: "\n").filter { $0.contains("error:") || $0.contains("warning:") }
        for notice in notices { Log.step(String(notice)) }
        guard let plist = InfoPlist.read(partialPlist), !notices.contains(where: { $0.contains("error:") }) else {
            throw ToolError("`\(arguments.joined(separator: " "))` failed:\n\(report)")
        }
        return plist
    }

    public static func actoolArguments(
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
