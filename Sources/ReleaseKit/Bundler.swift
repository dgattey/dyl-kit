import DylToolSupport
import Foundation

/// Builds the SwiftPM product and assembles `<App>.app`: binary with bundle-relative rpaths only, SwiftPM resource
/// bundles, embedded frameworks, the dock tile plug-in, icons and the manifest-derived `Info.plist`. Signing is a
/// separate step.
public struct Bundler: Sendable {
    public enum Configuration: String, Sendable, CaseIterable {
        case debug, release
    }

    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// - Blocking: runs `swift build`, the icon generator, `actool` and binary tools.
    @discardableResult
    public func bundle(
        configuration: Configuration, identity: AppIdentity, shortVersion: String, build: String, into directory: URL
    )
        throws -> URL
    {
        let manifest = workspace.manifest
        let product = manifest.build.product
        let fileManager = FileManager.default

        let platform = ResourceCompiler.Platform.macOS
        let sdkVersion = try platform.sdkVersion()
        for name in [product] + [manifest.build.dockTilePlugin?.product].compactMap({ $0 }) {
            Log.step("swift build -c \(configuration.rawValue) --product \(name) (SDK \(sdkVersion))")
            try Shell.run(
                ["swift", "build", "-c", configuration.rawValue, "--product", name]
                    + platform.platformVersionFlags(minimumOS: manifest.app.platforms.macos, sdkVersion: sdkVersion),
                cwd: workspace.root)
        }
        let binDir = URL(
            fileURLWithPath: try Shell.capture(
                ["swift", "build", "-c", configuration.rawValue, "--product", product, "--show-bin-path"],
                cwd: workspace.root
            )
        )
        let binary = binDir.appending(path: product)
        guard fileManager.fileExists(atPath: binary.path) else { throw ToolError("\(binary.path) wasn't built") }
        try ResourceCompiler.Platform.verifySDK(of: binary, sdkVersion: sdkVersion)

        let app = directory.appending(path: "\(identity.name(manifest)).app")
        let contents = app.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        let frameworks = contents.appending(path: "Frameworks")
        try? fileManager.removeItem(at: app)
        for directory in [macOS, resources, frameworks] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let executable = macOS.appending(path: product)
        try fileManager.copyItem(at: binary, to: executable)
        try fixRpaths(executable)

        for bundle in try contentsOfDirectory(binDir) where bundle.pathExtension == "bundle" {
            let destination = macOS.appending(path: bundle.lastPathComponent)
            try fileManager.copyItem(at: bundle, to: destination)
            let hasPlist = ["Info.plist", "Contents/Info.plist"].contains {
                fileManager.fileExists(atPath: destination.appending(path: $0).path)
            }
            if !hasPlist {
                let name = bundle.deletingPathExtension().lastPathComponent
                let plist = InfoPlist.resourceBundle(identifier: "\(identity.bundleId(manifest)).\(name)")
                try InfoPlist.data(plist).write(to: destination.appending(path: "Info.plist"))
            }
        }

        let sparkle = try locateFramework("Sparkle", binDir: binDir)
        try Shell.run(["ditto", sparkle.path, frameworks.appending(path: "Sparkle.framework").path])

        if let plugin = manifest.build.dockTilePlugin {
            let library = binDir.appending(path: "lib\(plugin.product).dylib")
            guard fileManager.fileExists(atPath: library.path) else { throw ToolError("\(library.path) wasn't built") }
            try ResourceCompiler.Platform.verifySDK(of: library, sdkVersion: sdkVersion)
            let pluginContents = contents.appending(path: "PlugIns/\(plugin.bundleName)/Contents")
            try fileManager.createDirectory(
                at: pluginContents.appending(path: "MacOS"), withIntermediateDirectories: true)
            let pluginBinary = pluginContents.appending(path: "MacOS/\(plugin.product)")
            try fileManager.copyItem(at: library, to: pluginBinary)
            try fixRpaths(pluginBinary, addingFrameworks: false)
            let pluginPlist = InfoPlist.dockTilePlugin(
                plugin, manifest: manifest, identity: identity, shortVersion: shortVersion, build: build)
            try InfoPlist.data(pluginPlist).write(to: pluginContents.appending(path: "Info.plist"))
        }

        try copyGeneratedIcns(into: resources)
        let generated = try ResourceCompiler(workspace: workspace)
            .compile(into: resources, platform: .macOS, minimumOS: manifest.app.platforms.macos)

        let publicKey = try? String(contentsOf: workspace.url(manifest.release.sparklePublicKey), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localValues = ResolvedLocalValues.resolve(workspace)
        if manifest.localValues != nil { Log.step(localValues.summary) }
        let plist = InfoPlist.finalizing(
            InfoPlist.contents(
                manifest: manifest, identity: identity, shortVersion: shortVersion, build: build,
                sparklePublicKey: publicKey),
            generated: generated, rawKeys: InfoPlist.rawKeys(manifest, iOS: false), localValues: localValues)
        try InfoPlist.data(plist).write(to: contents.appending(path: "Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appending(path: "PkgInfo"))
        if identity == .release, publicKey == nil {
            Log.warn("\(manifest.release.sparklePublicKey) is missing; the updater stays off")
        }
        return app
    }

    /// Drops absolute build-machine rpaths SwiftPM embeds (an Xcode path that doesn't exist on users' Macs makes
    /// XProtect log rPathCmd failures) and, unless told not to, makes sure `@executable_path/../Frameworks` is present.
    ///
    /// - Blocking: runs `otool` and `install_name_tool`.
    func fixRpaths(_ executable: URL, addingFrameworks: Bool = true) throws {
        let rpaths = try Self.rpaths(of: executable)
        for rpath in rpaths where !Self.isBundleRelative(rpath) {
            try Shell.run(["install_name_tool", "-delete_rpath", rpath, executable.path], allowFailure: true)
        }
        if addingFrameworks, !rpaths.contains("@executable_path/../Frameworks") {
            try Shell.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", executable.path])
        }
    }

    private static func isBundleRelative(_ rpath: String) -> Bool {
        rpath.hasPrefix("@executable_path") || rpath.hasPrefix("@loader_path") || rpath.hasPrefix("/usr/lib/swift")
    }

    /// The `LC_RPATH` entries of a Mach-O binary.
    ///
    /// - Blocking: runs `otool`.
    private static func rpaths(of executable: URL) throws -> [String] {
        let loadCommands = try Shell.capture(["otool", "-l", executable.path])
        var result: [String] = []
        var inRpath = false
        for line in loadCommands.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "cmd LC_RPATH" {
                inRpath = true
            } else if inRpath, trimmed.hasPrefix("path ") {
                result.append(String(trimmed.dropFirst(5).split(separator: " ").first ?? ""))
                inRpath = false
            }
        }
        return result
    }

    private func locateFramework(_ name: String, binDir: URL) throws -> URL {
        var candidates = [binDir.appending(path: "\(name).framework")]
        let xcframework = workspace.url(".build/artifacts/\(name.lowercased())/\(name)/\(name).xcframework")
        for slice in (try? contentsOfDirectory(xcframework)) ?? [] where slice.lastPathComponent.hasPrefix("macos") {
            candidates.append(slice.appending(path: "\(name).framework"))
        }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ToolError("\(name).framework isn't under .build; run `swift build` first")
        }
        return found
    }

    /// Runs the manifest's icon generator when its output is missing or older than the script. Returns the icon
    /// source `actool` compiles (`build/AppIcon.icon`, else `build/Assets.xcassets`), if any.
    ///
    /// - Blocking: runs the generator script.
    public func generateIcons() throws -> URL? {
        let fileManager = FileManager.default
        let buildDir = workspace.buildDir
        let icns = buildDir.appending(path: "AppIcon.icns")
        let iconBundle = buildDir.appending(path: "AppIcon.icon")
        if let generator = workspace.manifest.build.iconGenerator {
            let script = workspace.url(generator)
            let stale =
                !fileManager.fileExists(atPath: icns.path) || !fileManager.fileExists(atPath: iconBundle.path)
                || modificationDate(script) > modificationDate(icns)
            if stale {
                Log.step("generating icons with \(generator)")
                try Shell.run(["swift", script.path, workspace.root.path], cwd: workspace.root)
            }
        }
        return [iconBundle, buildDir.appending(path: "Assets.xcassets")].first {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    /// The light and dark `.icns` an icon generator writes next to its `.icon`, for macOS before 26. `actool` writes
    /// `AppIcon.icns` itself afterwards, over the generator's.
    private func copyGeneratedIcns(into resources: URL) throws {
        guard workspace.manifest.build.iconGenerator != nil else { return }
        let fileManager = FileManager.default
        for name in ["AppIcon.icns", "AppIcon-Light.icns", "AppIcon-Dark.icns"] {
            let source = workspace.buildDir.appending(path: name)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: resources.appending(path: name))
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    private func contentsOfDirectory(_ url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
