import DylCore
import Observation
#if os(macOS)
import AppKit
@preconcurrency import Sparkle
#endif

/// The app's Sparkle updater, one per process. It starts only in release builds (a feed URL and public key in
/// Info.plist), checks once in the background after the main window appears, and shows found updates in focus
/// (see `UpdatePresenter`). On iOS every member is inert, so call sites need no `#if`.
@Observable @MainActor
public final class AppUpdater {
    public static let shared = AppUpdater()

    public private(set) var canCheckForUpdates = false

    #if os(macOS)
    /// Sparkle's "check automatically" preference, for a Settings toggle.
    public var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private let isReleaseConfigured: Bool
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let presenter: UpdatePresenter
    // Sparkle holds its delegates weakly.
    @ObservationIgnored private let updaterDelegate: UpdaterDelegate
    @ObservationIgnored private let userDriverDelegate: UserDriverDelegate
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private init() {
        let configured = AppInfo.main.isReleaseConfigured
        let updaterDelegate = UpdaterDelegate()
        let userDriverDelegate = UserDriverDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: configured, updaterDelegate: updaterDelegate, userDriverDelegate: userDriverDelegate)
        let presenter = UpdatePresenter(
            activateApp: { NSApp.activate(ignoringOtherApps: true) },
            showUpdateInFocus: { [weak controller] in controller?.checkForUpdates(nil) }
        )
        updaterDelegate.presenter = presenter
        userDriverDelegate.presenter = presenter
        isReleaseConfigured = configured
        self.controller = controller
        self.presenter = presenter
        self.updaterDelegate = updaterDelegate
        self.userDriverDelegate = userDriverDelegate
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        // SPUUpdater is main-actor isolated, so read canCheckForUpdates on the main actor, not in the KVO callback.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial]) {
            [weak self] _, _ in
            Task { @MainActor in self?.canCheckDidChange() }
        }
    }

    /// For `applicationShouldTerminateAfterLastWindowClosed`: Sparkle closes its window to install.
    public var blocksQuitOnLastWindowClosed: Bool { presenter.blocksQuit }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Call once the main window is on screen, so a launch check can't close the last window and quit the app.
    public func mainWindowDidAppear() {
        guard isReleaseConfigured else { return }
        presenter.requestLaunchCheck()
        checkOnLaunchIfReady()
    }

    private func canCheckDidChange() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
        checkOnLaunchIfReady()
    }

    private func checkOnLaunchIfReady() {
        let updater = controller.updater
        if presenter.takeLaunchCheck(canCheck: updater.canCheckForUpdates, sessionInProgress: updater.sessionInProgress) {
            updater.checkForUpdatesInBackground()
        }
    }
    #else
    public var automaticallyChecksForUpdates = false

    private init() {}

    public var blocksQuitOnLastWindowClosed: Bool { false }
    public func checkForUpdates() {}
    public func mainWindowDidAppear() {}
    #endif
}
