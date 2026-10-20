import Testing

@testable import DylLintRules

private func lint(_ sources: [String: String]) -> LintReport {
    Linter.lint(sources.sorted { $0.key < $1.key }.map { ParsedFile(path: $0.key, source: $0.value) })
}

private func lint(_ source: String) -> LintReport { lint(["A.swift": source]) }

private func rules(_ report: LintReport) -> [String] { report.findings.map(\.rule) }

@Suite struct MainActorBlockingIOTests {
    @Test func flagsDirectReadOnMainActor() {
        let report = lint(
            """
            import Foundation
            @MainActor final class Model {
                func load(_ url: URL) -> Data? { try? Data(contentsOf: url) }
            }
            """
        )
        #expect(rules(report) == ["main_actor_blocking_io"])
        #expect(report.findings.first?.severity == .error)
    }

    @Test func reportsOnlyTheOutermostMainActorCallSite() {
        let report = lint(
            """
            import Foundation
            @MainActor final class Store {
                func persist() { save() }
                private func save() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            }
            @MainActor struct Screen {
                let store: Store
                func tap() { store.persist() }
            }
            """
        )
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.line == 8)
    }

    @Test func honorsBlockingDocMarker() {
        let report = lint(
            """
            import Foundation
            enum Files {
                /// Reads a slice.
                ///
                /// - Blocking: reads from disk.
                static func read() -> Data? { nil }
            }
            @MainActor final class Model {
                func refresh() { _ = Files.read() }
            }
            """
        )
        #expect(rules(report) == ["main_actor_blocking_io"])
    }

    @Test func ignoresWorkMovedOffMain() {
        let report = lint(
            """
            import Foundation
            @MainActor final class Model {
                func load(_ url: URL) {
                    Task.detached { _ = try? Data(contentsOf: url) }
                }
            }
            actor Disk {
                func load(_ url: URL) -> Data? { try? Data(contentsOf: url) }
            }
            """
        )
        #expect(report.findings.isEmpty)
    }

    @Test func ignoresGestureBuilderClosures() {
        let report = lint(
            """
            import SwiftUI
            @MainActor final class Store {
                func move() { try? FileManager.default.removeItem(at: url) }
            }
            struct MapView: View {
                let store: Store
                var body: some View {
                    Color.clear.gesture(drag())
                }
                func drag() -> some Gesture {
                    DragGesture().onEnded { _ in store.move() }
                }
            }
            """
        )
        #expect(report.findings.map(\.line) == [11])
    }

    @Test func flagsCryptoAndSleeps() {
        let report = lint(
            """
            import CryptoKit
            import Foundation
            @MainActor final class Vault {
                func seal(_ data: Data, key: SymmetricKey) { _ = try? AES.GCM.seal(data, using: key) }
                func nap() { Thread.sleep(forTimeInterval: 1) }
            }
            """
        )
        #expect(report.findings.count == 2)
    }
}

@Suite struct CancellationBlindPollTests {
    @Test func flagsUnboundedSwallowedSleep() {
        let report = lint(
            """
            func poll() async {
                while true {
                    try? await Task.sleep(for: .seconds(1))
                    await fetch()
                }
            }
            """
        )
        #expect(rules(report) == ["cancellation_blind_poll"])
    }

    @Test func flagsDeadlineLoop() {
        let report = lint(
            """
            func wait() async {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            """
        )
        #expect(rules(report) == ["cancellation_blind_poll"])
    }

    @Test func acceptsCancellationChecksAndQueueDrains() {
        let report = lint(
            """
            func poll() async {
                while true {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
            }
            func drain() async {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            func flush(_ queue: inout [Int: Int]) async {
                while let next = queue.removeValue(forKey: 1) {
                    try? await Task.sleep(for: .milliseconds(75))
                    _ = next
                }
            }
            func strict() async throws {
                while true { try await Task.sleep(for: .seconds(1)) }
            }
            """
        )
        #expect(report.findings.isEmpty)
    }
}

