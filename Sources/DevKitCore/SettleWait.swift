import DylToolSupport
import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

/// Takes frames until the screen stops changing, so a capture never lands mid-launch on a spinner, a fade or a
/// half-loaded list. A launch screen can sit still for a moment before the app draws, so a still screen only counts
/// once it has changed at least once or `minimum` has passed.
public struct SettleWait: Sendable {
    public var timeout: Duration
    public var minimum: Duration
    public var interval: Duration
    /// Identical frames in a row that count as settled.
    public var stableFrames: Int

    public init(
        timeout: Duration = .seconds(20), minimum: Duration = .seconds(4), interval: Duration = .milliseconds(500),
        stableFrames: Int = 3
    ) {
        self.timeout = timeout
        self.minimum = minimum
        self.interval = interval
        self.stableFrames = stableFrames
    }

    /// Calls `frame` with a scratch path to write a PNG to until the last `stableFrames` match, then moves the last
    /// frame to `output`. Past `timeout` it keeps the last frame and warns.
    ///
    /// - Blocking: `frame` usually runs `screencapture` or `simctl io`.
    public func capture(to output: URL, frame: (URL) throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "dylkit-settle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let start = ContinuousClock.now
        var first: Data?
        var previous: Data?
        var changed = false
        var still = 0
        var index = 0
        var last: URL?
        while true {
            let path = scratch.appending(path: "\(index).png")
            index += 1
            try frame(path)
            let pixels = Self.pixels(at: path)
            last = path
            if let pixels, pixels == previous { still += 1 } else { still = 1 }
            if let first, let pixels, pixels != first { changed = true }
            first = first ?? pixels
            previous = pixels

            let elapsed = ContinuousClock.now - start
            if still >= stableFrames, changed || elapsed >= minimum { break }
            if elapsed >= timeout {
                Log.warn("the screen was still changing after \(timeout); captured the last frame")
                break
            }
            try await Task.sleep(for: interval)
        }
        guard let last else { throw ToolError("took no frames") }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: last, to: output)
    }

    /// Decoded pixels rather than file bytes, because PNG encoders may differ in metadata for the same image.
    static func pixels(at url: URL) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let data = image.dataProvider?.data
        else { return nil }
        return data as Data
        #else
        return try? Data(contentsOf: url)
        #endif
    }
}
