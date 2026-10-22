import DylToolSupport
import Foundation

/// Icons render at release from the icon the app ships and upload to the store's `icons/`. `@dylkit/web` serves
/// them. Nothing is committed, so they can't drift.
public struct SiteIcons: Sendable {
    public enum Source: Equatable, Sendable {
        /// Icon Composer's render of the macOS icon: the squircle edge to edge, transparent corners.
        case macOS(Rendition)
        /// actool's opaque full-bleed iPhone/iPad icon, which iOS masks itself. Transparent corners would show black.
        case fullBleedIOS
    }

    /// ictool's `--rendition` names.
    public enum Rendition: String, Equatable, Sendable {
        case light = "Default"
        case dark = "Dark"
    }

    public enum Format: Equatable, Sendable {
        case png(pixels: Int)
        case ico(pixels: [Int])
    }

    public struct Icon: Sendable {
        public let stem: String
        public let source: Source
        public let format: Format

        public var name: String {
            switch format {
            case .png: stem + ".png"
            case .ico: stem + ".ico"
            }
        }
    }

    /// Every icon the site serves at `/icons/<name>`. A new row is live there after the next release.
    /// dylangattey.com reads `icon.png` (1024) and `apple-touch-icon.png` (180), so keep those two.
    public static let all: [Icon] = [
        Icon(stem: "icon", source: .macOS(.light), format: .png(pixels: 1024)),
        Icon(stem: "icon-dark", source: .macOS(.dark), format: .png(pixels: 1024)),
        Icon(stem: "icon-256", source: .macOS(.light), format: .png(pixels: 256)),
        Icon(stem: "icon-256-dark", source: .macOS(.dark), format: .png(pixels: 256)),
        Icon(stem: "apple-touch-icon", source: .fullBleedIOS, format: .png(pixels: 180)),
        Icon(stem: "favicon", source: .macOS(.light), format: .ico(pixels: [16, 32])),
        Icon(stem: "favicon-dark", source: .macOS(.dark), format: .ico(pixels: [16, 32])),
    ]

    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// Removes and recreates `directory` with one file per `all`, in that order.
    ///
    /// - Blocking: runs ictool, actool and sips.
    public func write(into directory: URL) throws -> [URL] {
        let icon = try requireIcon()
        let ictool = try iconComposer()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-site-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var fullBleed: URL?
        var written: [URL] = []
        for row in Self.all {
            switch row.format {
            case .png(let pixels):
                let output = directory.appending(path: row.name)
                written.append(
                    try render(
                        row.source, pixels: pixels, icon: icon, ictool: ictool, into: output, scratch: scratch,
                        fullBleed: &fullBleed))
            case .ico(let sizes):
                let pngs: [(size: Int, data: Data)] = try sizes.map { size in
                    let output = scratch.appending(path: "\(row.stem)-\(size).png")
                    _ = try render(
                        row.source, pixels: size, icon: icon, ictool: ictool, into: output, scratch: scratch,
                        fullBleed: &fullBleed)
                    return (size, try Data(contentsOf: output))
                }
                let output = directory.appending(path: row.name)
                try Self.ico(pngs: pngs).write(to: output)
                written.append(output)
            }
        }
        Log.step("wrote \(Self.all.map(\.name).joined(separator: ", ")) to \(directory.path)")
        return written
    }

    private func requireIcon() throws -> URL {
        guard
            let icon = try workspace.manifest.build.icon.map(workspace.url)
                ?? Bundler(workspace: workspace).generateIcons()
        else {
            throw ToolError("no app icon: set [build] icon or [build] icon-generator")
        }
        guard icon.pathExtension == "icon" else {
            throw ToolError("site icons need an Icon Composer .icon, not \(icon.lastPathComponent)")
        }
        return icon
    }

    /// Icon Composer's `ictool`, beside Xcode. `xcrun ictool` is a different binary.
    private func iconComposer() throws -> URL {
        let developer = URL(fileURLWithPath: try Shell.capture(["xcode-select", "-p"]), isDirectory: true)
        let ictool = developer
            .appending(path: "../Applications/Icon Composer.app/Contents/Executables/ictool")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: ictool.path) else {
            throw ToolError("Xcode's Icon Composer is missing at \(ictool.path)")
        }
        return ictool
    }

    /// `fullBleed` caches the one actool compile for this call.
    private func render(
        _ source: Source, pixels: Int, icon: URL, ictool: URL, into output: URL, scratch: URL, fullBleed: inout URL?
    ) throws -> URL {
        switch source {
        case .macOS(let rendition):
            try Shell.run([
                ictool.path, icon.path, "--export-image", "--output-file", output.path, "--platform", "macOS",
                "--rendition", rendition.rawValue, "--width", String(pixels), "--height", String(pixels),
                "--scale", "1",
            ])
        case .fullBleedIOS:
            let sourcePNG: URL
            if let cached = fullBleed {
                sourcePNG = cached
            } else {
                sourcePNG = try compileFullBleed(icon, scratch: scratch)
                fullBleed = sourcePNG
            }
            try Self.resample(sourcePNG, size: pixels, to: output)
        }
        return output
    }

    /// The loose full-bleed sizes don't depend on the deployment target.
    private func compileFullBleed(_ icon: URL, scratch: URL) throws -> URL {
        let compiled = scratch.appending(path: "iphoneos")
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Shell.run([
            "xcrun", "actool", icon.path, "--compile", compiled.path, "--platform", "iphoneos",
            "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", "17.0",
            "--app-icon", "AppIcon", "--output-partial-info-plist", compiled.appending(path: "partial.plist").path,
            "--errors", "--warnings",
        ])
        guard let png = Self.largestFullBleedPNG(in: compiled) else {
            throw ToolError("actool wrote no full-bleed iOS icon")
        }
        return png
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

    private static func resample(_ image: URL, size: Int, to output: URL) throws {
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
