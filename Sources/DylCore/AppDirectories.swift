import Foundation

/// The app's Application Support folder, `~/Library/Application Support/<bundle id>`, created once on first use.
/// Tests point it at a scratch folder with `DylTestSupport`.
public enum AppDirectories {
    /// - Blocking: creates the folder on first use.
    public static var support: URL { scopedOverride ?? defaultSupport }

    private static let defaultSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @TaskLocal package static var scopedOverride: URL?
}
