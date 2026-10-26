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
    /// Other sites can embed `icon.png` (1024) and `apple-touch-icon.png` (180), so keep those two.
    public static let all: [Icon] = [
        Icon(stem: "icon", source: .macOS(.light), format: .png(pixels: 1024)),
        Icon(stem: "icon-256", source: .macOS(.light), format: .png(pixels: 256)),
        Icon(stem: "icon-256-dark", source: .macOS(.dark), format: .png(pixels: 256)),
        Icon(stem: "apple-touch-icon", source: .fullBleedIOS, format: .png(pixels: 180)),
        Icon(stem: "favicon", source: .macOS(.light), format: .ico(pixels: [16, 32])),
        Icon(stem: "favicon-dark", source: .macOS(.dark), format: .ico(pixels: [16, 32])),
    ]

    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// Removes and recreates `directory` with one file per `all`.
    ///
    /// - Blocking: runs ictool, actool and sips.
    public func write(into directory: URL) throws {
        let icon = try requireIcon()
        let ictool = try iconComposer()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-site-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fullBleed = try compileFullBleed(icon, into: scratch)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func render(_ source: Source, pixels: Int, to output: URL) throws {
            let size = String(pixels)
            switch source {
            case .macOS(let rendition):
                try Shell.runQuietly([
                    ictool.path, icon.path, "--export-image", "--output-file", output.path, "--platform", "macOS",
                    "--rendition", rendition.rawValue, "--width", size, "--height", size, "--scale", "1",
                ])
            case .fullBleedIOS:
                try Shell.runQuietly(
                    ["sips", "-s", "format", "png", "-z", size, size, fullBleed.path, "--out", output.path])
            }
        }
        for row in Self.all {
            let output = directory.appending(path: row.name)
            switch row.format {
            case .png(let pixels):
                try render(row.source, pixels: pixels, to: output)
            case .ico(let sizes):
                let pngs: [(size: Int, data: Data)] = try sizes.map { size in
                    let png = scratch.appending(path: "\(row.stem)-\(size).png")
                    try render(row.source, pixels: size, to: png)
                    return (size, try Data(contentsOf: png))
                }
                try Self.ico(pngs: pngs).write(to: output)
            }
        }
        Log.step("wrote \(Self.all.map(\.name).joined(separator: ", ")) to \(directory.path)")
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

    /// actool's largest loose iOS icon, 152 px; it never writes a 180 px one, so `sips` resamples this.
    private func compileFullBleed(_ icon: URL, into scratch: URL) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Shell.runQuietly([
            "xcrun", "actool", icon.path, "--compile", scratch.path, "--platform", "iphoneos",
            "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", "17.0",
            "--app-icon", "AppIcon", "--output-partial-info-plist", scratch.appending(path: "partial.plist").path,
            "--errors", "--warnings",
        ])
        let png = scratch.appending(path: "AppIcon76x76@2x~ipad.png")
        guard FileManager.default.fileExists(atPath: png.path) else {
            throw ToolError("actool wrote no \(png.lastPathComponent)")
        }
        return png
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
