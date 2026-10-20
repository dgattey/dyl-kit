import Foundation

/// Launch-time state for screenshots and agent runs, set by `devkit relaunch` and `devkit ios`. Option `name` reads
/// the environment variable `<PREFIX>_<NAME>` (uppercased, dashes as underscores), then the argument `--name=value`
/// or `--name value`. The prefix is `[launch] env-prefix` in `DylApp.toml`.
public struct LaunchOverrides: Sendable {
    public let prefix: String
    private let environment: [String: String]
    private let arguments: [String]

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

    /// The option's value, lowercased, or nil when unset.
    public func value(_ name: String) -> String? {
        if let value = environment[variable(name)]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value.lowercased()
        }
        let flag = "--\(name)"
        for (index, argument) in arguments.enumerated() {
            let lowered = argument.lowercased()
            if lowered.hasPrefix("\(flag)=") { return String(lowered.dropFirst(flag.count + 1)) }
            if lowered == flag, arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") {
                return arguments[index + 1].lowercased()
            }
        }
        return nil
    }

    /// `true` for `<PREFIX>_<NAME>=1|true|yes` or a bare `--name`.
    public func flag(_ name: String) -> Bool {
        if let value = environment[variable(name)]?.lowercased() { return ["1", "true", "yes"].contains(value) }
        return arguments.contains { $0.lowercased() == "--\(name)" }
    }

    public var appearance: Appearance? { value("appearance").flatMap(Appearance.init(rawValue:)) }

    public var initialView: String? { value("initial-view") }

    /// `<width>x<height>` in points.
    public var windowSize: CGSize? {
        let parts = value("window-size")?.split(separator: "x").compactMap { Double($0) } ?? []
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    private func variable(_ name: String) -> String {
        "\(prefix)_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"
    }
}
