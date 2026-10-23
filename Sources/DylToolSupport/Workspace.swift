import DylManifest
import Foundation

/// An app repo: the directory holding `DylApp.toml`, plus the parsed manifest.
public struct Workspace: Sendable {
    public let root: URL
    public let manifest: DylAppManifest

    public init(root: URL, manifest: DylAppManifest) {
        self.root = root
        self.manifest = manifest
    }

    /// Loads the manifest from `explicitRoot`, else the nearest ancestor of the current directory that has one.
    ///
    /// - Blocking: reads the file system.
    public static func locate(_ explicitRoot: String? = nil) throws -> Workspace {
        let root: URL
        if let explicitRoot {
            root = URL(fileURLWithPath: explicitRoot).standardizedFileURL
        } else {
            var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
            while !FileManager.default.fileExists(atPath: candidate.appending(path: DylAppManifest.fileName).path) {
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else {
                    throw ToolError("no \(DylAppManifest.fileName) in this directory or any parent; pass --root")
                }
                candidate = parent
            }
            root = candidate
        }
        do {
            return Workspace(root: root, manifest: try DylAppManifest.load(root: root))
        } catch {
            throw ToolError(error.description)
        }
    }

    public func url(_ relative: String) -> URL { root.appending(path: relative) }

    /// `build/` in the repo: dev bundles, generated icons and release staging all live under it.
    public var buildDir: URL { url("build") }

    /// Sparkle's command-line tools, which SwiftPM unpacks from the Sparkle binary artifact.
    public func sparkleTool(_ name: String) -> URL {
        url(".build/artifacts/sparkle/Sparkle/bin/\(name)")
    }
}
