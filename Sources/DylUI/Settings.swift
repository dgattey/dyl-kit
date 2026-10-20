#if canImport(SwiftUI)
import DylCore
import DylUpdates
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One page of Settings: a sidebar row on macOS, a pushed list row on iOS. Its content goes in a grouped `Form`.
public struct SettingsPage: Identifiable {
    public let title: String
    let systemImage: String
    let content: AnyView

    public var id: String { title }

    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) {
        self.title = title
        self.systemImage = systemImage
        self.content = AnyView(content())
    }
}

/// Settings as Saga #48 shaped it: a sidebar of pages beside a grouped form on macOS, a pushed list on iOS.
public struct SettingsView: View {
    private let pages: [SettingsPage]
    @State private var selection: String?

    public init(pages: [SettingsPage]) { self.pages = pages }

    public var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(pages, selection: $selection) { page in
                Label(page.title, systemImage: page.systemImage).tag(page.id)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            if let page = pages.first(where: { $0.id == selection }) ?? pages.first {
                form(page)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        #else
        NavigationStack {
            List(pages) { page in
                NavigationLink { form(page) } label: { Label(page.title, systemImage: page.systemImage) }
            }
            .navigationTitle("Settings")
        }
        #endif
    }

    private func form(_ page: SettingsPage) -> some View {
        Form { page.content }
            .formStyle(.grouped)
            .navigationTitle(page.title)
    }
}

#if os(macOS)
/// The Settings window: one instance, never reopened at launch, and ⌘, focuses it when it's already open, with no
/// lookups by window title.
public struct SettingsWindow: Scene {
    public static let id = "settings"
    private let palette: any ThemePalette
    private let pages: [SettingsPage]

    public init(palette: any ThemePalette, pages: [SettingsPage]) {
        self.palette = palette
        self.pages = pages
    }

    public var body: some Scene {
        Window("Settings", id: Self.id) {
            SettingsView(pages: pages).palette(palette)
        }
        .windowResizability(.contentMinSize)
        .withoutRestoration()
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
        }
    }
}

extension Scene {
    @SceneBuilder fileprivate func withoutRestoration() -> some Scene {
        if #available(macOS 15, *) {
            restorationBehavior(.disabled)
        } else {
            self
        }
    }
}

private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",")
    }
}

/// The Updates section: Sparkle's automatic-check preference and a manual check.
public struct UpdatesSection: View {
    @Bindable private var updater = AppUpdater.shared

    public init() {}

    public var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            LabeledContent("Version \(AppInfo.main.version ?? "–") (\(AppInfo.main.build ?? "–"))") {
                CheckForUpdatesButton()
            }
        }
    }
}
#endif

/// The About section: the app's icon, name and version from its Info.plist.
public struct AboutSection: View {
    public init() {}

    public var body: some View {
        Section {
            VStack(spacing: 8) {
                #if os(macOS)
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                #endif
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "")
                    .font(.title2.weight(.semibold))
                Text("Version \(AppInfo.main.version ?? "–") (\(AppInfo.main.build ?? "–"))")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}
#endif
