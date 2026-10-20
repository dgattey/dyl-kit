/// Coalesces concurrent calls: while one `run` is in flight, later callers await the same result instead of
/// starting another. The next call after it finishes starts fresh.
public actor SingleFlight<Value: Sendable> {
    private var inFlight: Task<Value, Never>?

    public init() {}

    public func run(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        if let inFlight { return await inFlight.value }
        let task = Task { await operation() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        return value
    }
}

/// Drops results from superseded work. Call `advance()` when starting work and check `isCurrent(_:)` before
/// applying its result.
public struct GenerationGuard: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private var current: UInt64 = 0

    public init() {}

    public mutating func advance() -> Token {
        current &+= 1
        return Token(value: current)
    }

    public func isCurrent(_ token: Token) -> Bool { token.value == current }
}
