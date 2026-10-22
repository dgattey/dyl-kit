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
        subcommands: [Build.self, Relaunch.self, Capture.self, IOS.self, Sync.self, Checks.self, Verify.self]
    )
}

extension Bundler.Configuration: ExpressibleByArgument {}

extension LaunchOptions.Appearance: ExpressibleByArgument {}

struct LaunchArguments: ParsableArguments {
    @Option(help: "Render the app light or dark: just this process (or the simulator), never the Mac's setting.")
    var appearance: LaunchOptions.Appearance?
    @Option(help: "The view the app opens on, read by the app through LaunchOverrides.current.initialView.")
    var initialView: String?
    @Option(help: "The window size in points, <width>x<height>, applied by AppWindow.") var windowSize: String?

    var options: LaunchOptions {
        LaunchOptions(appearance: appearance, initialView: initialView, windowSize: windowSize)
    }
}

struct SettleArguments: ParsableArguments {
    @Option(help: "The most seconds to wait for the screen to stop changing before capturing anyway.")
    var settle: Double = 20

    var wait: SettleWait { SettleWait(timeout: .milliseconds(Int(settle * 1000))) }
}

extension DevKitCommand {
    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Bundle and ad-hoc sign build/<App> Dev.app.")

        @Argument(help: "debug or release.") var configuration: Bundler.Configuration = .debug

        func run() throws {
            print(try DevBuild(workspace: try Workspace.locate()).build(configuration: configuration).path)
        }
    }

    struct Relaunch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build, stop the build/ copy if it's running, and open it in the background.")

        @OptionGroup var launch: LaunchArguments
        @Option(help: "debug or release.") var configuration: Bundler.Configuration = .debug
        @Flag(help: "Relaunch the existing build without rebuilding.") var noBuild = false

        func run() async throws {
            let workspace = try Workspace.locate()
            let builder = DevBuild(workspace: workspace)
            let app = noBuild ? builder.appURL : try builder.build(configuration: configuration)
            try await Launcher(workspace: workspace).launch(app, options: launch.options)
        }
    }

    struct Capture: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Relaunch in the background and screenshot the main window into build/captures.")

        @OptionGroup var launch: LaunchArguments
        @OptionGroup var settle: SettleArguments
        @Flag(help: "Capture the existing build without rebuilding.") var noBuild = false

        func run() async throws {
            let workspace = try Workspace.locate()
            let builder = DevBuild(workspace: workspace)
            let app = noBuild ? builder.appURL : try builder.build(configuration: .debug)
            let pid = try await Launcher(workspace: workspace).launch(app, options: launch.options)
            let capture = WindowCapture(workspace: workspace)
            let label = [launch.appearance?.rawValue, launch.initialView].compactMap { $0 }.joined(separator: "-")
            let url = capture.defaultOutput(label: label.isEmpty ? nil : label)
            print(try await capture.capture(pid: pid, to: url, settle: settle.wait).path)
        }
    }

    struct IOS: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ios",
            abstract: "Build for the iOS Simulator; --run installs and launches it headless, --capture screenshots it.")

        @OptionGroup var launch: LaunchArguments
        @Flag(help: "Boot the simulator without Simulator.app, install and launch.") var run = false
        @Flag(help: "With --run, screenshot the simulator into build/captures.") var capture = false
        @OptionGroup var settle: SettleArguments
        @Option(help: "The simulator, such as an iPad; defaults to [ios] simulator.") var simulator: String?

        func run() async throws {
            let workspace = try Workspace.locate()
            let ios = IOSBuild(workspace: workspace)
            print(try ios.build().path)
            guard run || capture else { return }
            let udid = try ios.run(options: launch.options, simulator: simulator)
            guard capture else { return }
            let label = ["ios", launch.appearance?.rawValue, launch.initialView].compactMap { $0 }.joined(separator: "-")
            let output = WindowCapture(workspace: workspace).defaultOutput(label: label)
            try await ios.screenshot(udid: udid, to: output, settle: settle.wait)
            print(output.path)
        }
    }

    struct Sync: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write ./run, the pr-check and release workflows and the PR template as this DylKit version ships them.")

        func run() throws {
            let changed = try SharedFiles.sync(root: try Workspace.locate().root)
            Log.step(changed.isEmpty ? "shared files: up to date" : "shared files: wrote \(changed.joined(separator: ", "))")
        }
    }

    struct Checks: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manifest, SwiftLint (tier 1), dyl-lint (tier 2) and release checks (tier 3).")

        func run() throws {
            guard DevKitCore.Checks(workspace: try Workspace.locate()).run() else { throw ExitCode.failure }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "What macOS CI runs on every PR: checks, build and tests.")

        func run() throws {
            try DevKitCore.Checks(workspace: try Workspace.locate()).verify()
        }
    }
}
