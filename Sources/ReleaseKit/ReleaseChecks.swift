import DylManifest
import DylToolSupport
import Foundation

public struct CheckFinding: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error, warning
    }

    public let rule: String
    public let severity: Severity
    public let file: String?
    public let message: String

    public var description: String { "\(file ?? "release-kit"): \(severity.rawValue): \(message) [\(rule)]" }
}

public struct CheckReport: Sendable {
    public var findings: [CheckFinding] = []
    public var checked: [String] = []

    public var passed: Bool { !findings.contains { $0.severity == .error } }

    public func print() {
        for finding in findings { FileHandle.standardError.write(Data("\(finding)\n".utf8)) }
        let errors = findings.filter { $0.severity == .error }.count
        Log.step("\(checked.count) checks, \(errors) errors, \(findings.count - errors) warnings")
    }
}

/// Tier 3: release and workflow invariants, checked against the real files (manifest, `Package.swift`,
/// workflows, the committed appcast and, when given, a staged release).
public struct ReleaseChecks: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    private var manifest: DylAppManifest { workspace.manifest }

    /// - Blocking: reads repo files.
    public func run(
        stagedAppcast: URL? = nil, stagedArchive: URL? = nil, liveFeed: [AppcastItem] = []
    ) -> CheckReport {
        var report = CheckReport()
        func check(_ rule: String, _ body: (inout [CheckFinding]) -> Void) {
            report.checked.append(rule)
            var found: [CheckFinding] = []
            body(&found)
            report.findings += found
        }
        check("sparkle_public_key", checkPublicKey)
        check("swift_language_mode", checkPackageManifests)
        check("min_os_consistency", checkMinimumOS)
        check("swiftpm_only", checkNoXcodeProject)
        check("appcast_signature", checkCommittedAppcast)
        check("release_trigger_drift", checkTriggerDrift)
        check("unused_ci_secret", checkSecrets)
        check("forge_neutral", checkForgeNeutral)
        check("workflow_hygiene", checkWorkflowHygiene)
        check("pr_template_contract", checkPRTemplate)
        check("library_validation", checkLibraryValidation)
        check("site_deploy", checkSiteDeploy)
        if let stagedAppcast, let stagedArchive {
            check("staged_release") {
                checkStaged(appcast: stagedAppcast, archive: stagedArchive, liveFeed: liveFeed, into: &$0)
            }
        }
        return report
    }

    // MARK: - Repo

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: workspace.url(relative), encoding: .utf8)
    }

    private func error(_ rule: String, _ file: String?, _ message: String) -> CheckFinding {
        CheckFinding(rule: rule, severity: .error, file: file, message: message)
    }

    private var publicKey: String? {
        read(manifest.release.sparklePublicKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkPublicKey(_ findings: inout [CheckFinding]) {
        let file = manifest.release.sparklePublicKey
        guard let key = publicKey else {
            findings.append(error("sparkle_public_key", file, "missing; run scripts/generate-sparkle-key.sh"))
            return
        }
        if Data(base64Encoded: key)?.count != 32 {
            findings.append(error("sparkle_public_key", file, "isn't a base64 Ed25519 public key (32 bytes)"))
        }
    }

    private var packageManifests: [String] {
        var paths = ["Package.swift"]
        let packages = (try? FileManager.default.contentsOfDirectory(atPath: workspace.url("Packages").path)) ?? []
        paths += packages.sorted().map { "Packages/\($0)/Package.swift" }.filter { read($0) != nil }
        return paths
    }

    private func checkPackageManifests(_ findings: inout [CheckFinding]) {
        for path in packageManifests {
            guard let text = read(path) else { continue }
            if let tools = text.firstMatch(of: /swift-tools-version:\s*(\d+)/), (Int(tools.1) ?? 0) < 6 {
                findings.append(
                    error("swift_language_mode", path, "swift-tools-version is \(tools.1); use 6.0 or later"))
            }
            if text.matches(pattern: #"swiftLanguage(?:Modes|Versions)\s*:\s*\[[^\]]*\.v[45]"#) {
                findings.append(error("swift_language_mode", path, "pins Swift 5 language mode; use Swift 6"))
            }
            if text.contains("unsafeFlags") {
                findings.append(
                    error("swift_language_mode", path, "uses unsafeFlags, which SwiftPM rejects in dependencies"))
            }
        }
    }

    private func checkNoXcodeProject(_ findings: inout [CheckFinding]) {
        let enumerator = FileManager.default.enumerator(atPath: workspace.root.path)
        while let path = enumerator?.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") || name == "build" || name == "node_modules" {
                enumerator?.skipDescendants()
            } else if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                findings.append(error("swiftpm_only", path, "DylKit apps build with SwiftPM only; delete it"))
                enumerator?.skipDescendants()
            }
        }
    }

    private func checkMinimumOS(_ findings: inout [CheckFinding]) {
        let macOS = manifest.app.platforms.macos
        if let text = read("Package.swift") {
            let expected = macOS.split(separator: ".").first.map(String.init) ?? macOS
            if let declared = text.firstMatch(of: /\.macOS\(\.v(\d+)(?:_\d+)?\)/), String(declared.1) != expected {
                findings.append(
                    error(
                        "min_os_consistency", "Package.swift", ".macOS(.v\(declared.1)) but DylApp.toml says \(macOS)"))
            }
            if let iOS = manifest.app.platforms.ios, let declared = text.firstMatch(of: /\.iOS\(\.v(\d+)(?:_\d+)?\)/),
                String(declared.1) != (iOS.split(separator: ".").first.map(String.init) ?? iOS)
            {
                findings.append(
                    error("min_os_consistency", "Package.swift", ".iOS(.v\(declared.1)) but DylApp.toml says \(iOS)"))
            }
        }
        let appcastPath = workspace.appcastPath
        if let item = Appcast.items(at: workspace.appcastURL).first, let published = item.minimumSystemVersion,
            published != macOS
        {
            findings.append(
                error(
                    "min_os_consistency", appcastPath, "minimumSystemVersion is \(published), DylApp.toml says \(macOS)"
                ))
        }
    }

    private func checkCommittedAppcast(_ findings: inout [CheckFinding]) {
        let appcastPath = workspace.appcastPath
        guard let item = Appcast.items(at: workspace.appcastURL).first else { return }
        guard let signature = item.edSignature, !signature.isEmpty else {
            findings.append(error("appcast_signature", appcastPath, "newest item has no sparkle:edSignature"))
            return
        }
        guard let enclosure = item.enclosureURL, let name = enclosure.split(separator: "/").last.map(String.init) else {
            findings.append(error("appcast_signature", appcastPath, "newest item has no enclosure URL"))
            return
        }
        let archive = workspace.artifactsDir.appending(path: name)
        guard let data = try? Data(contentsOf: archive) else {
            findings.append(error("appcast_signature", appcastPath, "names \(name), which isn't committed next to it"))
            return
        }
        if let length = item.enclosureLength, length != data.count {
            findings.append(
                error("appcast_signature", appcastPath, "enclosure length \(length) != \(name) size \(data.count)"))
        }
        guard let publicKey else { return }
        switch EdSignature.verify(archive: data, signature: signature, publicKey: publicKey) {
        case .valid: break
        case .invalid(let reason): findings.append(error("appcast_signature", appcastPath, "\(name): \(reason)"))
        case .unverifiable:
            findings.append(
                CheckFinding(
                    rule: "appcast_signature", severity: .warning, file: appcastPath,
                    message: "can't verify edSignature on this platform; CI verifies it on macOS"))
        }
    }

    // MARK: - Workflows

    private struct Workflow {
        let path: String
        let text: String

        /// A workflow that versions, signs or publishes a release, through release-kit or the scripts it replaces.
        var runsRelease: Bool {
            text.matches(
                pattern:
                    #"(?:release-kit|run release) (?:release|version|appcast|publish)\b|generate_appcast|SPARKLE_ED_PRIVATE_KEY"#
            )
        }

        /// Items of the `paths:` list under `on.push`.
        var pushPaths: [String]? {
            let lines = text.components(separatedBy: "\n")
            guard let push = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "push:" }) else {
                return nil
            }
            let pushIndent = lines[push].prefix { $0 == " " }.count
            var index = push + 1
            while index < lines.count {
                let line = lines[index]
                let indent = line.prefix { $0 == " " }.count
                if !line.trimmingCharacters(in: .whitespaces).isEmpty, indent <= pushIndent { return nil }
                if line.trimmingCharacters(in: .whitespaces) == "paths:" { break }
                index += 1
            }
            guard index < lines.count else { return nil }
            let pathsIndent = lines[index].prefix { $0 == " " }.count
            var items: [String] = []
            for line in lines[(index + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- "), line.prefix(while: { $0 == " " }).count > pathsIndent else { break }
                items.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")))
            }
            return items
        }
    }

    private var workflows: [Workflow] {
        let directory = ".github/workflows"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.url(directory).path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.compactMap { name in
            let path = "\(directory)/\(name)"
            return read(path).map { Workflow(path: path, text: $0) }
        }
    }

    private func checkTriggerDrift(_ findings: inout [CheckFinding]) {
        for workflow in workflows where workflow.runsRelease {
            let expected = Set(workspace.manifest.release.inputs)
            guard let paths = workflow.pushPaths else {
                findings.append(
                    error("release_trigger_drift", workflow.path, "release runs on every push; add `paths:`"))
                continue
            }
            let actual = Set(paths)
            let missing = expected.subtracting(actual).sorted()
            let extra = actual.subtracting(expected).sorted()
            if !missing.isEmpty {
                findings.append(
                    error(
                        "release_trigger_drift", workflow.path,
                        "doesn't trigger on release inputs \(missing.joined(separator: ", ")) from DylApp.toml"))
            }
            if !extra.isEmpty {
                findings.append(
                    error(
                        "release_trigger_drift", workflow.path,
                        "triggers on \(extra.joined(separator: ", ")), which DylApp.toml's release.inputs doesn't list")
                )
            }
        }
    }

    private func checkSecrets(_ findings: inout [CheckFinding]) {
        let readers = toolSources()
        var referenced: Set<String> = []
        for workflow in workflows {
            for match in workflow.text.matches(of: /(\w+):\s*\$\{\{\s*secrets\.(\w+)\s*\}\}/) {
                let variable = String(match.1)
                referenced.insert(String(match.2))
                let readElsewhere = readers.contains { $0.text.contains(variable) }
                let readInWorkflow = workflow.text.matches(pattern: #"\$\{?\#(variable)\b"#)
                if !readElsewhere, !readInWorkflow {
                    findings.append(
                        error(
                            "unused_ci_secret", workflow.path,
                            "passes secret \(match.2) as \(variable), but nothing reads \(variable)"))
                }
            }
            for match in workflow.text.matches(of: /secrets\.(\w+)/) { referenced.insert(String(match.1)) }
        }
        for source in readers where source.path.hasPrefix("scripts/") {
            for match in source.text.matches(of: /(?:gh\s+secret\s+set|push_\w*secret)\s+"?([A-Z][A-Z0-9_]+)/)
            where !referenced.contains(String(match.1)) {
                findings.append(
                    error("unused_ci_secret", source.path, "uploads secret \(match.1), which no workflow uses"))
            }
        }
    }

    private struct Source {
        let path: String
        let text: String
    }

    private func toolSources() -> [Source] {
        var sources: [Source] = []
        for directory in ["scripts", "ci", "Packages/DylKit/Sources"] {
            let enumerator = FileManager.default.enumerator(atPath: workspace.url(directory).path)
            while let relative = enumerator?.nextObject() as? String {
                let path = "\(directory)/\(relative)"
                if let text = read(path) { sources.append(Source(path: path, text: text)) }
            }
        }
        if let run = read("run") { sources.append(Source(path: "run", text: run)) }
        return sources
    }

    private func checkForgeNeutral(_ findings: inout [CheckFinding]) {
        let forgeAPIs = [
            (#"(?m)(?:^|[\s;&|(])gh\s+(?:release|api|pr)\b"#, "calls the gh CLI"),
            (#"api\.github\.com"#, "calls the GitHub API"),
            (#"actions/github\-script"#, "uses the github-script action"),
            (#"action\-gh\-release"#, "uploads a GitHub Release"),
        ]
        let releaseWorkflows = workflows.filter(\.runsRelease).map { Source(path: $0.path, text: $0.text) }
        for source in releaseWorkflows + toolSources() where !source.path.hasPrefix("ci/github/") {
            for (pattern, problem) in forgeAPIs where source.text.matches(pattern: pattern) {
                findings.append(
                    error(
                        "forge_neutral", source.path,
                        "\(problem); only the thin wrapper in ci/github/ may talk to the forge"))
            }
        }
    }

    private func checkWorkflowHygiene(_ findings: inout [CheckFinding]) {
        for workflow in workflows where workflow.runsRelease {
            if !workflow.text.contains("concurrency:") || !workflow.text.contains("cancel-in-progress: false") {
                findings.append(
                    error(
                        "workflow_hygiene", workflow.path,
                        "releases must run one at a time without cancelling (`concurrency` + `cancel-in-progress: false`)"
                    ))
            }
        }
    }

    private func checkPRTemplate(_ findings: inout [CheckFinding]) {
        let path = ".github/pull_request_template.md"
        guard let text = read(path) else {
            findings.append(
                error("pr_template_contract", nil, "no PR template; release-kit reads its Release info checkboxes"))
            return
        }
        if !text.matches(pattern: #"(?im)^#+\s*Release info\s*$"#) {
            findings.append(error("pr_template_contract", path, "has no `# Release info` section"))
        }
        for name in ["Major", "Minor", "Patch"] where !text.matches(pattern: "(?m)^\\s*-\\s*\\[[ xX]\\]\\s*\(name)\\b")
        {
            findings.append(error("pr_template_contract", path, "has no `- [ ] \(name)` checkbox"))
        }
        if !ReleaseInfo.notesHeadings.contains(where: { text.matches(pattern: "(?im)^#+\\s*\(regexEscaped($0))\\s*$") })
        {
            findings.append(error("pr_template_contract", path, "has no `# Release notes` section"))
        }
    }

    /// Ad-hoc signed apps load embedded frameworks only with library validation off: without the entitlement, dyld
    /// rejects Sparkle.framework at launch because it isn't signed by the same team.
    private func checkLibraryValidation(_ findings: inout [CheckFinding]) {
        let file = manifest.build.entitlements
        let entitlements = InfoPlist.read(workspace.url(file))
        if entitlements?[Self.libraryValidationKey] != .boolean(true) {
            findings.append(
                error("library_validation", file, "embeds Sparkle.framework but doesn't set \(Self.libraryValidationKey)"))
        }
    }

    static let libraryValidationKey = "com.apple.security.cs.disable-library-validation"

    /// Vercel deploys the site from its root directory and skips commits its `ignoreCommand` says didn't touch it.
    /// That command must still deploy release commits, which only touch the artifacts dir, and changes to what the
    /// site builds from outside its root: `file:` packages and, for `@dylkit/web`, DylApp.toml (Saga #45).
    private struct VercelConfig: Decodable {
        var ignoreCommand: String?
    }

    private func checkSiteDeploy(_ findings: inout [CheckFinding]) {
        var siteRoot = (manifest.release.artifactsDir as NSString).deletingLastPathComponent
        while !siteRoot.isEmpty, read("\(siteRoot)/package.json") == nil {
            siteRoot = (siteRoot as NSString).deletingLastPathComponent
        }
        guard !siteRoot.isEmpty, let package = read("\(siteRoot)/package.json") else { return }
        let file = "\(siteRoot)/vercel.json"
        let config = read(file).flatMap { try? JSONDecoder().decode(VercelConfig.self, from: Data($0.utf8)) }
        let command = config?.ignoreCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let prefix = "git diff --quiet HEAD^ HEAD -- "
        guard command.hasPrefix(prefix) else {
            findings.append(
                error("site_deploy", file, "needs `\"ignoreCommand\": \"\(prefix)<paths>\"` so app-only commits don't deploy"))
            return
        }
        let watched = command.dropFirst(prefix.count).split(separator: " ").map { path in
            workspace.url(siteRoot).appending(path: String(path)).standardized.path
        }
        var needed = [manifest.release.artifactsDir]
        for match in package.matches(of: /"file:([^"]+)"/) {
            needed.append(workspace.url(siteRoot).appending(path: String(match.1)).standardized.path)
        }
        if package.contains("\"@dylkit/web\"") { needed.append(DylAppManifest.fileName) }
        for path in needed {
            let absolute = path.hasPrefix("/") ? path : workspace.url(path).standardized.path
            guard !watched.contains(where: { absolute == $0 || absolute.hasPrefix($0 + "/") }) else { continue }
            let relative = absolute.replacingOccurrences(of: workspace.root.standardized.path + "/", with: "")
            findings.append(error("site_deploy", file, "ignoreCommand skips commits that only change \(relative)"))
        }
    }

    // MARK: - Staged release

    /// The build must beat both the committed feed and the live one, which can be ahead of a stale checkout. The
    /// `check` step after install covers everything else in the new feed.
    private func checkStaged(appcast: URL, archive: URL, liveFeed: [AppcastItem], into findings: inout [CheckFinding]) {
        let file = appcast.path
        guard let item = Appcast.items(at: appcast).first else {
            findings.append(error("staged_release", file, "has no items"))
            return
        }
        let published = Appcast.items(at: workspace.appcastURL) + liveFeed
        if let newBuild = item.build.flatMap({ Int($0) }),
            let oldBuild = published.compactMap({ $0.build.flatMap { Int($0) } }).max(), newBuild <= oldBuild
        {
            findings.append(
                error("build_number_monotonic", file, "build \(newBuild) isn't above the published build \(oldBuild)"))
        }
        let expectedURL = manifest.release.siteUrl.trimmingSuffix("/") + "/" + archive.lastPathComponent
        if item.enclosureURL != expectedURL {
            findings.append(
                error("staged_release", file, "enclosure is \(item.enclosureURL ?? "missing"), expected \(expectedURL)")
            )
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
