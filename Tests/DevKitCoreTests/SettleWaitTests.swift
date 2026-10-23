import CoreGraphics
import DylToolSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DevKitCore

@Suite struct SettleWaitTests {
    private static func writePNG(gray: CGFloat, to url: URL) throws {
        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private static func output() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "settle-\(UUID().uuidString).png")
    }

    private static let quick = SettleWait(
        timeout: .seconds(5), minimum: .seconds(5), interval: .milliseconds(1), stableFrames: 3)

    /// Photos: `devkit ios capture` caught the launch spinner. Frames that keep changing aren't captured until they stop.
    @Test func waitsForTheSpinnerToStop() async throws {
        let spinner: [CGFloat] = [0.1, 0.4, 0.7, 0.4, 0.9, 0.9, 0.9, 0.9]
        var index = 0
        let output = Self.output()
        defer { try? FileManager.default.removeItem(at: output) }
        try await Self.quick.capture(to: output) { frame in
            try Self.writePNG(gray: spinner[min(index, spinner.count - 1)], to: frame)
            index += 1
        }
        #expect(index == 7)
        let settled = Self.output()
        defer { try? FileManager.default.removeItem(at: settled) }
        try Self.writePNG(gray: 0.9, to: settled)
        #expect(SettleWait.pixels(at: output) == SettleWait.pixels(at: settled))
    }

    /// A blank launch screen that holds still isn't the app; it must change once or outlast `minimum`.
    @Test func aStillLaunchScreenWaitsForTheMinimum() async throws {
        var frames = 0
        let output = Self.output()
        defer { try? FileManager.default.removeItem(at: output) }
        let wait = SettleWait(timeout: .seconds(5), minimum: .milliseconds(200), interval: .milliseconds(20))
        let start = ContinuousClock.now
        try await wait.capture(to: output) { frame in
            try Self.writePNG(gray: 1, to: frame)
            frames += 1
        }
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        #expect(frames >= 3)
    }

    @Test func givesUpAtTheTimeoutWithTheLastFrame() async throws {
        var gray: CGFloat = 0
        let output = Self.output()
        defer { try? FileManager.default.removeItem(at: output) }
        let wait = SettleWait(timeout: .milliseconds(100), minimum: .zero, interval: .milliseconds(10))
        try await wait.capture(to: output) { frame in
            gray = gray >= 1 ? 0 : gray + 0.05
            try Self.writePNG(gray: gray, to: frame)
        }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    /// Sconeos: frames 0 to 18 captured, then the window went to another Space and frame 19 failed, failing the run.
    @Test func keepsTheLastGoodFrameWhenTheWindowGoesAway() async throws {
        var index = 0
        let output = Self.output()
        defer { try? FileManager.default.removeItem(at: output) }
        let wait = SettleWait(timeout: .seconds(1), minimum: .seconds(5), interval: .milliseconds(10))
        try await wait.capture(to: output) { frame in
            index += 1
            guard index <= 3 else { throw ToolError("window 7681 is off screen") }
            try Self.writePNG(gray: CGFloat(index) / 4, to: frame)
        }
        #expect(index > 4)
        let third = Self.output()
        defer { try? FileManager.default.removeItem(at: third) }
        try Self.writePNG(gray: 0.75, to: third)
        #expect(SettleWait.pixels(at: output) == SettleWait.pixels(at: third))
    }

    @Test func retriesAFailedFrameAndThrowsItIfNoneWorks() async throws {
        var attempts = 0
        let output = Self.output()
        let wait = SettleWait(timeout: .milliseconds(100), minimum: .zero, interval: .milliseconds(10))
        await #expect(throws: ToolError.self) {
            try await wait.capture(to: output) { _ in
                attempts += 1
                throw ToolError("window 7681 is off screen")
            }
        }
        #expect(attempts > 1)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func aWindowThatsGoneIsSaidPlainly() {
        #expect(WindowCapture.visibility(of: .max) == .gone)
        #expect(WindowCapture.unreadable(.max).message.contains("closed"))
        #expect(WindowCapture.offScreen(7681).message.contains("another Space"))
    }
}
