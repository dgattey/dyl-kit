import Testing

@testable import DylUpdates

#if os(macOS)
import Sparkle
#endif

@MainActor
@Suite struct UpdatePresenterTests {
    @Test func foundUpdatesComeForwardInFocusAndUpToDateChecksStaySilent() {
        var calls: [String] = []
        let presenter = UpdatePresenter(
            activateApp: { calls.append("activate") },
            showUpdateInFocus: { calls.append("showInFocus") }
        )
        #expect(!UpdatePresenter.sparkleShowsScheduledUpdates)

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
    #endif
}
