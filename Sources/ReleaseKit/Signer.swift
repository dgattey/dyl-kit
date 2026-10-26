import DylToolSupport
import Foundation

/// Signs an app bundle inside-out. Never `--deep`: it re-signs Sparkle's XPC services without their entitlements.
/// Ad-hoc builds pin the designated requirement to the bundle identifier instead of the cdhash, so Sparkle accepts
/// each new build as the same app.
public struct Signer: Sendable {
    public let entitlements: URL
    public let bundleIdentifier: String

    public init(entitlements: URL, bundleIdentifier: String) {
        self.entitlements = entitlements
        self.bundleIdentifier = bundleIdentifier
    }

    private var designatedRequirement: String { "designated => identifier \"\(bundleIdentifier)\"" }

    /// - Blocking: runs `xattr` and `codesign`.
    public func sign(_ app: URL) throws {
        try HostPlatform.requireMacOS("signing \(app.lastPathComponent)")
        let fileManager = FileManager.default
        let macOS = app.appending(path: "Contents/MacOS")
        let resourceBundles = (try? fileManager.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil)) ?? []
        for bundle in resourceBundles.sorted(by: { $0.path < $1.path }) where bundle.pathExtension == "bundle" {
            try codesign([bundle.path])
        }

        // Quarantine and provenance attributes from downloads must not be sealed into the signature.
        try Shell.run(["xattr", "-cr", app.path], allowFailure: true)

        let frameworksDir = app.appending(path: "Contents/Frameworks")
        let frameworks =
            (try? fileManager.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil)) ?? []
        for framework in frameworks.sorted(by: { $0.path < $1.path }) where framework.pathExtension == "framework" {
            try signFramework(framework)
        }

        let plugInsDir = app.appending(path: "Contents/PlugIns")
        let plugIns = (try? fileManager.contentsOfDirectory(at: plugInsDir, includingPropertiesForKeys: nil)) ?? []
        for plugIn in plugIns.sorted(by: { $0.path < $1.path }) {
            try codesign([plugIn.path])
        }

        let outer = ["--entitlements", entitlements.path, "-r=\(designatedRequirement)"]
        try codesign(outer + [app.path])
    }

    /// Nested code first: XPC services (keeping their sandbox entitlements), helper executables and apps, then the
    /// framework itself.
    private func signFramework(_ framework: URL) throws {
        let fileManager = FileManager.default
        let versions = framework.appending(path: "Versions")
        let current = (try? fileManager.destinationOfSymbolicLink(atPath: versions.appending(path: "Current").path))
            .map { versions.appending(path: $0) }
        guard
            let version = current
                ?? (try? fileManager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil))?
                .first(where: { $0.lastPathComponent != "Current" })
        else {
            try codesign([framework.path])
            return
        }
        let xpcDir = version.appending(path: "XPCServices")
        let services = (try? fileManager.contentsOfDirectory(at: xpcDir, includingPropertiesForKeys: nil)) ?? []
        for service in services.sorted(by: { $0.path < $1.path }) where service.pathExtension == "xpc" {
            try codesign(["--preserve-metadata=entitlements", service.path])
        }
        let frameworkBinary = framework.deletingPathExtension().lastPathComponent
        let entries = (try? fileManager.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let name = entry.lastPathComponent
            if entry.pathExtension == "app" || (name != frameworkBinary && isExecutableFile(entry)) {
                try codesign([entry.path])
            }
        }
        try codesign([framework.path])
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func codesign(_ arguments: [String]) throws {
        try Shell.run(["codesign", "--force", "--sign", "-"] + arguments)
    }

    /// Strict verification plus the pinned designated requirement Sparkle relies on.
    ///
    /// - Blocking: runs `codesign`.
    public func verify(_ app: URL) throws {
        try Shell.run(["codesign", "--verify", "--deep", "--strict", app.path])
        let requirement = try Self.designatedRequirement(of: app)
        guard requirement.contains("identifier \"\(bundleIdentifier)\"") else {
            throw ToolError("designated requirement is `\(requirement)`, expected `\(designatedRequirement)`")
        }
    }

    /// - Blocking: runs `codesign`.
    private static func designatedRequirement(of app: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codesign", "-d", "-r-", app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return output.split(separator: "\n").first { $0.hasPrefix("designated") }.map(String.init) ?? output
    }
}
