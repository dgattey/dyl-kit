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
        let name = [workspace.manifest.app.name.lowercased(), label?.replacing("/", with: "-"), stamp]
            .compactMap { $0 }.joined(separator: "-")
        return capturesDir.appending(path: "\(name).png")
    }

    /// Waits up to `timeout` for `pid` to show a normal window on screen, then captures it without its shadow once it
    /// stops changing.
    ///
    /// - Blocking: polls the window list and runs `screencapture`.
    public func capture(pid: Int32, to output: URL, timeout: Duration = .seconds(15), settle: SettleWait = .init())
        async throws -> URL
    {
        let deadline = ContinuousClock.now + timeout
        var window: UInt32?
        while window == nil, ContinuousClock.now < deadline {
            window = Self.mainWindow(of: pid, onScreenOnly: true)
            if window == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let window else {
            if let hidden = Self.mainWindow(of: pid) { throw Self.offScreen(hidden) }
            throw ToolError("pid \(pid) showed no window within \(timeout)")
        }
        try await settle.capture(to: output) { frame in
            let arguments = ["screencapture", "-l", String(window), "-o", "-x", frame.path]
            guard try Shell.run(arguments, quiet: true, allowFailure: true) == 0 else {
                throw Self.unreadable(window)
            }
        }
        Log.step("captured window \(window) to \(output.path)")
        return output
    }

    enum Visibility: Equatable { case onScreen, offScreen, gone }

    /// Why `screencapture` couldn't read `window`, in words rather than its "could not create image from window".
    static func unreadable(_ window: UInt32) -> ToolError {
        switch visibility(of: window) {
        case .offScreen: offScreen(window)
        case .gone: ToolError("window \(window) closed before it could be captured")
        case .onScreen: ToolError("screencapture couldn't read window \(window)")
        }
    }

    static func offScreen(_ window: UInt32) -> ToolError {
        ToolError(
            "window \(window) is off screen (on another Space, minimized or hidden), so it can't be captured; "
                + "switch back to the Space it opened on")
    }

    /// The window server only draws a window for `screencapture -l` while it's on screen in the current Space.
    static func visibility(of window: UInt32) -> Visibility {
        #if canImport(CoreGraphics)
        guard
            let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window))
                as? [[CFString: AnyObject]])?.first
        else { return .gone }
        return (info[kCGWindowIsOnscreen] as? Bool) == true ? .onScreen : .offScreen
        #else
        return .gone
        #endif
    }

    /// The largest normal-layer window `pid` owns, preferring one on screen. The list also holds windows that were
    /// created but never ordered in, or that sit on another Space, so `onScreenOnly` is what "has a window" means.
    static func mainWindow(of pid: Int32, onScreenOnly: Bool = false) -> UInt32? {
        #if canImport(CoreGraphics)
        guard
            let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: AnyObject]]
        else { return nil }
        let candidates = windows.compactMap { info -> (id: UInt32, onScreen: Bool, area: Double)? in
            guard (info[kCGWindowOwnerPID] as? Int32) == pid, (info[kCGWindowLayer] as? Int) == 0,
                let id = info[kCGWindowNumber] as? UInt32,
                let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                bounds.width > 200, bounds.height > 200
            else { return nil }
            let onScreen = (info[kCGWindowIsOnscreen] as? Bool) == true
            return onScreenOnly && !onScreen ? nil : (id, onScreen, Double(bounds.width * bounds.height))
        }
        return candidates.max { ($0.onScreen ? 1 : 0, $0.area) < ($1.onScreen ? 1 : 0, $1.area) }?.id
        #else
        return nil
        #endif
    }
}
