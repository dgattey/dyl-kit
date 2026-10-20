import Foundation
import SwiftParser
import SwiftSyntax

public struct ParsedFile {
    public let path: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter
    let suppressions: Suppressions

    public init(path: String, source: String) {
        self.path = path
        tree = Parser.parse(source: source)
        converter = SourceLocationConverter(fileName: path, tree: tree)
        suppressions = Suppressions(tree: tree, converter: converter)
    }

    func finding(_ node: some SyntaxProtocol, rule: String, severity: Severity, _ message: String) -> Finding {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return Finding(
            file: path,
            line: location.line,
            column: location.column,
            rule: rule,
            severity: severity,
            message: message
        )
    }
}

public struct LintReport: Sendable {
    public let findings: [Finding]
    /// `lint:allow` comments that silenced a finding, so CI can print the count.
    public let allowedCount: Int

    public var errorCount: Int { findings.filter { $0.severity == .error }.count }
    public var warningCount: Int { findings.filter { $0.severity == .warning }.count }
}

public enum Linter {
    public static let rules = [
        MainActorBlockingIO.rule, CancellationBlindPoll.rule, PublishedWriteOffMain.rule,
        PublishedWriteOffMain.transitionalRule, HotCallbackStateWrite.rule, FormatterAlloc.rule,
        DelegateMainActorHop.rule, SessionAlloc.rule,
    ]

    public static func lint(_ files: [ParsedFile]) -> LintReport {
        let typeCollector = MainActorTypeCollector()
        for file in files { typeCollector.walk(file.tree) }
        let mainTypes = typeCollector.mainTypes
        let stateTypes = collectStateTypes(files)

        var raw = MainActorBlockingIO.run(files, mainTypes: mainTypes)
        raw += PublishedWriteOffMain.run(files, types: stateTypes)
        raw += HotCallbackStateWrite.run(files, types: stateTypes)
        for file in files {
            raw += CancellationBlindPoll.run(file)
            raw += FormatterAlloc.run(file)
            raw += DelegateMainActorHop.run(file)
            raw += SessionAlloc.run(file)
        }

        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [Finding] = []
        var allowed = 0
        for finding in Set(raw) {
            if byPath[finding.file]?.suppressions.allows(finding.rule, at: finding.line) == true {
                allowed += 1
            } else {
                kept.append(finding)
            }
        }
        kept.sort { ($0.file, $0.line, $0.column, $0.rule) < ($1.file, $1.line, $1.column, $1.rule) }
        return LintReport(findings: kept, allowedCount: allowed)
    }

    /// Parsed Swift sources under each path. Unreadable files are skipped.
    ///
    /// - Blocking: walks the file system and reads each source.
    public static func parsedFiles(under paths: [String]) -> [ParsedFile] {
        swiftFiles(under: paths).compactMap { path in
            (try? String(contentsOfFile: path, encoding: .utf8)).map { ParsedFile(path: path, source: $0) }
        }
    }

    /// Swift files under each path, skipping build products.
    ///
    /// - Blocking: walks the file system.
    static func swiftFiles(under paths: [String]) -> [String] {
        let fileManager = FileManager.default
        var result: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if path.hasSuffix(".swift") { result.append(path) }
                continue
            }
            let enumerator = fileManager.enumerator(atPath: path)
            while let relative = enumerator?.nextObject() as? String {
                guard relative.hasSuffix(".swift"), !relative.contains(".build/") else { continue }
                result.append((path as NSString).appendingPathComponent(relative))
            }
        }
        return result.sorted()
    }
}
