import Foundation

/// A `major.minor.patch` marketing version. Pre-release suffixes (`1.2.3-beta`) are dropped when parsing.
public struct AppVersion: Comparable, Hashable, Sendable, LosslessStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ description: String) {
        var text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let numbers = parts.compactMap { $0 }
        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0
        )
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public enum Bump: String, CaseIterable, Sendable {
        case major, minor, patch
    }

    public func bumped(_ bump: Bump) -> AppVersion {
        switch bump {
        case .major: AppVersion(major: major + 1, minor: 0, patch: 0)
        case .minor: AppVersion(major: major, minor: minor + 1, patch: 0)
        case .patch: AppVersion(major: major, minor: minor, patch: patch + 1)
        }
    }
}
