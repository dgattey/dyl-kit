#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// sRGB components on a 0–255 scale with 0–1 opacity.
public struct RGBA: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ opacity: Double = 1) -> RGBA {
        RGBA(red: red, green: green, blue: blue, opacity: opacity)
    }
}

extension Color {
    /// A color that resolves per appearance without forcing a color scheme on the view tree.
    public static func adaptive(light: RGBA, dark: RGBA) -> Color {
        #if os(macOS)
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.red / 255, green: c.green / 255, blue: c.blue / 255, alpha: c.opacity)
            }
        )
        #else
        return Color(
            uiColor: UIColor { traits in
                let c = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.red / 255, green: c.green / 255, blue: c.blue / 255, alpha: c.opacity)
            }
        )
        #endif
    }
}

/// The colors shared components draw with. Each app supplies one and installs it with `.themePalette(_:)`.
public protocol ThemePalette: Sendable {
    var background: Color { get }
    var backgroundSecondary: Color { get }
    var accent: Color { get }
    var accentSecondary: Color { get }
    var primaryText: Color { get }
    var secondaryText: Color { get }
    var tertiaryText: Color { get }
    /// Foreground on top of `accent`.
    var onAccent: Color { get }
    var cardFill: Color { get }
    var cardElevatedFill: Color { get }
    var cardBorder: Color { get }
    var subtleFill: Color { get }
}

/// System colors, used until an app installs its palette.
public struct SystemPalette: ThemePalette {
    public init() {}
    public var background: Color { Color.clear }
    public var backgroundSecondary: Color { Color.clear }
    public var accent: Color { Color.accentColor }
    public var accentSecondary: Color { Color.accentColor }
    public var primaryText: Color { Color.primary }
    public var secondaryText: Color { Color.secondary }
    public var tertiaryText: Color { Color.secondary.opacity(0.7) }
    public var onAccent: Color { Color.white }
    public var cardFill: Color { Color.primary.opacity(0.04) }
    public var cardElevatedFill: Color { Color.primary.opacity(0.07) }
    public var cardBorder: Color { Color.primary.opacity(0.12) }
    public var subtleFill: Color { Color.primary.opacity(0.06) }
}

extension EnvironmentValues {
    @Entry public var themePalette: any ThemePalette = SystemPalette()
}

extension View {
    public func themePalette(_ palette: some ThemePalette) -> some View {
        environment(\.themePalette, palette)
    }
}
#endif
