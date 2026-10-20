import Foundation
import PackagePlugin

/// `swift package dev <subcommand>` forwards to `devkit`. Agents and CI call the `./run` shim instead, which
/// skips the plugin sandbox.
@main
struct DevCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = try context.tool(named: "devkit").url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["DYLKIT_ROOT": context.package.directoryURL.path]
        ) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DevFailure(status: process.terminationStatus)
        }
    }

    struct DevFailure: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "devkit exited with status \(status)" }
    }
}
