import DylShell
import Testing

@testable import DylUpdates

@Suite struct LaunchCheckPlanTests {
    @Test func devBuildsNeverCheck() {
        #expect(
            LaunchCheckPlan.decide(
                isReleaseConfigured: false,
                alreadyScheduled: false,
                sessionInProgress: false,
                canCheckForUpdates: true
            ) == .skip
        )
    }

    @Test func checksOncePerLaunch() {
        #expect(
            LaunchCheckPlan.decide(
                isReleaseConfigured: true,
                alreadyScheduled: true,
                sessionInProgress: false,
                canCheckForUpdates: true
            ) == .skip
        )
    }

    @Test func adoptsTheSchedulersSessionInsteadOfStartingASecond() {
        #expect(
            LaunchCheckPlan.decide(
                isReleaseConfigured: true,
                alreadyScheduled: false,
                sessionInProgress: true,
                canCheckForUpdates: false
            ) == .adoptRunningSession
        )
    }

    @Test func waitsForTheUpdaterToBecomeReady() {
        #expect(
            LaunchCheckPlan.decide(
                isReleaseConfigured: true,
                alreadyScheduled: false,
                sessionInProgress: false,
                canCheckForUpdates: false
            ) == .waitUntilReady
        )
        #expect(
            LaunchCheckPlan.decide(
                isReleaseConfigured: true,
                alreadyScheduled: false,
                sessionInProgress: false,
                canCheckForUpdates: true
            ) == .checkNow
        )
    }
}

@Suite @MainActor struct QuitBlockersTests {
    @Test func nestedSessionsBlockUntilTheLastEnds() {
        let blockers = QuitBlockers()
        #expect(blockers.shouldTerminateAfterLastWindowClosed)
        blockers.begin()
        blockers.begin()
        blockers.end()
        #expect(!blockers.shouldTerminateAfterLastWindowClosed)
        blockers.end()
        blockers.end()
        #expect(blockers.shouldTerminateAfterLastWindowClosed)
    }

    @Test func resetClearsAbortedSessions() {
        let blockers = QuitBlockers()
        blockers.begin()
        blockers.begin()
        blockers.reset()
        #expect(!blockers.isBlocking)
    }
}
