/// How a found update reaches the user, and whether quitting must wait for Sparkle.
///
/// Sparkle's standard driver never activates a regular app for a background check, and it defers the alert until the
/// app next becomes active when the app isn't active or more than 3s have passed since the updater started. A launch
/// check therefore leaves the alert behind other windows. So Sparkle never shows a scheduled update itself: every found
/// update activates the app, and one Sparkle deferred is re-run as a user check, which shows it in focus. A background
/// check that finds nothing never reaches here and stays silent.
@MainActor
final class UpdatePresenter {
    /// Sparkle closes its alert to install; a single-window app must not quit on that last window closing.
    private(set) var blocksQuit = false
    private let activateApp: () -> Void
    private let showUpdateInFocus: () -> Void

    init(activateApp: @escaping () -> Void, showUpdateInFocus: @escaping () -> Void) {
        self.activateApp = activateApp
        self.showUpdateInFocus = showUpdateInFocus
    }

    /// `standardUserDriverShouldHandleShowingScheduledUpdate`: never, so `willShowUpdate` can bring it forward.
    nonisolated static let sparkleShowsScheduledUpdates = false

    /// `standardUserDriverWillHandleShowingUpdate`. `handledBySparkle` is false for a scheduled or launch check.
    func willShowUpdate(handledBySparkle: Bool) {
        blocksQuit = true
        activateApp()
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
