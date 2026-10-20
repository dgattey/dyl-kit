import Foundation
import PackagePlugin

/// `swift package release <subcommand>` forwards to `release-kit`.
@main
struct ReleaseCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = try context.tool(named: "release-kit").url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["DYLKIT_ROOT": context.package.directoryURL.path]
        ) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReleaseFailure(status: process.terminationStatus)
        }
    }

    struct ReleaseFailure: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "release-kit exited with status \(status)" }
    }
}
