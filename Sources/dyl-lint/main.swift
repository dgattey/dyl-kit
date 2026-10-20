import DylLintRules
import Foundation

// dyl-lint [--strict] [--summary] [--stamp <file>] <file-or-dir>...
//
// Prints findings in compiler format and exits 1 on any error, or on any warning with --strict. The build-tool
// plugin passes --stamp so SwiftPM can skip the run when no source changed.

var strict = false
var summary = false
var stamp: String?
var paths: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--strict": strict = true
    case "--summary": summary = true
    case "--stamp": stamp = arguments.popFirst()
    case "--help", "-h":
        print("usage: dyl-lint [--strict] [--summary] [--stamp <file>] <file-or-dir>...")
        print("rules: \(Linter.rules.joined(separator: ", "))")
        exit(0)
    default: paths.append(argument)
    }
}

let files = Linter.swiftFiles(under: paths.isEmpty ? ["Sources"] : paths).compactMap { path -> ParsedFile? in
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("dyl-lint: can't read \(path)\n".utf8))
        return nil
    }
    return ParsedFile(path: path, source: source)
}
let report = Linter.lint(files)
for finding in report.findings { print(finding) }

if summary {
    let counts = Dictionary(grouping: report.findings, by: \.rule).mapValues(\.count)
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
    let detail = counts.isEmpty ? "" : " (\(counts.joined(separator: " ")))"
    print(
        "dyl-lint: \(files.count) files, \(report.errorCount) errors, \(report.warningCount) warnings\(detail), "
            + "\(report.allowedCount) lint:allow"
    )
}

let failed = report.errorCount > 0 || (strict && report.warningCount > 0)
if !failed, let stamp {
    _ = FileManager.default.createFile(atPath: stamp, contents: Data())
}
exit(failed ? 1 : 0)
