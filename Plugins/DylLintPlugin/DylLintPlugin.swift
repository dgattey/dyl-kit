import Foundation
import PackagePlugin

/// Runs `dyl-lint` over every Swift source in the target on each build. Diagnostics use the compiler's
/// `file:line:col: warning|error:` format, so Xcode and `swift build` show them inline and errors fail the build.
@main
struct DylLintPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let sources = target.sourceFiles(withSuffix: "swift").map(\.url)
        guard !sources.isEmpty else { return [] }
        let stamp = context.pluginWorkDirectoryURL.appending(path: "\(target.name).dyl-lint.stamp")
        return [
            .buildCommand(
                displayName: "dyl-lint \(target.name)",
                executable: try context.tool(named: "dyl-lint").url,
                arguments: ["--stamp", stamp.path] + sources.map(\.path),
                inputFiles: sources,
                outputFiles: [stamp]
            )
        ]
    }
}
