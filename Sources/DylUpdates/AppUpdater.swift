#if canImport(SwiftUI)
import Combine
import DylCore
import DylShell
import SwiftUI

#if os(macOS)
import OSLog
@preconcurrency import Sparkle
#endif

/// Sparkle updates for a DylKit app. Starts only when Info.plist carries `SUFeedURL` and `SUPublicEDKey`, checks
/// in the background once per launch after the main window appears, and keeps the app alive while an update is
/// shown or installing. On iOS every member is inert.
@MainActor
public final class AppUpdater: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false
    public let isReleaseConfigured: Bool
    private var didScheduleLaunchCheck = false

    #if os(macOS)
    private let controller: SPUStandardUpdaterController
    private let updaterDelegate: UpdaterDelegate
    private let userDriverDelegate: UserDriverDelegate
    private var canCheckCancellable: AnyCancellable?
    private var launchCheckCancellable: AnyCancellable?
    #endif

    public init(info: AppInfo = .main, quitBlockers: QuitBlockers = .shared) {
        isReleaseConfigured = info.isReleaseConfigured
        #if os(macOS)
        let logger = Logger(subsystem: info.bundleIdentifier ?? "DylKit", category: "Sparkle")
        updaterDelegate = UpdaterDelegate(logger: logger, quitBlockers: quitBlockers)
        userDriverDelegate = UserDriverDelegate(quitBlockers: quitBlockers)
        controller = SPUStandardUpdaterController(
            startingUpdater: isReleaseConfigured,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )
        userDriverDelegate.updater = controller.updater
        canCheckCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
        #endif
    }

    public func checkForUpdates() {
        #if os(macOS)
        controller.updater.checkForUpdates()
        #endif
    }

    /// Call once the main window is on screen, so a launch check can never close the last window and quit.
    public func mainWindowDidAppear() {
        #if os(macOS)
        let updater = controller.updater
        let plan = LaunchCheckPlan.decide(
            isReleaseConfigured: isReleaseConfigured,
            alreadyScheduled: didScheduleLaunchCheck,
            sessionInProgress: updater.sessionInProgress,
            canCheckForUpdates: updater.canCheckForUpdates
        )
        if plan != .skip { didScheduleLaunchCheck = true }
        switch plan {
        case .skip, .adoptRunningSession:
            return
        case .checkNow:
            updater.checkForUpdatesInBackground()
        case .waitUntilReady:
            launchCheckCancellable = updater.publisher(for: \.canCheckForUpdates)
                .removeDuplicates()
                .filter { $0 }
                .first()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, !self.controller.updater.sessionInProgress else { return }
                    self.controller.updater.checkForUpdatesInBackground()
                }
        }
        #endif
    }
}

/// "Check for Updates…" for the app menu, typically in `CommandGroup(after: .appInfo)`.
public struct CheckForUpdatesButton: View {
    @ObservedObject private var updater: AppUpdater

    public init(updater: AppUpdater) {
        self.updater = updater
    }

    public var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

#if os(macOS)
@MainActor
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    weak var updater: SPUUpdater?
    private let quitBlockers: QuitBlockers

    init(quitBlockers: QuitBlockers) {
        self.quitBlockers = quitBlockers
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            quitBlockers.begin()
            if !handleShowingUpdate {
                updater?.checkForUpdates()
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            quitBlockers.reset()
        }
    }
}

@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let logger: Logger
    private let quitBlockers: QuitBlockers

    init(logger: Logger, quitBlockers: QuitBlockers) {
        self.logger = logger
        self.quitBlockers = quitBlockers
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            logger.info("Sparkle found valid update \(version, privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        let isNoUpdate = nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            quitBlockers.reset()
            if isNoUpdate {
                logger.info("Sparkle update check finished: \(message, privacy: .public)")
            } else {
                logger.error("Sparkle update check failed: \(message, privacy: .public)")
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            quitBlockers.begin()
            logger.info("Installing update \(version, privacy: .public)")
        }
    }
}
#endif
#endif
