#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The colors an app draws with. Each app declares one conforming type with its own values, built with
/// `Color(light:dark:)`, and adds any colors of its own. `AppWindow` and `SettingsWindow` install it, and views read it
/// back as the app's own type with `@Palette`. The accent is also the tint, so controls and selection use it.
public protocol ThemePalette: Sendable {
    /// The app's palette, which `@Palette` falls back to outside a DylKit window, as in previews.
    init()
    var accent: Color { get }
}

/// The installed palette as the app's own type, app-specific colors included: `@Palette var palette: SagaPalette`.
@propertyWrapper
public struct Palette<Value: ThemePalette>: DynamicProperty {
    @Environment(\.palette) private var installed

    public init() {}

    @MainActor public var wrappedValue: Value { installed as? Value ?? Value() }
}

extension EnvironmentValues {
    @Entry var palette: (any ThemePalette)? = nil
}

extension View {
    /// Installs `palette` for `@Palette` and tints controls and selection with its accent.
    public func palette(_ palette: any ThemePalette) -> some View {
        environment(\.palette, palette).tint(palette.accent)
    }
}

extension Color {
    /// A color that follows the light or dark appearance by itself, so views never branch on `colorScheme`.
    public init(light: Color, dark: Color) {
        let light = light.resolve(in: EnvironmentValues())
        let dark = dark.resolve(in: EnvironmentValues())
        #if os(macOS)
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(cgColor: (isDark ? dark : light).cgColor) ?? .clear
            })
        #else
        self.init(
            uiColor: UIColor { traits in
                UIColor(cgColor: (traits.userInterfaceStyle == .dark ? dark : light).cgColor)
            })
        #endif
    }
}
#endif
