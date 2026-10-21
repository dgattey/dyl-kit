import DylCore
import Foundation

/// How a found update reaches the user, when the launch check runs, and whether quitting must wait for Sparkle.
///
/// Sparkle's standard driver never activates a regular app for a background check, and it defers the alert until the
/// app next becomes active when the app isn't active or more than 3s have passed since the updater started. A launch
/// check therefore leaves the alert behind other windows. So Sparkle never shows a scheduled update itself: every found
/// update activates the app, and one Sparkle deferred is re-run as a user check, which shows it in focus. A background
/// check that finds nothing never reaches here and stays silent.
///
/// The re-run is safe inside the session because Sparkle calls the deferred `willShowUpdate` a run loop later, once its
/// driver is showing the update, so `checkForUpdates` refocuses it. A call made earlier in the session, such as from
/// `didFindValidUpdate` or a `checkForUpdateInformation` probe, hits `sessionInProgress` and Sparkle drops it.
///
/// Activating is allowed only once `mayActivate` is set, which `mayActivate(app:bundleURL:launch:)` decides.
@MainActor
final class UpdatePresenter {
    /// Sparkle closes its alert to install; a single-window app must not quit on that last window closing.
    private(set) var blocksQuit = false
    /// False until the main window appears and the app is known to be an installed release.
    var mayActivate = false
    private var launchCheck = LaunchCheck.notRequested
    private let activateApp: () -> Void
    private let showUpdateInFocus: () -> Void

    private enum LaunchCheck { case notRequested, pending, done }

    init(activateApp: @escaping () -> Void, showUpdateInFocus: @escaping () -> Void) {
        self.activateApp = activateApp
        self.showUpdateInFocus = showUpdateInFocus
    }

    /// Only an installed release takes focus. A dev build under `build/`, a test runner, or anything devkit or an
    /// agent launched (`DYLKIT_BACKGROUND`) never does.
    nonisolated static func mayActivate(app: AppInfo, bundleURL: URL, launch: LaunchOverrides) -> Bool {
        app.isReleaseConfigured
            && bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
            && !launch.staysInBackground
    }

    /// The main window is on screen, so a launch check can no longer close the last window and quit the app.
    func requestLaunchCheck() {
        if launchCheck == .notRequested { launchCheck = .pending }
    }

    /// True exactly once per launch, when the background launch check should start now. A session already in
    /// progress (Sparkle's scheduler, or the user) counts as the launch check; until Sparkle can check, keep waiting.
    func takeLaunchCheck(canCheck: Bool, sessionInProgress: Bool) -> Bool {
        guard launchCheck == .pending else { return false }
        if sessionInProgress {
            launchCheck = .done
            return false
        }
        guard canCheck else { return false }
        launchCheck = .done
        return true
    }

    /// `standardUserDriverWillHandleShowingUpdate`. `handledBySparkle` is false for a scheduled or launch check.
    func willShowUpdate(handledBySparkle: Bool) {
        blocksQuit = true
        launchCheck = .done
        if mayActivate { activateApp() }
        if !handledBySparkle { showUpdateInFocus() }
    }

    func willInstallUpdate() {
        blocksQuit = true
    }

    /// The session finished, was dismissed, or aborted (including "no update").
    func sessionEnded() {
        blocksQuit = false
    }
}
