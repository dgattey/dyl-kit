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
/// workflows, the staged appcast in `build/release/` and, when given, what's published).
public struct ReleaseChecks: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    private var manifest: DylAppManifest { workspace.manifest }

    /// A staged release and what it must replace.
    public struct StagedRelease: Sendable {
        public var appcast: URL
        public var archive: URL
        /// Where the Blob store serves the release's zip.
        public var downloadPrefix: String
        /// Every item in the published feeds.
        public var published: [AppcastItem]
    }

    /// - Blocking: reads repo files.
    public func run(staged: StagedRelease? = nil) -> CheckReport {
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
        check("appcast_signature", checkStagedAppcast)
        check("unused_ci_secret", checkSecrets)
        check("forge_neutral", checkForgeNeutral)
        check("library_validation", checkLibraryValidation)
        check("site_deploy", checkSiteDeploy)
        check("dylkit_web_version", checkWebMatchesPin)
        check("site_icons", checkSiteIcons)
        check("resource_not_excluded", checkResourcesExcluded)
        check("local_values_ignored", checkLocalValuesIgnored)
        check("shared_files", checkSharedFiles)
        if let staged {
            check("staged_release") { checkStaged(staged, into: &$0) }
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

    private func checkSharedFiles(_ findings: inout [CheckFinding]) {
        // Without `./run` there's no `./run dev`; SwiftPM runs a dependency's executables directly.
        let fix = read("run") == nil ? "`swift run devkit sync`" : "`./run dev sync`"
        for (file, drift) in SharedFiles.drift(root: workspace.root) {
            findings.append(error("shared_files", file.path, "\(drift.rawValue); run \(fix)"))
        }
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
        if let item = items(at: stagedAppcast, "min_os_consistency", &findings)?.newest,
            let staged = item.minimumSystemVersion, staged != macOS
        {
            findings.append(
                error(
                    "min_os_consistency", relative(stagedAppcast),
                    "minimumSystemVersion is \(staged), DylApp.toml says \(macOS)"))
        }
    }

    private var stagedAppcast: URL { ReleasePipeline(workspace: workspace).stagedAppcast }

    private func relative(_ url: URL) -> String {
        url.path.replacingOccurrences(of: workspace.root.path + "/", with: "")
    }

    /// The appcast's items, nil when none is staged. One that doesn't parse is a finding under `rule`.
    private func items(at appcast: URL, _ rule: String, _ findings: inout [CheckFinding]) -> [AppcastItem]? {
        guard FileManager.default.fileExists(atPath: appcast.path) else { return nil }
        do {
            return try Appcast.items(at: appcast)
        } catch let failure {
            findings.append(error(rule, relative(appcast), "\(failure)"))
            return nil
        }
    }

    private func checkStagedAppcast(_ findings: inout [CheckFinding]) {
        let appcastPath = relative(stagedAppcast)
        guard let item = items(at: stagedAppcast, "appcast_signature", &findings)?.newest else { return }
        guard let name = item.enclosureURL?.split(separator: "/").last.map(String.init) else {
            findings.append(error("appcast_signature", appcastPath, "newest item has no enclosure URL"))
            return
        }
        guard let data = try? Data(contentsOf: stagedAppcast.deletingLastPathComponent().appending(path: name)) else {
            findings.append(error("appcast_signature", appcastPath, "names \(name), which isn't staged next to it"))
            return
        }
        guard let publicKey else { return }
        switch EdSignature.check(item, archive: data, publicKey: publicKey) {
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
    }

    private var workflows: [Workflow] {
        let directory = ".github/workflows"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.url(directory).path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.compactMap { name in
            let path = "\(directory)/\(name)"
            return read(path).map { Workflow(path: path, text: $0) }
        }
    }

    private func checkSecrets(_ findings: inout [CheckFinding]) {
        let readers = toolSources()
        var referenced: Set<String> = []
        for workflow in workflows {
            for match in workflow.text.matches(of: /(\w+):\s*\$\{\{\s*secrets\.(\w+)\s*\}\}/) {
                let variable = String(match.1)
                referenced.insert(String(match.2))
                let readElsewhere =
                    Self.releaseKitVariables.contains(variable) || readers.contains { $0.text.contains(variable) }
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

    /// Environment variables release-kit itself reads, so a workflow that passes them to it uses them.
    static let releaseKitVariables: Set<String> = [
        ReleasePipeline.edKeyVariable, GitHub.tokenVariable, BlobStore.tokenVariable,
    ]

    private struct Source {
        let path: String
        let text: String
    }

    private func toolSources() -> [Source] {
        var sources: [Source] = []
        for directory in ["scripts", "ci"] {
            let enumerator = FileManager.default.enumerator(atPath: workspace.url(directory).path)
            while let relative = enumerator?.nextObject() as? String {
                let path = "\(directory)/\(relative)"
                if let text = read(path) { sources.append(Source(path: path, text: text)) }
            }
        }
        if let run = read("run") { sources.append(Source(path: "run", text: run)) }
        return sources
    }

    /// What in `text` talks to a forge directly. Only release-kit may.
    public static func forgeCalls(in text: String) -> [String] {
        let forgeAPIs = [
            (#"(?m)(?:^|[\s;&|(])gh\s+(?:release|api|pr)\b"#, "calls the gh CLI"),
            (#"api\.github\.com"#, "calls the GitHub API"),
            (#"actions/github\-script"#, "uses the github-script action"),
            (#"action\-gh\-release"#, "uploads a GitHub Release"),
        ]
        return forgeAPIs.filter { text.matches(pattern: $0.0) }.map(\.1)
    }

    private func checkForgeNeutral(_ findings: inout [CheckFinding]) {
        let releaseWorkflows = workflows.filter(\.runsRelease).map { Source(path: $0.path, text: $0.text) }
        for source in releaseWorkflows + toolSources() {
            for problem in Self.forgeCalls(in: source.text) {
                findings.append(
                    error(
                        "forge_neutral", source.path,
                        "\(problem); only release-kit talks to the forge"))
            }
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
    /// That command must still deploy changes to the artifacts dir and to what the site builds from outside its root:
    /// `file:` packages and, for `@dylkit/web`, DylApp.toml (Saga #45).
    private struct VercelConfig: Decodable {
        var ignoreCommand: String?
    }

    /// The site's root, the nearest folder above the artifacts dir with a `package.json`, and that file's text.
    private var site: (root: String, package: String)? {
        var root = (manifest.release.artifactsDir as NSString).deletingLastPathComponent
        while !root.isEmpty {
            if let package = read("\(root)/package.json") { return (root, package) }
            root = (root as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func checkSiteDeploy(_ findings: inout [CheckFinding]) {
        guard let (siteRoot, package) = site else { return }
        if let path = package.firstMatch(of: /"@dylkit\/web"\s*:\s*"file:([^"]+)"/)?.1 {
            findings.append(
                error(
                    "site_deploy", "\(siteRoot)/package.json",
                    "@dylkit/web is a `file:\(path)` dependency, which Vercel can't build; depend on the release "
                        + "tarball instead: \"\(Self.webTarballURL)\""))
        }
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
        for match in package.matches(of: /"(?!@dylkit\/web")[^"]+"\s*:\s*"file:([^"]+)"/) {
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

    private struct PackageResolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { var version: String? }
            var identity: String
            var state: State
        }
        var pins: [Pin]
    }

    /// SwiftPM and npm pin DylKit separately, so the app and its site can drift onto different releases. A DylKit
    /// pinned to a branch or revision has no version to compare.
    private func checkWebMatchesPin(_ findings: inout [CheckFinding]) {
        guard let (siteRoot, package) = site,
            let match = package.firstMatch(of: /"@dylkit\/web"\s*:\s*"([^"]*\/dylkit-web-([^"\/]+)\.tgz)"/),
            let resolved = read("Package.resolved")
                .flatMap({ try? JSONDecoder().decode(PackageResolved.self, from: Data($0.utf8)) }),
            let pinned = resolved.pins.first(where: { $0.identity == "dyl-kit" })?.state.version,
            match.2 != pinned
        else { return }
        let url = match.1.replacingOccurrences(of: match.2, with: pinned)
        findings.append(
            error(
                "dylkit_web_version", "\(siteRoot)/package.json",
                "@dylkit/web is \(match.2) but Package.resolved pins DylKit \(pinned); depend on \"\(url)\""))
    }

    /// What `devkit icons` writes into `[build] site-icons`.
    public static let siteIconNames = ["favicon.ico", "icon.png", "apple-icon.png"]

    /// The `@dylkit/web` dependency apps' sites use; `<version>` is the DylKit release, whose log names the URL.
    static let webTarballURL =
        "https://<DylKit's store>.public.blob.vercel-storage.com/releases/v<version>/dylkit-web-<version>.tgz"

    private func checkSiteIcons(_ findings: inout [CheckFinding]) {
        guard let directory = manifest.build.siteIcons else { return }
        for name in Self.siteIconNames
        where !FileManager.default.fileExists(atPath: workspace.url("\(directory)/\(name)").path) {
            findings.append(error("site_icons", "\(directory)/\(name)", "missing; run `./run dev icons`"))
        }
    }

    /// SwiftPM copies a listed resource verbatim into a resource bundle unless the target excludes it, so the app
    /// would ship it twice, once uncompiled. Resources outside every target's directory are invisible to SwiftPM.
    private func checkResourcesExcluded(_ findings: inout [CheckFinding]) {
        guard !manifest.build.resources.isEmpty, let package = read("Package.swift") else { return }
        let excluded = Set(
            package.matches(of: /exclude\s*:\s*\[([^\]]*)\]/).flatMap { block in
                block.1.matches(of: /"([^"]+)"/).map { String($0.1) }
            })
        let targetRoots = ["Sources/", "Tests/"]
            + package.matches(of: /path\s*:\s*"([^"]+)"/).map { String($0.1).trimmingSuffix("/") + "/" }
        for resource in manifest.build.resources where targetRoots.contains(where: resource.hasPrefix) {
            let components = resource.split(separator: "/")
            let candidates = (0..<components.count).map { components[$0...].joined(separator: "/") }
            if !candidates.contains(where: excluded.contains) {
                findings.append(
                    error(
                        "resource_not_excluded", "Package.swift",
                        "\(resource) is in [build] resources but not in its target's `exclude:`"))
            }
        }
    }

    /// Local values are credentials; their file must never be committed.
    private func checkLocalValuesIgnored(_ findings: inout [CheckFinding]) {
        guard let file = manifest.localValues?.file else { return }
        let root = workspace.root
        let tracked = (try? Shell.run(
            ["git", "ls-files", "--error-unmatch", "--", file], cwd: root, quiet: true, allowFailure: true)) == 0
        let ignored = (try? Shell.run(
            ["git", "check-ignore", "-q", "--no-index", "--", file], cwd: root, quiet: true, allowFailure: true)) == 0
        if tracked {
            findings.append(error("local_values_ignored", file, "is committed; `git rm --cached` it and rotate its values"))
        } else if !ignored {
            findings.append(error("local_values_ignored", file, "isn't in .gitignore"))
        }
    }

    // MARK: - Staged release

    /// The build must beat every published feed: the site's and the Blob store's latest, either of which can be ahead.
    /// The same build and version is a re-run of the release that published them.
    private func checkStaged(_ staged: StagedRelease, into findings: inout [CheckFinding]) {
        let file = relative(staged.appcast)
        guard let item = items(at: staged.appcast, "staged_release", &findings)?.newest else {
            if findings.isEmpty { findings.append(error("staged_release", file, "has no items")) }
            return
        }
        if let published = staged.published.newest,
            item.build < published.build || (item.build == published.build && item.displayVersion != published.displayVersion)
        {
            findings.append(
                error(
                    "build_number_monotonic", file, "build \(item.build) isn't above the published build \(published.build)"
                ))
        }
        let expectedURL = staged.downloadPrefix + staged.archive.lastPathComponent
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
