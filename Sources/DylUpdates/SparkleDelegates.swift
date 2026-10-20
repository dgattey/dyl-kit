#if os(macOS)
import Foundation
import OSLog
@preconcurrency import Sparkle

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DylUpdates", category: "Sparkle")

/// Opts into Sparkle's gentle reminders so `UpdatePresenter` decides how every found update is shown.
@MainActor
final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var presenter: UpdatePresenter?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled updates stay deferred so `willShowUpdate` can bring them forward.
        return false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated { presenter?.willShowUpdate(handledBySparkle: handleShowingUpdate) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { presenter?.sessionEnded() }
    }
}

@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var presenter: UpdatePresenter?

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        logger.info("Sparkle found update \(item.displayVersionString, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        let isNoUpdate = nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
        if isNoUpdate {
            logger.info("Sparkle check finished: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.error("Sparkle check failed: \(error.localizedDescription, privacy: .public)")
        }
        MainActor.assumeIsolated { presenter?.sessionEnded() }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        logger.info("Installing update \(item.displayVersionString, privacy: .public)")
        MainActor.assumeIsolated { presenter?.willInstallUpdate() }
    }
}
#endif
