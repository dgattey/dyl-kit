import DylCore
import Foundation
import Testing

@testable import DevKitCore

@Suite struct LaunchOptionsTests {
    @Test func everyLaunchTellsTheAppToStayInTheBackground() {
        let environment = LaunchOptions(appearance: .dark).environment
        #expect(environment["DYLKIT_BACKGROUND"] == "1")
        #expect(environment["DYLKIT_APPEARANCE"] == "dark")
        #expect(LaunchOverrides(environment: environment, arguments: []).staysInBackground)
    }

    /// Photos: no app reads the overrides itself, so devkit sets prefix-free names and the appearance per process.
    @Test func appearanceIsAppliedToTheProcessNotTheSystem() {
        let app = URL(fileURLWithPath: "/tmp/build/Sample Dev.app")
        #expect(
            Launcher.openArguments(app, options: LaunchOptions(appearance: .light, windowSize: "800x600")) == [
                "open", "-g", "--env", "DYLKIT_APPEARANCE=light", "--env", "DYLKIT_BACKGROUND=1", "--env",
                "DYLKIT_WINDOW_SIZE=800x600", app.path, "--args", "-NSRequiresAquaSystemAppearance", "YES",
            ])
        #expect(LaunchOptions(appearance: .dark).arguments.starts(with: ["-AppleInterfaceStyle", "Dark"]))
        #expect(Launcher.openArguments(app, options: LaunchOptions()).last == app.path)
    }

    @Test func overridesReadDevkitNamesThenTheAppPrefixThenArguments() {
        enum Screen: String { case group, living }
        let devkit = LaunchOverrides(environment: ["DYLKIT_INITIAL_VIEW": "Living"], arguments: [])
        #expect(devkit.initialView(as: Screen.self) == .living)
        let script = LaunchOverrides(prefix: "SCONEOS", environment: ["SCONEOS_INITIAL_VIEW": "group"], arguments: [])
        #expect(script.initialView(as: Screen.self) == .group)
        let both = LaunchOverrides(
            prefix: "SCONEOS", environment: ["DYLKIT_APPEARANCE": "dark", "SCONEOS_APPEARANCE": "light"], arguments: [])
        #expect(both.appearance == .dark)
        let flags = LaunchOverrides(environment: [:], arguments: ["--initial-view", "nowhere", "--window-size=10x20"])
        #expect(flags.initialView(as: Screen.self) == nil)
        #expect(flags.windowSize == CGSize(width: 10, height: 20))
    }
}