@Suite struct HotCallbackStateWriteTests {
    @Test func flagsUnguardedWritesAndSkipsGuardedOrTrackingOnes() {
        let report = lint(
            """
            import SwiftUI
            struct MapView: View {
                @State private var dragging: Int?
                @State private var point: CGPoint = .zero
                @State private var target: Int?
                @State private var offset: CGFloat = 0
                var body: some View {
                    Color.clear
                        .gesture(
                            DragGesture().onChanged { value in
                                dragging = 1
                                point = value.location
                                let next = nearest(value.location)
                                if next != target { target = next }
                            }
                        )
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                            offset = 4
                        }
                        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 0 } action: { _, new in
                            offset = 9
                        }
                }
                func nearest(_ point: CGPoint) -> Int? { nil }
            }
            """
        )
        #expect(rules(report) == ["hot_callback_state_write", "hot_callback_state_write"])
        #expect(report.findings.map(\.line) == [11, 18])
        #expect(report.findings.allSatisfy { $0.severity == .warning })
    }
}

@Suite struct PublishedWriteOffMainTests {
    @Test func flagsWriteFromDetachedTask() {
        let report = lint(
            """
            import Combine
            final class Model: ObservableObject {
                @Published var items: [Int] = []
                func reload() {
                    DispatchQueue.global().async { self.clear() }
                }
                private func clear() { items = [] }
            }
            """
        )
        #expect(Set(rules(report)) == ["published_write_off_main", "observable_not_main_actor"])
    }

    @Test func flagsObservableObjectWithoutMainActor() {
        let report = lint(
            """
            import Combine
            final class Model: ObservableObject {
                @Published var items: [Int] = []
            }
            """
        )
        #expect(rules(report) == ["observable_not_main_actor"])
    }

    @Test func acceptsMainActorWrites() {
        let report = lint(
            """
            import Combine
            @MainActor final class Model: ObservableObject {
                @Published var items: [Int] = []
                func reload() async {
                    let fresh = await Task.detached { [1, 2] }.value
                    items = fresh
                }
            }
            """
        )
        #expect(report.findings.isEmpty)
    }
}

@Suite struct AllocationAndDelegateTests {
    @Test func flagsPerCallFormatterOnly() {
        let report = lint(
            """
            import Foundation
            enum Format {
                static let shared = ISO8601DateFormatter()
                static func stamp(_ date: Date) -> String {
                    let formatter = DateFormatter()
                    return formatter.string(from: date) + shared.string(from: date)
                }
            }
            """
        )
        #expect(rules(report) == ["formatter_alloc"])
        #expect(report.findings.first?.line == 5)
    }

    @Test func flagsPerCallBoundedSessionOnly() {
        let report = lint(
            """
            import Foundation
            private let artwork = URLSession.bounded(cache: .shared)
            enum API {
                static let session = URLSession.bounded()
                static func load(_ url: URL) async throws -> Data {
                    try await URLSession.bounded().data(from: url).0
                }
            }
            """
        )
        #expect(rules(report) == ["session_alloc"])
        #expect(report.findings.first?.line == 6)
    }

    @Test func flagsMainActorHopInDelegateCallback() {
        let report = lint(
            """
            import Foundation
            final class Delegate: NSObject, URLSessionDelegate {
                func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
                    Task { @MainActor in self.finish() }
                }
                func finish() {}
            }
            """
        )
        #expect(rules(report) == ["delegate_mainactor_hop"])
    }
}

@Suite struct SuppressionTests {
    @Test func lintAllowWithReasonSilencesAndCounts() {
        let report = lint(
            """
            import Foundation
            @MainActor final class Model {
                // lint:allow main_actor_blocking_io: a 200-byte config read once at launch
                func load(_ url: URL) -> Data? { try? Data(contentsOf: url) }
            }
            """
        )
        #expect(report.findings.isEmpty)
        #expect(report.allowedCount == 1)
    }

    @Test func lintAllowWithoutReasonDoesNotSuppress() {
        let report = lint(
            """
            import Foundation
            @MainActor final class Model {
                func load(_ url: URL) -> Data? { try? Data(contentsOf: url) } // lint:allow main_actor_blocking_io
            }
            """
        )
        #expect(rules(report) == ["main_actor_blocking_io"])
        #expect(report.allowedCount == 0)
    }
}
