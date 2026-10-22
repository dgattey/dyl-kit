#if canImport(SwiftUI)
import DylCore
import DylUpdates
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// The main window of a DylKit app: the palette and its accent tint, devkit's `--appearance` and `--window-size`
/// launch overrides (read from `LaunchOverrides.current`, so the app passes nothing), the updater's launch check once
/// the window is on screen, and "Check for Updates…" in the app menu next to the app's own commands. The toolbar
/// style and resizability are the app's; the defaults are a unified toolbar without a title that never shrinks
/// below its content.
public struct AppWindow<Content: View, AppCommands: Commands, Toolbar: WindowToolbarStyle>: Scene {
    private let title: String
    private let palette: any ThemePalette
    private let defaultSize: CGSize
    private let toolbarStyle: Toolbar
    private let resizability: WindowResizability
    private let content: Content
    private let commands: AppCommands

    public init(
        _ title: String,
        palette: any ThemePalette,
        defaultSize: CGSize,
        toolbarStyle: Toolbar,
        resizability: WindowResizability = .contentMinSize,
        @ViewBuilder content: () -> Content,
        @CommandsBuilder commands: () -> AppCommands
    ) {
        self.title = title
        self.palette = palette
        self.defaultSize = defaultSize
        self.toolbarStyle = toolbarStyle
        self.resizability = resizability
        self.content = content()
        self.commands = commands()
    }

    public var body: some Scene {
        // Linked against the macOS 27 SDK, a WindowGroup without an id opens no window when the app launches without
        // activating, as every devkit launch does.
        WindowGroup(title, id: "main") {
            MainWindowContent(palette: palette, content: content)
        }
        .windowToolbarStyle(toolbarStyle)
        .defaultSize(LaunchOverrides.current.windowSize ?? defaultSize)
        .windowResizability(resizability)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            commands
        }
    }
}

extension AppWindow where Toolbar == UnifiedWindowToolbarStyle {
    public init(
        _ title: String,
        palette: any ThemePalette,
        defaultSize: CGSize,
        resizability: WindowResizability = .contentMinSize,
        @ViewBuilder content: () -> Content,
        @CommandsBuilder commands: () -> AppCommands
    ) {
        self.init(
            title, palette: palette, defaultSize: defaultSize, toolbarStyle: .unified(showsTitle: false),
            resizability: resizability, content: content, commands: commands)
    }
}
#else
/// The main window of a DylKit app: the palette and its accent tint, the `--appearance` launch override, and the
/// updater hook. It takes the macOS arguments too, so shared app code needs no `#if`.
public struct AppWindow<Content: View, AppCommands: Commands>: Scene {
    private let title: String
    private let palette: any ThemePalette
    private let content: Content

    public init(
        _ title: String,
        palette: any ThemePalette,
        defaultSize: CGSize,
        @ViewBuilder content: () -> Content,
        @CommandsBuilder commands: () -> AppCommands
    ) {
        self.title = title
        self.palette = palette
        self.content = content()
    }

    public var body: some Scene {
        WindowGroup(title) {
            MainWindowContent(palette: palette, content: content)
        }
    }
}
#endif

private struct MainWindowContent<Content: View>: View {
    let palette: any ThemePalette
    let content: Content

    var body: some View {
        content
            .palette(palette)
            .preferredColorScheme(colorScheme)
            .onAppear(perform: windowDidAppear)
    }

    private var launch: LaunchOverrides { .current }

    private var colorScheme: ColorScheme? {
        launch.appearance.map { $0 == .dark ? .dark : .light }
    }

    private func windowDidAppear() {
        AppUpdater.shared.mainWindowDidAppear()
        #if os(macOS)
        // Menus and alerts follow the app's appearance, not the SwiftUI color scheme.
        if let appearance = launch.appearance {
            NSApplication.shared.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        // A restored frame wins over defaultSize, so screenshots set the size once the window exists.
        if let size = launch.windowSize {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                for window in NSApplication.shared.windows where window.isVisible && window.frame.width > 300 {
                    window.setContentSize(size)
                }
            }
        }
        #endif
    }
}
#endif
