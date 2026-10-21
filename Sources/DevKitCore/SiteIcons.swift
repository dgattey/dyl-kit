import DylToolSupport
import Foundation
import ReleaseKit

/// The download site's icons, from the same icon the app ships: a 16+32 px `favicon.ico`, the 256 px rounded
/// `icon.png` from the macOS `.icns`, and the 180 px full-bleed `apple-icon.png` from the icons `actool` compiles
/// for iPhone and iPad.
/// They're committed, because the site builds on Linux, where there's no `actool`.
public struct SiteIcons: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// - Blocking: runs the icon generator, `actool` and `sips`.
    public func write() throws -> URL {
        guard let directory = workspace.manifest.build.siteIcons.map(workspace.url) else {
            throw ToolError("set [build] site-icons to the site's app/ directory")
        }
        guard let icon = try ResourceCompiler(workspace: workspace).iconSource() else {
            throw ToolError("no app icon: set [build] icon or [build] icon-generator")
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-site-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let macOS = scratch.appending(path: "macos")
        let iPhone = scratch.appending(path: "iphoneos")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let icns = try compile(icon, platform: .macOS, minimumOS: workspace.manifest.app.platforms.macos, into: macOS)
            .appending(path: "AppIcon.icns")
        guard FileManager.default.fileExists(atPath: icns.path) else { throw ToolError("actool wrote no AppIcon.icns") }
        try resample(icns, size: 256, to: directory.appending(path: "icon.png"))
        let sizes = [16, 32]
        let pngs = try sizes.map { size in
            let png = scratch.appending(path: "favicon-\(size).png")
            try resample(icns, size: size, to: png)
            return try Data(contentsOf: png)
        }
        try Self.ico(pngs: Array(zip(sizes, pngs))).write(to: directory.appending(path: "favicon.ico"))

        let appleIcon = directory.appending(path: "apple-icon.png")
        let iOSOutput = try compile(
            icon, platform: .iOS, minimumOS: workspace.manifest.app.platforms.ios ?? "17.0", into: iPhone)
        try? FileManager.default.removeItem(at: appleIcon)
        if let fullBleed = Self.largestFullBleedPNG(in: iOSOutput) {
            try resample(fullBleed, size: 180, to: appleIcon)
        } else {
            Log.warn("actool wrote no full-bleed iOS icon; apple-icon.png is the rounded macOS icon")
            try resample(icns, size: 180, to: appleIcon)
        }
        Log.step("wrote \(ReleaseChecks.siteIconNames.joined(separator: ", ")) to \(directory.path)")
        return directory
    }

    private func compile(_ icon: URL, platform: ResourceCompiler.Platform, minimumOS: String, into output: URL)
        throws -> URL
    {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let partial = output.appending(path: "partial.plist")
        _ = try ResourceCompiler.runActool(
            ResourceCompiler.actoolArguments(
                catalogs: [icon.path], hasIcon: true, accentColor: nil, platform: platform, minimumOS: minimumOS,
                output: output.path, partialPlist: partial.path),
            partialPlist: partial)
        return output
    }

    /// actool writes loose iPhone and iPad icons (`AppIcon60x60@2x.png` is 120 px, `AppIcon76x76@2x~ipad.png`
    /// 152 px) but never the 180 px one, so the largest is resampled.
    static func largestFullBleedPNG(in directory: URL) -> URL? {
        let pngs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return pngs.filter { $0.lastPathComponent.hasPrefix("AppIcon") && $0.pathExtension == "png" }
            .max { pixelSize($0.lastPathComponent) < pixelSize($1.lastPathComponent) }
    }

    /// `AppIcon76x76@2x~ipad.png` is 152 px: the point size times the scale.
    static func pixelSize(_ name: String) -> Double {
        let pattern = /AppIcon(\d+(?:\.\d+)?)x\d+(?:\.\d+)?@(\d)x/
        guard let match = name.firstMatch(of: pattern), let points = Double(match.1), let scale = Double(match.2)
        else { return 0 }
        return points * scale
    }

    private func resample(_ image: URL, size: Int, to output: URL) throws {
        try Shell.run([
            "sips", "-s", "format", "png", "-z", String(size), String(size), image.path, "--out", output.path,
        ])
    }

    /// An ICO holding PNG images, which every browser since IE 9 reads, so no image library is needed.
    static func ico(pngs: [(size: Int, data: Data)]) -> Data {
        var data = Data()
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        append16(0)
        append16(1)
        append16(pngs.count)
        var offset = 6 + 16 * pngs.count
        for (size, png) in pngs {
            data.append(UInt8(size >= 256 ? 0 : size))
            data.append(UInt8(size >= 256 ? 0 : size))
            data.append(0)
            data.append(0)
            append16(1)
            append16(32)
            append32(png.count)
            append32(offset)
            offset += png.count
        }
        for (_, png) in pngs { data.append(png) }
        return data
    }
}
