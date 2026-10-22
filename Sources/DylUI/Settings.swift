#if canImport(SwiftUI)
import DylCore
import DylUpdates
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One page of Settings: a sidebar row with a badge on macOS, a pushed row on iOS. Its content goes in a grouped
/// `Form`, so each `Section` is a rounded card. The badge uses `color`, or the palette's accent without one.
public struct SettingsPage: Identifiable {
    public let title: String
    let systemImage: String
    let color: Color?
    let content: AnyView

    public var id: String { title }

    @MainActor
    public init(_ title: String, systemImage: String, color: Color? = nil, @ViewBuilder content: () -> some View) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.content = AnyView(content())
    }
}

/// A run of pages in the sidebar under an optional header such as "Library".
public struct SettingsSection: Identifiable {
    public let title: String?
    let pages: [SettingsPage]

    public var id: String { title ?? pages.map(\.id).joined() }

    public init(_ title: String? = nil, pages: [SettingsPage]) {
        self.title = title
        self.pages = pages
    }
}

/// Settings as Saga #60 builds it. On macOS a sidebar of badged pages under the window controls, and a detail pane
/// with the page's badge and big title in the toolbar over a grouped form whose sections are the cards. On iOS a
/// pushed list.
public struct SettingsView: View {
    private let sections: [SettingsSection]
    @State private var selection: SettingsPage.ID?
    #if os(macOS)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #endif

    /// Opens on the first page, or with `--initial-view settings/<page>` on that page: its title lowercased with
    /// dashes for spaces, such as `settings/software-updates`.
    public init(sections: [SettingsSection]) {
        self.sections = sections
        let pages = sections.flatMap(\.pages)
        let launchPage = pages.first {
            LaunchOverrides.current.initialView == "settings/\($0.title.lowercased().replacing(" ", with: "-"))"
        }
        _selection = State(initialValue: (launchPage ?? pages.first)?.id)
    }

    private var pages: [SettingsPage] { sections.flatMap(\.pages) }

    public var body: some View {
        #if os(macOS)
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(sections: sections, selection: $selection)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 205, ideal: 205, max: 205)
        } detail: {
            if let page = pages.first(where: { $0.id == selection }) ?? pages.first {
                SettingsForm(page: page)
                    .settingsHeader(page)
            }
        }
        .liquidGlassToolbar()
        .frame(width: 700, height: 540)
        #else
        NavigationStack {
            Form {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.pages) { page in
                            NavigationLink {
                                SettingsForm(page: page)
                            } label: {
                                Label { Text(page.title) } icon: { SettingsBadge(page: page, size: 20) }
                            }
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }
            .formStyle(.grouped)
            .textCase(nil)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }
}

private struct SettingsForm: View {
    let page: SettingsPage

    var body: some View {
        Form { page.content }
            .formStyle(.grouped)
            .textCase(nil)
            #if os(macOS)
            .scrollContentBackground(.hidden)
            .softScrollEdge()
            .navigationTitle("")
            #else
            .navigationTitle(page.title)
            #endif
    }
}

/// A squircle in the page's color with its symbol in white, as System Settings draws its icons.
private struct SettingsBadge: View {
    @Environment(\.palette) private var palette
    let page: SettingsPage
    let size: CGFloat

    var body: some View {
        let color = page.color ?? palette?.accent ?? .accentColor
        Image(systemName: page.systemImage)
            .font(.system(size: round(size * 0.52), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: round(size * 0.28), style: .continuous))
    }
}

#if os(macOS)
private struct SettingsSidebar: View {
    let sections: [SettingsSection]
    @Binding var selection: SettingsPage.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(sections) { section in
                if let title = section.title {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 5)
                        .padding(.horizontal, 15)
                }
                ForEach(section.pages) { page in
                    row(page)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ page: SettingsPage) -> some View {
        Button {
            selection = page.id
        } label: {
            HStack(spacing: 8) {
                SettingsBadge(page: page, size: 20)
                Text(page.title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(7)
            .background(selection == page.id ? Color.primary.opacity(0.11) : .clear)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// The page's badge and title in the detail's leading toolbar slot, level with the window controls.
    @ViewBuilder
    fileprivate func settingsHeader(_ page: SettingsPage) -> some View {
        let header = HStack(spacing: 8) {
            SettingsBadge(page: page, size: 25)
            Text(page.title)
                .font(.title)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 13)
        if #available(macOS 26, *) {
            toolbar {
                ToolbarItem(placement: .navigation) { header }
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            toolbar {
                ToolbarItem(placement: .navigation) { header }
            }
        }
    }

    /// Floats the toolbar over the full-height sidebar, so the window controls sit inside it.
    @ViewBuilder
    fileprivate func liquidGlassToolbar() -> some View {
        if #available(macOS 15, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    /// A thin material under the palette's surface tint, which the sidebar and the form's cards sit on.
    @ViewBuilder
    fileprivate func windowBackground(_ tint: Color) -> some View {
        if #available(macOS 15, *) {
            containerBackground(for: .window) {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    tint
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    fileprivate func softScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// The Settings window: one instance, never reopened at launch, and ⌘, focuses it when it's already open, with no
/// lookups by window title. `SettingsView` lays it out from sections by default; an app with its own layout passes
/// any content instead.
public struct SettingsWindow: Scene {
    public static let id = "settings"
    private let palette: any ThemePalette
    private let content: AnyView

    public init(palette: any ThemePalette, sections: [SettingsSection]) {
        self.init(palette: palette) { SettingsView(sections: sections) }
    }

    public init(palette: any ThemePalette, @ViewBuilder content: () -> some View) {
        self.palette = palette
        self.content = AnyView(content())
    }

    public var body: some Scene {
        Window("Settings", id: Self.id) {
            content
                .palette(palette)
                .windowBackground(palette.surfaceTint)
                .background(NonRestorableWindow())
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 540)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
        }
    }
}

/// `Scene.restorationBehavior` needs macOS 15 and `SceneBuilder` can't fall back with `else`, so this turns off
/// restoration on the hosting window itself.
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowHook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
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

/// The Software Updates card. An app drawing its own binds to `AppUpdater.shared` (`@Bindable`) and shows
/// `AppAbout.main.version`.
public struct UpdatesSection: View {
    @Bindable private var updater = AppUpdater.shared

    public init() {}

    public var body: some View {
        Section("Software Updates") {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Automatically download updates", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
            LabeledContent {
                CheckForUpdatesButton()
            } label: {
                Text("Software updates")
                Text("Current version \(AppAbout.main.version)")
            }
        }
    }
}
#endif

/// The name and version Settings shows, for an app that draws About or Updates itself.
public struct AppAbout: Equatable, Sendable {
    public var name: String
    /// "v1.2 (34)".
    public var version: String

    public static var main: AppAbout {
        let info = AppInfo.main
        return AppAbout(
            name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
            version: "v\(info.version ?? "–") (\(info.build ?? "–"))")
    }
}

/// The About card: the app's icon beside its name and a version capsule in the palette's accent.
public struct AboutSection: View {
    @Environment(\.palette) private var palette

    public init() {}

    public var body: some View {
        let about = AppAbout.main
        let accent = palette?.accent ?? .accentColor
        Section {
            HStack(spacing: 16) {
                #if os(macOS)
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                #endif
                VStack(alignment: .leading, spacing: 4) {
                    Text(about.name)
                        .font(.title2.weight(.bold))
                    Text(about.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.10), in: .capsule)
                        .overlay(Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 1))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }
}
#endif
