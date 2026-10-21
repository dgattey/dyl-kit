import DylToolSupport
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Screenshots one app window with `screencapture -l`, which reads the window server directly: nothing is
/// activated or raised, and the system appearance is never touched (the app applies `--appearance` to itself).
public struct WindowCapture: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    private var capturesDir: URL { workspace.buildDir.appending(path: "captures") }

    /// A fresh, timestamped path so image caches never serve an old render.
    public func defaultOutput(label: String?) -> URL {
        let stamp = Date().formatted(
            Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted, timeZone: .current)
                .year().month().day().time(includingFractionalSeconds: false))
        let name = [workspace.manifest.app.name.lowercased(), label, stamp]
            .compactMap { $0 }.joined(separator: "-")
        return capturesDir.appending(path: "\(name).png")
    }

    /// Waits up to `timeout` for `pid` to show a normal window, then captures it without its shadow once it stops
    /// changing.
    ///
    /// - Blocking: polls the window list and runs `screencapture`.
    public func capture(pid: Int32, to output: URL, timeout: Duration = .seconds(15), settle: SettleWait = .init())
        async throws -> URL
    {
        let deadline = ContinuousClock.now + timeout
        var window: UInt32?
        while window == nil, ContinuousClock.now < deadline {
            window = Self.mainWindow(of: pid)
            if window == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let window else { throw ToolError("pid \(pid) showed no window within \(timeout)") }
        try await settle.capture(to: output) { frame in
            try Shell.run(["screencapture", "-l", String(window), "-o", "-x", frame.path])
        }
        Log.step("captured window \(window) to \(output.path)")
        return output
    }

    /// The largest normal-layer window `pid` owns.
    private static func mainWindow(of pid: Int32) -> UInt32? {
        #if canImport(CoreGraphics)
        guard
            let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: AnyObject]]
        else { return nil }
        let candidates = windows.compactMap { info -> (id: UInt32, area: Double)? in
            guard (info[kCGWindowOwnerPID] as? Int32) == pid, (info[kCGWindowLayer] as? Int) == 0,
                let id = info[kCGWindowNumber] as? UInt32,
                let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                bounds.width > 200, bounds.height > 200
            else { return nil }
            return (id, Double(bounds.width * bounds.height))
        }
        return candidates.max { $0.area < $1.area }?.id
        #else
        return nil
        #endif
    }
}
