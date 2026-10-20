import ArgumentParser
import DevKitCore
import DylToolSupport
import Foundation
import ReleaseKit

@main
struct DevKitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devkit",
        abstract: "Build, relaunch and capture the app in build/, and run every check a PR needs.",
        discussion: "Nothing here touches /Applications, steals focus or changes the system appearance.",
        subcommands: [
            Build.self, Relaunch.self, Capture.self, IOS.self, Checks.self, Verify.self, Bootstrap.self, Clean.self,
            Manifest.self, Skills.self,
        ]
    )
}

struct RootOption: ParsableArguments {
    @Option(help: "The app repo (the directory with DylApp.toml). Defaults to the nearest ancestor that has one.")
    var root: String?

    func workspace() throws -> Workspace { try Workspace.locate(root) }
}

extension Bundler.Configuration: ExpressibleByArgument {}

enum AppearanceChoice: String, ExpressibleByArgument, CaseIterable {
    case light, dark
}

struct LaunchArguments: ParsableArguments {
    @Option(help: "Render the app light or dark (the app applies it to itself, not the system).")
    var appearance: AppearanceChoice?
    @Option(help: "The view the app opens on.") var initialView: String?
    @Option(help: "The window size in points, <width>x<height>.") var windowSize: String?

    var options: LaunchOptions {
        LaunchOptions(appearance: appearance?.rawValue, initialView: initialView, windowSize: windowSize)
    }
}

extension DevKitCommand {
    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Bundle and ad-hoc sign build/<App>.app.")

        @OptionGroup var root: RootOption
        @Argument(help: "debug or release.") var configuration: Bundler.Configuration = .debug

        func run() throws {
            print(try DevBuild(workspace: try root.workspace()).build(configuration: configuration).path)
        }
    }

    struct Relaunch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build, stop the build/ copy if it's running, and open it in the background.")

        @OptionGroup var root: RootOption
        @OptionGroup var launch: LaunchArguments
        @Option(help: "debug or release.") var configuration: Bundler.Configuration = .debug
        @Flag(help: "Relaunch the existing build without rebuilding.") var noBuild = false

        func run() async throws {
            let workspace = try root.workspace()
            let builder = DevBuild(workspace: workspace)
            let app = noBuild ? builder.appURL : try builder.build(configuration: configuration)
            try await Launcher(workspace: workspace).launch(app, options: launch.options)
        }
    }

    struct Capture: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Relaunch in the background and screenshot the main window into build/captures.")

        @OptionGroup var root: RootOption
        @OptionGroup var launch: LaunchArguments
        @Option(help: "debug or release.") var configuration: Bundler.Configuration = .debug
        @Flag(help: "Capture the existing build without rebuilding.") var noBuild = false
        @Option(help: "Where to write the PNG; defaults to a timestamped file in build/captures.") var output: String?
        @Option(help: "Seconds to let the window settle before capturing.") var settle: Double = 2

        func run() async throws {
            let workspace = try root.workspace()
            let builder = DevBuild(workspace: workspace)
            let app = noBuild ? builder.appURL : try builder.build(configuration: configuration)
            let pid = try await Launcher(workspace: workspace).launch(app, options: launch.options)
            let capture = WindowCapture(workspace: workspace)
            let label = [launch.appearance?.rawValue, launch.initialView].compactMap { $0 }.joined(separator: "-")
            let url =
                output.map { URL(fileURLWithPath: $0) } ?? capture.defaultOutput(label: label.isEmpty ? nil : label)
            print(try await capture.capture(pid: pid, to: url, settle: .milliseconds(Int(settle * 1000))).path)
        }
    }

    struct IOS: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ios",
            abstract: "Build for the iOS Simulator; --run installs and launches it headless, --capture screenshots it.")

        @OptionGroup var root: RootOption
        @OptionGroup var launch: LaunchArguments
        @Flag(help: "Boot the simulator without Simulator.app, install and launch.") var run = false
        @Flag(help: "With --run, screenshot the simulator into build/captures.") var capture = false
        @Option(help: "The simulator name; defaults to [ios] simulator.") var simulator: String?

        func run() async throws {
            let workspace = try root.workspace()
            let ios = IOSBuild(workspace: workspace)
            print(try ios.build().path)
            guard run || capture else { return }
            let udid = try ios.run(options: launch.options, simulator: simulator)
            guard capture else { return }
            try await Task.sleep(for: .seconds(3))
            let label = ["ios", launch.appearance?.rawValue].compactMap { $0 }.joined(separator: "-")
            let output = WindowCapture(workspace: workspace).defaultOutput(label: label)
            try ios.screenshot(udid: udid, to: output)
            print(output.path)
        }
    }

    struct Checks: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manifest, SwiftLint (tier 1), dyl-lint (tier 2) and release checks (tier 3).")

        @OptionGroup var root: RootOption

        func run() throws {
            guard DevKitCore.Checks(workspace: try root.workspace()).run() else { throw ExitCode.failure }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "What CI runs on every PR: checks, build, tests, and the site's typecheck and tests.")

        @OptionGroup var root: RootOption

        func run() throws {
            try DevKitCore.Checks(workspace: try root.workspace()).verify()
        }
    }

    struct Bootstrap: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resolve packages, generate icons and install the pre-push hook.")

        @OptionGroup var root: RootOption

        func run() throws {
            try DevKitCore.Bootstrap(workspace: try root.workspace()).run()
        }
    }

    struct Clean: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove build/ (and .build with --all).")

        @OptionGroup var root: RootOption
        @Flag(help: "Also remove SwiftPM's .build directories.") var all = false

        func run() throws {
            try DevKitCore.Clean.run(workspace: try root.workspace(), all: all)
        }
    }

    struct Manifest: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate DylApp.toml, or print one value for scripts and CI wrappers.",
            subcommands: [ManifestCheck.self, ManifestGet.self]
        )
    }

    struct ManifestCheck: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Validate DylApp.toml.")

        @OptionGroup var root: RootOption

        func run() throws {
            let workspace = try root.workspace()
            print("\(workspace.url("DylApp.toml").path): OK")
        }
    }

    struct ManifestGet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get", abstract: "Print a value by dotted key, e.g. app.name or release.site-url.")

        @OptionGroup var root: RootOption
        @Argument(help: "The dotted key.") var key: String

        func run() throws {
            guard let value = try root.workspace().table.value(at: key) else {
                throw ToolError("DylApp.toml has no \(key)")
            }
            print(value.plainText)
        }
    }

    struct Skills: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "DylKit's agent skills and rules.", subcommands: [SkillsSyncCommand.self])
    }

    struct SkillsSyncCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync", abstract: "Copy DylKit's skills and rules into .cursor/.")

        @OptionGroup var root: RootOption
        @Flag(help: "Only report files that differ from DylKit's copies.") var check = false

        func run() throws {
            let stale = try AgentAssets.sync(workspace: try root.workspace(), check: check)
            if check, !stale.isEmpty {
                for path in stale {
                    FileHandle.standardError.write(Data("\(path) differs; run `./run dev skills sync`\n".utf8))
                }
                throw ExitCode.failure
            }
        }
    }
}
