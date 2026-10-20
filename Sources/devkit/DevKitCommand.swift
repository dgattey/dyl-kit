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
        subcommands: [Build.self, Relaunch.self, Capture.self, IOS.self, Checks.self, Verify.self]
    )
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
        @Flag(help: "Capture the existing build without rebuilding.") var noBuild = false
        @Option(help: "Seconds to let the window settle before capturing.") var settle: Double = 2

        func run() async throws {
            let workspace = try Workspace.locate()
            let builder = DevBuild(workspace: workspace)
            let app = noBuild ? builder.appURL : try builder.build(configuration: .debug)
            let pid = try await Launcher(workspace: workspace).launch(app, options: launch.options)
            let capture = WindowCapture(workspace: workspace)
            let label = [launch.appearance?.rawValue, launch.initialView].compactMap { $0 }.joined(separator: "-")
            let url = capture.defaultOutput(label: label.isEmpty ? nil : label)
            print(try await capture.capture(pid: pid, to: url, settle: .milliseconds(Int(settle * 1000))).path)
        }
    }

    struct IOS: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ios",
            abstract: "Build for the iOS Simulator; --run installs and launches it headless, --capture screenshots it.")

        @OptionGroup var launch: LaunchArguments
        @Flag(help: "Boot the simulator without Simulator.app, install and launch.") var run = false
        @Flag(help: "With --run, screenshot the simulator into build/captures.") var capture = false
        @Option(help: "The simulator, such as an iPad; defaults to [ios] simulator.") var simulator: String?

        func run() async throws {
            let workspace = try Workspace.locate()
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
