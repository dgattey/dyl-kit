#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The colors DylKit's views draw with. Each app supplies its own, built with `Color(light:dark:)`, and the window
/// installs it with `.palette(_:)`. The accent is also the tint, so selected sidebar and list rows use it.
public protocol ThemePalette: Sendable {
    var accent: Color { get }
    var secondaryText: Color { get }
    /// Quiet fills behind pills and wells.
    var subtleFill: Color { get }
    /// Hairlines around pills and cards.
    var border: Color { get }
}

/// The system's colors, for an app that hasn't set a palette yet.
public struct SystemPalette: ThemePalette {
    public init() {}
    public var accent: Color { .accentColor }
    public var secondaryText: Color { .secondary }
    public var subtleFill: Color { .secondary.opacity(0.12) }
    public var border: Color { .secondary.opacity(0.25) }
}

extension EnvironmentValues {
    @Entry public var palette: any ThemePalette = SystemPalette()
}

extension View {
    /// Installs `palette` for DylKit's views and tints controls and selection with its accent.
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
