#if os(macOS)
import AppKit

/// Badges Sample's Dock icon while it's quit and its home screen tint is off. The Dock loads this into its own
/// process, so `UserDefaults.standard` is the Dock's. Sample's domain is this bundle's identifier minus `.docktile`,
/// which keeps a dev build reading `com.dylkit.Sample.dev`.
@objc(SampleDockTilePlugIn)
final class SampleDockTilePlugIn: NSObject, NSDockTilePlugIn {
    func setDockTile(_ dockTile: NSDockTile?) {
        guard let dockTile, let identifier = Bundle(for: Self.self).bundleIdentifier else { return }
        let app = String(identifier.dropLast(".docktile".count)) as CFString
        let showsWash = CFPreferencesCopyAppValue("showsWash" as CFString, app) as? Bool ?? true
        dockTile.badgeLabel = showsWash ? nil : "Plain"
    }
}
#endif
