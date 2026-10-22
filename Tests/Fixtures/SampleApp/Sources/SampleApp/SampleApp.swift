import DylCore
import DylUI
import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        AppWindow("Sample", palette: SamplePalette(), defaultSize: CGSize(width: 640, height: 420)) {
            HomeView()
        } commands: {
            EmptyCommands()
        }
        #if os(macOS)
        SettingsWindow(palette: SamplePalette(), sections: SampleSettings.sections)
        #endif
    }
}

/// `[site] accent` in DylApp.toml.
struct SamplePalette: ThemePalette {
    var accent = Color(light: Color(hex: 0x9a5f12), dark: Color(hex: 0xe2a547))
    var surfaceTint: Color { accent.opacity(0.08) }
    var wash: Color { accent.opacity(0.12) }
}

private let showsWashKey = "showsWash"

/// `--initial-view settings` opens Settings, and `settings/credits` opens it on Credits, so captures cover DylUI's
/// Settings without a click.
struct HomeView: View {
    @Palette private var palette: SamplePalette
    @AppStorage(showsWashKey) private var showsWash = true
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        #if os(macOS)
        home.onAppear {
            if opensSettings {
                openWindow(id: SettingsWindow.id)
            }
        }
        #else
        if opensSettings {
            SettingsView(sections: SampleSettings.sections)
        } else {
            home
        }
        #endif
    }

    private var opensSettings: Bool { LaunchOverrides.current.initialView?.split(separator: "/").first == "settings" }

    private var home: some View {
        Text("Sample")
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(showsWash ? palette.wash : .clear)
    }
}

@MainActor
enum SampleSettings {
    static var sections: [SettingsSection] {
        [
            SettingsSection(pages: [
                SettingsPage("General", systemImage: "gearshape.fill", color: Color(hex: 0x747a7f)) {
                    #if os(macOS)
                    UpdatesSection()
                    #endif
                    HomeSection()
                }
            ]),
            SettingsSection("App", pages: [
                SettingsPage("Credits", systemImage: "heart.fill", color: Color(hex: 0xc2883e)) { CreditsSection() },
                SettingsPage("About", systemImage: "info.circle.fill", color: Color(hex: 0xb4644a)) { AboutSection() },
            ]),
        ]
    }
}

private struct CreditsSection: View {
    var body: some View {
        Section("Open Source") {
            SettingsRow(
                "DylKit", subtitle: "Release pipeline, dev loop and Settings", systemImage: "hammer.fill",
                tags: ["MIT"], link: URL(string: "https://github.com/dgattey/dyl-kit"))
            SettingsRow(
                "Sparkle", subtitle: "Automatic software updates for macOS", systemImage: "sparkles",
                color: Color(hex: 0x3d8461), tags: ["MIT"], link: URL(string: "https://sparkle-project.org"))
        }
    }
}

private struct HomeSection: View {
    @AppStorage(showsWashKey) private var showsWash = true

    var body: some View {
        Section("Home") {
            Toggle("Tint the home screen", isOn: $showsWash)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}
