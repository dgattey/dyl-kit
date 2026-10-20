import Foundation

/// Per-app storage locations.
public struct AppDirectories: Sendable {
    public let applicationSupport: URL

    public init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
    }

    /// `~/Library/Application Support/<folder>`.
    public init(folder: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(applicationSupport: base.appending(path: folder))
    }

    /// The Mac user's Application Support folder when running in the iOS simulator, so simulator builds can seed
    /// themselves from the Mac app's files. `nil` everywhere else.
    public static func simulatorHostApplicationSupport(
        folder: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        #if targetEnvironment(simulator)
        guard let hostHome = environment["SIMULATOR_HOST_HOME"], !hostHome.isEmpty else { return nil }
        return URL(fileURLWithPath: hostHome).appending(path: "Library/Application Support/\(folder)")
        #else
        return nil
        #endif
    }

    /// Copies each named file from `source` into `applicationSupport` when the destination is missing or older.
    ///
    /// - Blocking: file system copies.
    public func seed(from source: URL, fileNames: [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        try? fm.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        for name in fileNames {
            let src = source.appending(path: name)
            let dst = applicationSupport.appending(path: name)
            guard let srcDate = modificationDate(src) else { continue }
            if let dstDate = modificationDate(dst) {
                guard srcDate > dstDate else { continue }
                try? fm.removeItem(at: dst)
            }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
