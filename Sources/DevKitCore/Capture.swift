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

    /// Waits up to `timeout` for `pid` to show a normal window, on screen or on a Space that isn't active, then
    /// captures it without its shadow once it stops changing.
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
        guard let window else {
            if let unshown = Self.unshownWindow(of: pid) { throw Self.notShown(unshown) }
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

    /// Why `screencapture` couldn't read `window`, in words rather than its "could not create image from window".
    static func unreadable(_ window: UInt32) -> ToolError {
        #if canImport(CoreGraphics)
        let listed = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window))
            as? [[CFString: AnyObject]])?.first.flatMap(ListedWindow.init)
        #else
        let listed: ListedWindow? = nil
        #endif
        guard let listed else { return ToolError("window \(window) closed before it could be captured") }
        return listed.shown ? ToolError("screencapture couldn't read window \(window)") : notShown(window)
    }

    static func notShown(_ window: UInt32) -> ToolError {
        ToolError(
            "window \(window) isn't shown (closed, minimized, hidden or never ordered in), so it can't be captured")
    }

    /// A normal-layer window from the window list. `onScreen` is false for a window on a Space that isn't active,
    /// which `screencapture -l` still reads, so `shown` is what "has a window" means.
    struct ListedWindow: Equatable {
        var id: UInt32
        var onScreen: Bool
        /// On screen, or ordered in on another Space. False for a window that was never ordered in, or that's been
        /// ordered out, minimized, hidden with its app or closed: the window list keeps all of those.
        var shown: Bool
        var area: Double
    }

    /// The largest shown window, preferring one on screen.
    static func mainWindow(in windows: [ListedWindow]) -> UInt32? {
        windows.filter(\.shown).max { ($0.onScreen ? 1 : 0, $0.area) < ($1.onScreen ? 1 : 0, $1.area) }?.id
    }

    static func mainWindow(of pid: Int32) -> UInt32? { mainWindow(in: windows(of: pid)) }

    /// The largest window `pid` has created but isn't showing, when it shows none.
    static func unshownWindow(of pid: Int32) -> UInt32? {
        let windows = Self.windows(of: pid)
        guard mainWindow(in: windows) == nil else { return nil }
        return windows.max { $0.area < $1.area }?.id
    }

    static func windows(of pid: Int32) -> [ListedWindow] {
        #if canImport(CoreGraphics)
        guard
            let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: AnyObject]]
        else { return [] }
        return windows.compactMap { info in
            (info[kCGWindowOwnerPID] as? Int32) == pid ? ListedWindow(info) : nil
        }
        #else
        return []
        #endif
    }
}

#if canImport(CoreGraphics)
extension WindowCapture.ListedWindow {
    init?(_ info: [CFString: AnyObject]) {
        guard (info[kCGWindowLayer] as? Int) == 0, let id = info[kCGWindowNumber] as? UInt32,
            let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsInfo), bounds.width > 200, bounds.height > 200
        else { return nil }
        let onScreen = (info[kCGWindowIsOnscreen] as? Bool) == true
        self.init(
            id: id, onScreen: onScreen, shown: onScreen || SkyLight.isOrderedIn(id) == true,
            area: Double(bounds.width * bounds.height))
    }
}

/// SkyLight's read-only `SLSWindowIsOrderedIn`, looked up at runtime: nothing public tells a window ordered in on a
/// Space that isn't active from one that's ordered out. Without it, only on-screen windows count as shown.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> Int32

    nonisolated(unsafe) private static let orderedIn =  // SAFETY: a C function pointer, set once and only read
        symbol("SLSWindowIsOrderedIn", IsOrderedIn.self)
    private static let connection = symbol("SLSMainConnectionID", MainConnection.self)?()

    static var available: Bool { orderedIn != nil && connection != nil }

    static func isOrderedIn(_ window: UInt32) -> Bool? {
        guard let orderedIn, let connection else { return nil }
        var value: UInt8 = 0
        return orderedIn(connection, window, &value) == 0 ? value != 0 : nil
    }

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        return dlsym(skyLight, name).map { unsafeBitCast($0, to: type) }
    }
}
#endif
