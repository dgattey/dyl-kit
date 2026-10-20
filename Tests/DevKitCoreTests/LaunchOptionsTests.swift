import DylCore
import Testing

@testable import DevKitCore

@Suite struct LaunchOptionsTests {
    @Test func everyLaunchTellsTheAppToStayInTheBackground() {
        let environment = LaunchOptions(appearance: "dark").environment(prefix: "SCONEOS")
        #expect(environment["SCONEOS_BACKGROUND"] == "1")
        #expect(environment["SCONEOS_APPEARANCE"] == "dark")
        #expect(LaunchOverrides(prefix: "SCONEOS", environment: environment, arguments: []).staysInBackground)
    }
}
