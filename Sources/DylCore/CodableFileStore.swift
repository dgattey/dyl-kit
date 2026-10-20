import Foundation

/// One JSON file in a `CodableFileStore`. Disposable slots (caches) are deleted when corrupt; the rest are moved
/// aside as `<name>.corrupt-<timestamp>` so user data is never silently lost.
public struct FileSlot<Content: Codable & Sendable>: Sendable {
    public let name: String
    public let isDisposable: Bool

    public init(name: String, isDisposable: Bool) {
        self.name = name
        self.isDisposable = isDisposable
    }
}

public enum LoadResult<Content: Sendable>: Sendable {
    case missing
    case loaded(Content)
    case quarantined(fileName: String)

    public var content: Content? {
        if case .loaded(let content) = self { return content }
        return nil
    }
}

/// Atomic JSON files in one directory. Synchronous methods are for background contexts; the async variants run
/// on a per-store writer so writes land in call order and never on the caller's actor.
public struct CodableFileStore: Sendable {
    public let directory: URL
    private let writer: Writer

    public init(directory: URL) {
        self.directory = directory
        self.writer = Writer(directory: directory)
    }

    public func url(for name: String) -> URL { directory.appending(path: name) }

    /// - Blocking: reads and possibly moves a file.
    public func load<C>(_ slot: FileSlot<C>) -> LoadResult<C> {
        let url = url(for: slot.name)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .missing
        }
        do {
            return .loaded(try JSONDecoder().decode(C.self, from: data))
        } catch {
            return quarantine(slot, at: url)
        }
    }

    /// - Blocking: creates the directory and writes a file.
    public func save<C>(_ content: C, to slot: FileSlot<C>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(content).write(to: url(for: slot.name), options: .atomic)
    }

    /// - Blocking: deletes a file.
    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    public func loadAsync<C>(_ slot: FileSlot<C>) async -> LoadResult<C> {
        await writer.run { load(slot) }
    }

    public func saveAsync<C>(_ content: C, to slot: FileSlot<C>) async throws {
        let data = try Self.encode(content)
        try await writer.write(data, to: url(for: slot.name))
    }

    private static func encode<C: Encodable>(_ content: C) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(content)
    }

    private func quarantine<C>(_ slot: FileSlot<C>, at url: URL) -> LoadResult<C> {
        if slot.isDisposable {
            try? FileManager.default.removeItem(at: url)
            return .missing
        }
        let fileName = "\(slot.name).corrupt-\(Int(Date().timeIntervalSince1970))"
        do {
            try FileManager.default.moveItem(at: url, to: self.url(for: fileName))
            return .quarantined(fileName: fileName)
        } catch {
            return .quarantined(fileName: slot.name)
        }
    }

    private actor Writer {
        let directory: URL
        private var directoryExists = false

        init(directory: URL) { self.directory = directory }

        func run<T: Sendable>(_ body: @Sendable () -> T) -> T { body() }

        func write(_ data: Data, to url: URL) throws {
            if !directoryExists {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                directoryExists = true
            }
            try data.write(to: url, options: .atomic)
        }
    }
}
