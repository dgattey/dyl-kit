#if canImport(SwiftUI)
import DylCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// macOS window setup driven by `LaunchOverrides`. Every call is a no-op on iOS.
@MainActor
public enum LaunchShell {
    /// Call from `App.init()`: stops window restoration and applies an `--appearance` override before the first
    /// window draws, so captures never flash the other appearance.
    public static func configure(_ overrides: LaunchOverrides) {
        #if os(macOS)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        applyAppearance(overrides.appearance)
        #endif
    }

    public static func applyAppearance(_ appearance: LaunchOverrides.Appearance?) {
        #if os(macOS)
        guard let appearance else { return }
        NSApplication.shared.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        #endif
    }
}

extension View {
    /// Resizes the app's windows to `--window-size` once the view appears. Structured: cancelled with the view.
    public func launchWindowSize(_ overrides: LaunchOverrides) -> some View {
        #if os(macOS)
        task {
            guard let size = overrides.windowSize else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            for window in NSApp.windows where window.frame.width > 300 {
                window.setContentSize(size)
            }
        }
        #else
        self
        #endif
    }
}
#endif
