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

    /// Sconeos at v0.3.0: linked against the macOS 27 SDK, the window only opened after a second `open -g`.
    @Test func theReopenStaysInTheBackground() {
        let app = URL(fileURLWithPath: "/tmp/build/Sample Dev.app")
        #expect(Launcher.reopenArguments(app) == ["open", "-g", app.path])
    }

    /// Sconeos: `relaunch` left no window. An old copy that outlives the stop must not stand in for the new launch.
    @Test func aLaunchNeverTakesTheOldCopysPid() {
        #expect(Launcher.newPid([25600, 25673], excluding: [25600]) == 25673)
        #expect(Launcher.newPid([25600], excluding: [25600]) == nil)
        #expect(Launcher.newPid([], excluding: []) == nil)
    }

    @Test func overridesReadDevkitVariablesThenArguments() {
        let devkit = LaunchOverrides(environment: ["DYLKIT_INITIAL_VIEW": "Living"], arguments: [])
        #expect(devkit.initialView == "living")
        let appPrefixed = LaunchOverrides(environment: ["SCONEOS_INITIAL_VIEW": "group"], arguments: [])
        #expect(appPrefixed.initialView == nil)
        let both = LaunchOverrides(environment: ["DYLKIT_APPEARANCE": "dark"], arguments: ["--appearance=light"])
        #expect(both.appearance == .dark)
        let flags = LaunchOverrides(environment: [:], arguments: ["--initial-view", "nowhere", "--window-size=10x20"])
        #expect(flags.initialView == "nowhere")
        #expect(flags.windowSize == CGSize(width: 10, height: 20))
    }
}
