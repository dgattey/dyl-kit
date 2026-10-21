@_exported import ViewInspector
import DylCore
import Foundation

extension AppDirectories {
    /// Runs `body` with `AppDirectories.support` pointing at a fresh scratch folder, removed afterwards. Scoped to
    /// the task, so parallel tests each get their own.
    public static func withTemporarySupportFolder<T>(
        _ body: (URL) async throws -> T, isolation: isolated (any Actor)? = #isolation
    ) async rethrows -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dylkit-support-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await $scopedOverride.withValue(folder) { try await body(folder) }
    }

    /// Points `AppDirectories.support` at `url` for the whole process until it's reset with nil, for XCTest
    /// `setUp`/`tearDown`. Prefer `withTemporarySupportFolder` in Swift Testing, which runs tests in parallel.
    public static func setSupportFolderForTesting(_ url: URL?) {
        globalOverride = url
    }
}
