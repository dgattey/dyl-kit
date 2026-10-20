#if canImport(SwiftUI)
import SwiftUI

/// Card surface: palette fill, hairline top highlight, gradient border and soft shadow. `glowing` marks the
/// active or selected card with the accent.
public struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themePalette) private var palette
    public var glowing: Bool
    public var radius: CGFloat

    public init(glowing: Bool = false, radius: CGFloat = 22) {
        self.glowing = glowing
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(glowing ? palette.cardElevatedFill : palette.cardFill)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(dark ? 0.02 : 0.35),
                        (glowing ? palette.accent : Color.white).opacity(dark ? (glowing ? 0.65 : 0.25) : 0.85),
                        Color.white.opacity(dark ? 0.04 : 0.35),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, radius * 0.7)
                .padding(.top, 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: glowing
                                ? [palette.accent.opacity(0.92), palette.accentSecondary.opacity(0.42)]
                                : [palette.cardBorder, palette.cardBorder.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: glowing ? 1.4 : 1
                    )
            }
            .shadow(
                color: glowing
                    ? palette.accentSecondary.opacity(dark ? 0.34 : 0.18)
                    : Color.black.opacity(dark ? 0.28 : 0.07),
                radius: glowing ? 16 : 10,
                y: 6
            )
    }
}

extension View {
    public func glassCard(glowing: Bool = false, radius: CGFloat = 22) -> some View {
        modifier(GlassCard(glowing: glowing, radius: radius))
    }
}

/// Full-bleed window background: the palette's two background colors with faint accent glows.
public struct ThemedBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themePalette) private var palette

    public init() {}

    public var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            LinearGradient(
                colors: [palette.background, palette.backgroundSecondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [palette.accentSecondary.opacity(dark ? 0.16 : 0.10), .clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 460
            )
            RadialGradient(
                colors: [palette.accent.opacity(dark ? 0.10 : 0.08), .clear],
                center: .bottomLeading,
                startRadius: 8,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

/// Slight shrink and fade while pressed.
public struct PressableStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

/// Small capsule label for a status such as "Offline".
public struct StatusPill: View {
    @Environment(\.themePalette) private var palette
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.subtleFill))
            .overlay(Capsule().strokeBorder(palette.cardBorder, lineWidth: 1))
    }
}
#endif
