/// What to do about the once-per-launch background update check when the main window appears.
public enum LaunchCheckPlan: Equatable, Sendable {
    /// Dev build without a feed or key, or the check already ran.
    case skip
    /// Sparkle's scheduler already started a session during startup; let it run and count it as this launch's check.
    case adoptRunningSession
    case checkNow
    /// The updater isn't ready; check as soon as `canCheckForUpdates` turns true.
    case waitUntilReady

    public static func decide(
        isReleaseConfigured: Bool,
        alreadyScheduled: Bool,
        sessionInProgress: Bool,
        canCheckForUpdates: Bool
    ) -> LaunchCheckPlan {
        guard isReleaseConfigured, !alreadyScheduled else { return .skip }
        if sessionInProgress { return .adoptRunningSession }
        return canCheckForUpdates ? .checkNow : .waitUntilReady
    }
}
