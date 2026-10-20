#if canImport(SwiftUI)
import SwiftUI

/// "Check for Updates…" for the app menu, disabled while Sparkle can't start a check.
public struct CheckForUpdatesButton: View {
    public init() {}

    public var body: some View {
        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            .disabled(!AppUpdater.shared.canCheckForUpdates)
    }
}
#endif
