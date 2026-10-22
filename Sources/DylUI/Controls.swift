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
#endif
