import DylLintRules
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: dyl-lint <file-or-dir>...")
    print("rules: \(Linter.rules.joined(separator: ", "))")
    exit(0)
}

let report = Linter.lint(Linter.parsedFiles(under: arguments.isEmpty ? ["Sources"] : arguments))
for finding in report.findings { print(finding) }
exit(report.errorCount > 0 ? 1 : 0)
