/// Reasons the app must stay alive after its last window closes, such as an update installing. Nested
/// `begin`/`end` pairs are counted; `reset()` clears them when a session ends abnormally.
@MainActor
public final class QuitBlockers {
    public static let shared = QuitBlockers()

    private var count = 0

    public init() {}

    public var isBlocking: Bool { count > 0 }

    public func begin() { count += 1 }

    public func end() { count = max(0, count - 1) }

    public func reset() { count = 0 }

    /// Answer for `applicationShouldTerminateAfterLastWindowClosed`.
    public var shouldTerminateAfterLastWindowClosed: Bool { !isBlocking }
}
