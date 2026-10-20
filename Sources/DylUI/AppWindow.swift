#if canImport(SwiftUI)
import DylCore
import DylUpdates
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The main window of a DylKit app: a unified toolbar without a title, the palette and its accent tint, the
/// `--appearance` and `--window-size` launch overrides, the updater's launch check once the window is on screen, and
/// "Check for Updates…" in the app menu next to the app's own commands.
public struct AppWindow<Content: View, AppCommands: Commands>: Scene {
    private let title: String
    private let palette: any ThemePalette
    private let launch: LaunchOverrides
    private let defaultSize: CGSize
    private let content: Content
    private let commands: AppCommands

    public init(
        _ title: String,
        palette: any ThemePalette,
        launch: LaunchOverrides,
        defaultSize: CGSize,
        @ViewBuilder content: () -> Content,
        @CommandsBuilder commands: () -> AppCommands
    ) {
        self.title = title
        self.palette = palette
        self.launch = launch
        self.defaultSize = defaultSize
        self.content = content()
        self.commands = commands()
    }

    public var body: some Scene {
        WindowGroup(title) {
            content
                .palette(palette)
                .preferredColorScheme(colorScheme)
                .onAppear(perform: windowDidAppear)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(launch.windowSize ?? defaultSize)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            commands
        }
        #endif
    }

    private var colorScheme: ColorScheme? {
        launch.appearance.map { $0 == .dark ? .dark : .light }
    }

    private func windowDidAppear() {
        AppUpdater.shared.mainWindowDidAppear()
        #if os(macOS)
        // Menus and alerts follow NSApp, not the SwiftUI color scheme.
        if let appearance = launch.appearance {
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        // A restored frame wins over defaultSize, so screenshots set the size once the window exists.
        if let size = launch.windowSize {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
                    window.setContentSize(size)
                }
            }
        }
        #endif
    }
}
#endif
