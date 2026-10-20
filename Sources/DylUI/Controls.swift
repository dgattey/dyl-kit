#if canImport(SwiftUI)
import SwiftUI

/// Shrinks and dims a custom button while it's pressed.
public struct PressableStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

/// A small capsule for a status such as "Offline".
public struct StatusPill: View {
    @Environment(\.palette) private var palette
    private let text: LocalizedStringKey

    public init(_ text: LocalizedStringKey) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.subtleFill))
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
    }
}
#endif
