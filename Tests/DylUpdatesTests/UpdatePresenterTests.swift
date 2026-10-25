import DylCore
import Foundation
import Testing

@testable import DylUpdates

#if os(macOS)
import Sparkle
#endif

@MainActor
@Suite struct UpdatePresenterTests {
    @Test func onlyAnInstalledReleaseMayTakeFocus() {
        let release = AppInfo { ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"][$0] }
        let dev = AppInfo { _ in nil }
        let installed = URL(filePath: "/Applications/Demo.app")
        let userInstalled = URL(filePath: "/Users/me/Applications/Demo.app")
        let devBuild = URL(filePath: "/Users/me/repos/demo/build/Demo.app")
        let quiet = LaunchOverrides(environment: [:], arguments: [])
        let devkit = LaunchOverrides(environment: ["DYLKIT_BACKGROUND": "1"], arguments: [])
        let agentArgs = LaunchOverrides(environment: [:], arguments: ["--background"])

        #expect(UpdatePresenter.mayActivate(app: release, bundleURL: installed, launch: quiet))
        #expect(UpdatePresenter.mayActivate(app: release, bundleURL: userInstalled, launch: quiet))
        #expect(!UpdatePresenter.mayActivate(app: release, bundleURL: devBuild, launch: quiet))
        #expect(!UpdatePresenter.mayActivate(app: dev, bundleURL: installed, launch: quiet))
        #expect(!UpdatePresenter.mayActivate(app: release, bundleURL: installed, launch: devkit))
        #expect(!UpdatePresenter.mayActivate(app: release, bundleURL: installed, launch: agentArgs))
        // This test process is a runner, not an installed release.
        #expect(!UpdatePresenter.mayActivate(app: .main, bundleURL: Bundle.main.bundleURL, launch: quiet))
    }

    @Test func aFoundUpdateNeverActivatesUntilAllowed() {
        var calls: [String] = []
        let presenter = UpdatePresenter(
            activateApp: { calls.append("activate") },
            showUpdateInFocus: { calls.append("showInFocus") }
        )
        presenter.willShowUpdate(handledBySparkle: false)
        presenter.sessionEnded()
        presenter.willShowUpdate(handledBySparkle: true)
        #expect(calls == ["showInFocus"])
    }

    @Test func foundUpdatesComeForwardInFocusAndUpToDateChecksStaySilent() {
        var calls: [String] = []
        let presenter = UpdatePresenter(
            activateApp: { calls.append("activate") },
            showUpdateInFocus: { calls.append("showInFocus") }
        )
        presenter.mayActivate = true

        // A background check that finds nothing only ends its session.
        presenter.sessionEnded()
        #expect(calls.isEmpty)
        #expect(!presenter.blocksQuit)

        // A launch or scheduled check found one: Sparkle deferred it, so bring the app forward and show it in focus.
        presenter.willShowUpdate(handledBySparkle: false)
        #expect(calls == ["activate", "showInFocus"])
        #expect(presenter.blocksQuit)
        presenter.sessionEnded()
        #expect(!presenter.blocksQuit)

        // A user's check: Sparkle shows the alert itself.
        calls.removeAll()
        presenter.willShowUpdate(handledBySparkle: true)
        #expect(calls == ["activate"])
        presenter.sessionEnded()

        presenter.willInstallUpdate()
        #expect(presenter.blocksQuit)
    }

    @Test func launchCheckWaitsForSparkleAndRunsOnce() {
        let presenter = UpdatePresenter(activateApp: {}, showUpdateInFocus: {})
        #expect(!presenter.takeLaunchCheck(canCheck: true, sessionInProgress: false), "not before the window appears")

        presenter.requestLaunchCheck()
        #expect(!presenter.takeLaunchCheck(canCheck: false, sessionInProgress: false), "Sparkle isn't ready yet")
        #expect(presenter.takeLaunchCheck(canCheck: true, sessionInProgress: false))
        #expect(!presenter.takeLaunchCheck(canCheck: true, sessionInProgress: false))

        presenter.requestLaunchCheck()
        #expect(!presenter.takeLaunchCheck(canCheck: true, sessionInProgress: false), "a second window doesn't re-check")
    }

    @Test func checksAlreadyUnderwayCountAsTheLaunchCheck() {
        let scheduled = UpdatePresenter(activateApp: {}, showUpdateInFocus: {})
        scheduled.requestLaunchCheck()
        #expect(!scheduled.takeLaunchCheck(canCheck: false, sessionInProgress: true))
        #expect(!scheduled.takeLaunchCheck(canCheck: true, sessionInProgress: false))

        let shown = UpdatePresenter(activateApp: {}, showUpdateInFocus: {})
        shown.willShowUpdate(handledBySparkle: false)
        shown.requestLaunchCheck()
        #expect(!shown.takeLaunchCheck(canCheck: true, sessionInProgress: false))
    }

    #if os(macOS)
    @Test func sparkleHandsScheduledUpdatesToThePresenter() {
        let delegate = UserDriverDelegate()
        #expect(delegate.supportsGentleScheduledUpdateReminders)
        for immediateFocus in [true, false] {
            #expect(
                !delegate.standardUserDriverShouldHandleShowingScheduledUpdate(
                    .empty(), andInImmediateFocus: immediateFocus))
        }
    }

    /// A `checkForUpdates` made while Sparkle is still finding the update is dropped, so only the
    /// deferred `willShowUpdate` may re-run it, and an aborted session must not leave quit blocked.
    @Test func onlyTheDeferredShowReRunsTheCheck() {
        var shownInFocus = 0
        let presenter = UpdatePresenter(activateApp: {}, showUpdateInFocus: { shownInFocus += 1 })
        let updaterDelegate = UpdaterDelegate()
        updaterDelegate.presenter = presenter
        let updater = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        ).updater

        updaterDelegate.updater(updater, didFindValidUpdate: .empty())
        #expect(shownInFocus == 0)
        presenter.willShowUpdate(handledBySparkle: false)
        #expect(shownInFocus == 1)
        #expect(presenter.blocksQuit)

        updaterDelegate.updater(updater, didAbortWithError: NSError(domain: "SparkleTest", code: 1))
        #expect(!presenter.blocksQuit)
        #expect(shownInFocus == 1)
    }
    #endif
}
