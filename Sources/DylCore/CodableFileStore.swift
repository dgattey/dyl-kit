import Foundation

/// One JSON file in a `CodableFileStore`. A corrupt disposable file (a cache) is deleted; any other corrupt file is
/// moved aside as `<name>.corrupt-<timestamp>` so user data is never silently lost.
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
}

/// Atomic JSON files in one directory. `load` blocks, so call it off the main actor; `saveAsync` runs on a
/// per-store writer, so writes land in call order and never on the caller's actor.
public struct CodableFileStore: Sendable {
    public let directory: URL
    private let writer: Writer

    public init(directory: URL) {
        self.directory = directory
        writer = Writer(directory: directory)
    }

    public func url(for name: String) -> URL { directory.appending(path: name) }

    /// - Blocking: reads and possibly moves a file.
    public func load<C>(_ slot: FileSlot<C>) -> LoadResult<C> {
        let url = url(for: slot.name)
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do {
            return .loaded(try JSONDecoder().decode(C.self, from: data))
        } catch {
            return quarantine(slot, at: url)
        }
    }

    public func saveAsync<C>(_ content: C, to slot: FileSlot<C>) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await writer.write(try encoder.encode(content), to: url(for: slot.name))
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

        init(directory: URL) { self.directory = directory }

        func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}
