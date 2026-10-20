import Foundation
import PackagePlugin

/// `swift package lint [paths…]`: SwiftLint with the package's shared config, then `dyl-lint`. Defaults to
/// `Sources` and `Tests` under the package root.
@main
struct LintCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let paths =
            arguments.isEmpty
            ? ["Sources", "Tests"].map { root.appending(path: $0).path }.filter {
                FileManager.default.fileExists(atPath: $0)
            }
            : arguments

        var failed = false
        if let swiftlint = try? context.tool(named: "swiftlint") {
            failed = try run(swiftlint.url, ["lint", "--strict", "--quiet"] + paths, in: root) || failed
        } else {
            Diagnostics.warning("swiftlint not found on PATH; skipping tier 1 (install with `brew install swiftlint`)")
        }
        let dylLint = try context.tool(named: "dyl-lint")
        failed = try run(dylLint.url, paths, in: root) || failed
        if failed { throw LintFailure() }
    }

    private func run(_ executable: URL, _ arguments: [String], in directory: URL) throws -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus != 0
    }

    struct LintFailure: Error, CustomStringConvertible {
        var description: String { "lint failed" }
    }
}
