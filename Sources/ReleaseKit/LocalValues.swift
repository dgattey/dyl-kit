import DylManifest
import DylToolSupport
import Foundation

/// `[local-values]` resolved for one build. Values are secrets in practice, so nothing here logs one.
public struct ResolvedLocalValues: Equatable, Sendable {
    public var values: [String: String] = [:]
    /// Where each key's value came from: `env`, the file's name, or `defaults`.
    public var sources: [String: String] = [:]

    /// "3 local values from Config.xcconfig, env", never the values.
    public var summary: String {
        let origins = Set(sources.values).sorted().joined(separator: ", ")
        return "\(values.count) local value\(values.count == 1 ? "" : "s")\(origins.isEmpty ? "" : " from \(origins)")"
    }

    public static func resolve(
        _ config: DylAppManifest.LocalValues?, fileText: String?, environment: [String: String]
    ) -> ResolvedLocalValues {
        guard let config else { return ResolvedLocalValues() }
        let file = fileText.map(XCConfig.parse) ?? [:]
        let fileName = config.file.map { ($0 as NSString).lastPathComponent } ?? "file"
        var resolved = ResolvedLocalValues()
        for (key, variable) in config.keys {
            let candidates = [(environment[variable], "env"), (file[variable], fileName), (config.defaults[key], "defaults")]
            guard let (value, source) = candidates.first(where: { $0.0 != nil }), let value else { continue }
            resolved.values[key] = value
            resolved.sources[key] = source
        }
        return resolved
    }

    /// - Blocking: reads the local file.
    public static func resolve(_ workspace: Workspace) -> ResolvedLocalValues {
        let config = workspace.manifest.localValues
        let text = config?.file.flatMap { try? String(contentsOf: workspace.url($0), encoding: .utf8) }
        return resolve(config, fileText: text, environment: ProcessInfo.processInfo.environment)
    }
}

/// The xcconfig subset local files use: `NAME = value` lines, `//` comments, blank lines; the last assignment wins.
enum XCConfig {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = Substring(rawLine)
            if let comment = line.range(of: "//") { line = line[..<comment.lowerBound] }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
