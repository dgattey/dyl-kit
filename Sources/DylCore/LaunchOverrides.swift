import Foundation

/// Launch-time overrides used by `devkit relaunch` and screenshot captures. Each option `name` reads from the
/// environment variable `<PREFIX>_<NAME>` (uppercased, dashes as underscores) or the argument `--name=value` /
/// `--name value`. The prefix comes from `[launch] env-prefix` in `DylApp.toml`.
public struct LaunchOverrides: Sendable {
    public let prefix: String
    public let environment: [String: String]
    public let arguments: [String]

    public init(
        prefix: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.prefix = prefix
        self.environment = environment
        self.arguments = arguments
    }

    public enum Appearance: String, Sendable {
        case light, dark
    }

    /// The option's value, lowercased. The environment wins over arguments.
    public func value(_ name: String) -> String? {
        let variable = "\(prefix)_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"
        if let value = environment[variable]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value.lowercased()
        }
        let flag = "--\(name)"
        for (index, argument) in arguments.enumerated() {
            let lowered = argument.lowercased()
            if lowered.hasPrefix("\(flag)=") {
                return String(lowered.dropFirst(flag.count + 1))
            }
            if lowered == flag, arguments.indices.contains(index + 1) {
                let next = arguments[index + 1]
                if !next.hasPrefix("--") { return next.lowercased() }
            }
        }
        return nil
    }

    /// `true` for `<PREFIX>_<NAME>=1|true|yes` or a bare `--name` argument.
    public func flag(_ name: String) -> Bool {
        let variable = "\(prefix)_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"
        if let value = environment[variable]?.lowercased() {
            return ["1", "true", "yes"].contains(value)
        }
        return arguments.contains { $0.lowercased() == "--\(name)" }
    }

    public var appearance: Appearance? { value("appearance").flatMap(Appearance.init(rawValue:)) }

    public var initialView: String? { value("initial-view") }

    /// `<width>x<height>` in points.
    public var windowSize: CGSize? {
        guard let raw = value("window-size") else { return nil }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}
