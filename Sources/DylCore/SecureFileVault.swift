#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// A Codable record sealed with AES-GCM in a `0600` file. Use it for credentials that must never sit in
/// `UserDefaults` or plaintext. Reads that only open with a fallback key are re-sealed with the primary key.
public struct SecureFileVault<Record: Codable & Sendable>: Sendable {
    public let fileURL: URL
    private let key: SymmetricKey
    private let fallbackKeys: @Sendable () -> [SymmetricKey]
    private let writer = Writer()

    public init(
        fileURL: URL,
        key: SymmetricKey,
        fallbackKeys: @escaping @Sendable () -> [SymmetricKey] = { [] }
    ) {
        self.fileURL = fileURL
        self.key = key
        self.fallbackKeys = fallbackKeys
    }

    /// HKDF-SHA256 key from app-chosen material, salt and info strings.
    public static func deriveKey(material: String, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(material.utf8)),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// - Blocking: reads the vault file.
    public func read() -> Record? {
        guard let combined = try? Data(contentsOf: fileURL),
            let box = try? AES.GCM.SealedBox(combined: combined)
        else { return nil }
        if let record = open(box, with: key) { return record }
        for fallback in fallbackKeys() {
            if let record = open(box, with: fallback) {
                try? write(record)
                return record
            }
        }
        return nil
    }

    /// - Blocking: writes the vault file.
    public func write(_ record: Record) throws {
        let plaintext = try JSONEncoder().encode(record)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try combined.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// - Blocking: deletes the vault file.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func readAsync() async -> Record? {
        await writer.run { read() }
    }

    /// Read-modify-write on the vault's serial writer, so concurrent updates never drop each other's fields.
    public func updateAsync(_ change: @escaping @Sendable (inout Record?) -> Void) async throws {
        try await writer.run {
            var record = read()
            change(&record)
            if let record { try write(record) } else { clear() }
        }
    }

    public func clearAsync() async {
        await writer.run { clear() }
    }

    private func open(_ box: AES.GCM.SealedBox, with key: SymmetricKey) -> Record? {
        guard let plaintext = try? AES.GCM.open(box, using: key) else { return nil }
        do {
            return try JSONDecoder().decode(Record.self, from: plaintext)
        } catch {
            return nil
        }
    }

    private actor Writer {
        func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T { try body() }
    }
}
#endif
