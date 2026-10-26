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

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

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
        check("library_validation", checkLibraryValidation)
        check("site_deploy", checkSiteDeploy)
        check("site_package_manager", checkSitePackageManager)
        check("releases_page", checkReleasesPage)
        check("site_typescript", checkSiteTypeScript)
        check("dylkit_version", checkPinsMatch)
        check("local_values_ignored", checkLocalValuesIgnored)
        check("release_notes", checkReleaseNotesFiles)
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

    private var publicKey: String? {
        read(manifest.release.sparklePublicKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkPublicKey(_ findings: inout [CheckFinding]) {
        let file = manifest.release.sparklePublicKey
        guard let key = publicKey else {
            let tool = ".build/artifacts/sparkle/Sparkle/bin/generate_keys --account \(manifest.app.bundleId)"
            findings.append(
                error(
                    "sparkle_public_key", file,
                    "missing; after `swift build`, run `\(tool)` to give the app its own key, then "
                        + "`\(tool) -p > \(file)` (adopt-dylkit step 2)"))
            return
        }
        if Data(base64Encoded: key)?.count != 32 {
            findings.append(error("sparkle_public_key", file, "isn't a base64 Ed25519 public key (32 bytes)"))
        }
    }

    private func checkPackageManifests(_ findings: inout [CheckFinding]) {
        let path = "Package.swift"
        guard let text = read(path) else { return }
        if let tools = text.firstMatch(of: /swift-tools-version:\s*(\d+)/), (Int(tools.1) ?? 0) < 6 {
            findings.append(error("swift_language_mode", path, "swift-tools-version is \(tools.1); use 6.0 or later"))
        }
        if text.matches(pattern: #"swiftLanguage(?:Modes|Versions)\s*:\s*\[[^\]]*\.v[45]"#) {
            findings.append(error("swift_language_mode", path, "pins Swift 5 language mode; use Swift 6"))
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

    // MARK: - Workflows

    private struct Source {
        let path: String
        let text: String
    }

    private var workflows: [Source] {
        let directory = ".github/workflows"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.url(directory).path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.compactMap { name in
            let path = "\(directory)/\(name)"
            return read(path).map { Source(path: path, text: $0) }
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
    /// `file:` packages, the repo root's `package.json` and, for `@dylkit/web`, DylApp.toml. It diffs from the last
    /// deployed commit, so a site change in a skipped commit still deploys with the next one. A branch's first deploy,
    /// which has no last commit, always builds, and so does one whose last commit Vercel's clone lacks after a
    /// force-push or rebase: `rev-parse` exits 1 there, where `git diff` exits 128 and Vercel fails the deploy.
    private struct VercelConfig: Decodable {
        var ignoreCommand: String?
    }

    static let ignoreCommandPrefix =
        #"git rev-parse --quiet --verify "$VERCEL_GIT_PREVIOUS_SHA^{commit}" && "#
        + #"git diff --quiet "$VERCEL_GIT_PREVIOUS_SHA" HEAD -- "#

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
        let file = "\(siteRoot)/vercel.json"
        let config = read(file).flatMap { try? JSONDecoder().decode(VercelConfig.self, from: Data($0.utf8)) }
        let command = config?.ignoreCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let prefix = Self.ignoreCommandPrefix
        guard command.hasPrefix(prefix) else {
            findings.append(
                error("site_deploy", file, "needs `\"ignoreCommand\": \"\(Self.jsonEscaped(prefix))<paths>\"`"))
            return
        }
        let watched = command.dropFirst(prefix.count).split(separator: " ").map { path in
            workspace.url(siteRoot).appending(path: String(path)).standardized.path
        }
        var needed = [manifest.release.artifactsDir, "package.json"]
        for match in package.matches(of: /"[^"]+"\s*:\s*"file:([^"]+)"/) {
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

    /// Sites install with pnpm: `packageManager` pins it and Vercel installs with it from `pnpm-lock.yaml`, falling
    /// back to npm without that lockfile. Vercel's CLI enables corepack from the clone root's `package.json`, not the
    /// Root Directory's, so the repo root holds the same pin; without it Vercel's bundled pnpm can't read the lockfile.
    private func checkSitePackageManager(_ findings: inout [CheckFinding]) {
        guard let (siteRoot, package) = site else { return }
        let file = "\(siteRoot)/package.json"
        let fields = (try? JSONSerialization.jsonObject(with: Data(package.utf8))) as? [String: Any] ?? [:]
        let wrongPin = "doesn't pin DylKit's pnpm; set \"packageManager\" to \"\(Self.pnpmPin)\""
        if fields["packageManager"] as? String != Self.pnpmPin {
            findings.append(error("site_package_manager", file, wrongPin))
        }
        if let root = read("package.json") {
            let rootFields = (try? JSONSerialization.jsonObject(with: Data(root.utf8))) as? [String: Any] ?? [:]
            if rootFields["packageManager"] as? String != Self.pnpmPin {
                findings.append(error("site_package_manager", "package.json", wrongPin))
            }
        } else {
            findings.append(
                error(
                    "site_package_manager", "package.json",
                    "is missing, so Vercel's CLI can't find the pnpm pin and installs with its own pnpm; add one "
                        + "holding only \"private\": true and \"packageManager\": \"\(Self.pnpmPin)\""))
        }
        if read("\(siteRoot)/pnpm-lock.yaml") == nil {
            findings.append(
                error(
                    "site_package_manager", "\(siteRoot)/pnpm-lock.yaml",
                    "is missing, so Vercel installs with npm; run `pnpm install` in \(siteRoot)"))
        }
    }

    /// `@dylkit/web` ships TypeScript and exposes its pages and routes as subpath exports, which only `bundler`
    /// resolution type-checks. A site with no `tsconfig.json` gets one from `next build` with `node` resolution, so it
    /// fails its first build.
    private func checkSiteTypeScript(_ findings: inout [CheckFinding]) {
        guard let (siteRoot, package) = site, package.contains("\"@dylkit/web\"") else { return }
        let file = "\(siteRoot)/tsconfig.json"
        let fix = "set \"moduleResolution\": \"bundler\" so @dylkit/web/app, /config and /routes resolve"
        guard let config = read(file) else {
            findings.append(error("site_typescript", file, "is missing; copy DylKit's SampleApp server/tsconfig.json"))
            return
        }
        let resolution = config.firstMatch(of: /"moduleResolution"\s*:\s*"([^"]*)"/).map { String($0.1) }
        guard resolution?.lowercased() != "bundler" else { return }
        let current = resolution.map { "\"\($0)\"" } ?? "no"
        findings.append(error("site_typescript", file, "has \(current) moduleResolution; \(fix)"))
    }

    /// Sparkle's full-notes link and the end of every update's notes point at `/releases`, the only place a user more
    /// than ten releases behind can read what they skipped, so a `@dylkit/web` site must serve it.
    private func checkReleasesPage(_ findings: inout [CheckFinding]) {
        guard let (siteRoot, package) = site, package.contains("\"@dylkit/web\"") else { return }
        let pages = ["tsx", "ts", "jsx", "js"].map { "\(siteRoot)/app/releases/page.\($0)" }
        guard !pages.contains(where: { FileManager.default.fileExists(atPath: workspace.url($0).path) }) else { return }
        findings.append(
            error(
                "releases_page", pages[0],
                "is missing; the update dialog links every version's notes there. Add "
                    + #"`export { Releases as default, releasesMetadata as metadata } from "@dylkit/web/app";`"#))
    }

    private static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: #"\""#)
    }

    private struct PackageResolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable {
                var version: String?
                var branch: String?
                var revision: String?
            }
            var identity: String
            var state: State
        }
        var pins: [Pin]
    }

    /// SwiftPM, the site's package.json and the app's workflow each pin DylKit, so they can drift onto different
    /// releases, or, while an app runs a DylKit PR, onto different commits: a revision pin needs `app.yml@<sha>` and
    /// the tarball the PR's prerelease job uploaded for that commit, `-pr.<number>.<short sha>`. A branch pin has no
    /// one commit to compare.
    private func checkPinsMatch(_ findings: inout [CheckFinding]) {
        let callers = workflows.compactMap { workflow in
            workflow.text.firstMatch(of: /uses:\s*dgattey\/dyl-kit\/\.github\/workflows\/app\.yml@([^\s#]+)/)
                .map { (path: workflow.path, ref: String($0.1)) }
        }
        if callers.isEmpty {
            findings.append(
                error(
                    "dylkit_version", ".github/workflows",
                    "nothing calls \(Self.appWorkflow); copy .github/workflows/dylkit.yml from DylKit's SampleApp"))
        }
        guard
            let state = read("Package.resolved")
                .flatMap({ try? JSONDecoder().decode(PackageResolved.self, from: Data($0.utf8)) })?
                .pins.first(where: { $0.identity == "dyl-kit" })?.state
        else { return }
        let tarball = site.flatMap { site in
            site.package.firstMatch(of: /"@dylkit\/web"\s*:\s*"([^"]*\/dylkit-web-([^"\/]+)\.tgz)"/)
                .map { (file: "\(site.root)/package.json", url: String($0.1), version: String($0.2)) }
        }
        if let pinned = state.version {
            for caller in callers where caller.ref != "v\(pinned)" {
                findings.append(
                    error(
                        "dylkit_version", caller.path,
                        "calls \(Self.appWorkflow)@\(caller.ref) but Package.resolved pins DylKit \(pinned); "
                            + "use @v\(pinned)"))
            }
            guard let tarball, tarball.version != pinned else { return }
            let url = tarball.url.replacingOccurrences(of: tarball.version, with: pinned)
            findings.append(
                error(
                    "dylkit_version", tarball.file,
                    "@dylkit/web is \(tarball.version) but Package.resolved pins DylKit \(pinned); "
                        + "depend on \"\(url)\""))
        } else if state.branch == nil, let revision = state.revision {
            let short = String(revision.prefix(7))
            for caller in callers where caller.ref != revision {
                findings.append(
                    error(
                        "dylkit_version", caller.path,
                        "calls \(Self.appWorkflow)@\(caller.ref) but Package.resolved pins DylKit at \(short); "
                            + "use @\(revision)"))
            }
            guard let tarball else { return }
            let commit = tarball.version.firstMatch(of: /-pr\.\d+\.([0-9a-f]{7,40})$/).map { String($0.1) }
            guard commit.map({ !revision.hasPrefix($0) }) ?? true else { return }
            findings.append(
                error(
                    "dylkit_version", tarball.file,
                    "@dylkit/web is \(tarball.version) but Package.resolved pins DylKit at \(short); depend on the "
                        + "-pr.<number>.\(short) tarball its PR's prerelease job uploaded"))
        }
    }

    /// The pnpm every site and its repo root pin, as SampleApp does. The hash is the npm registry's integrity for that
    /// pnpm tarball, so corepack refuses a download that doesn't match it.
    static let pnpmPin =
        "pnpm@12.9.1+sha512.06b055fff5cd20dc12781de173ced3310ce0951bf2ec620211a16045d5444d5c93a663210764ef29a653a610459"
        + "ba0368f0e74f84d80c54723cf95aae7bc0d6d"

    /// The reusable workflow that checks each app's PRs and releases its merges.
    static let appWorkflow = "dgattey/dyl-kit/.github/workflows/app.yml"

    /// Local values are credentials; their file must never be committed.
    private func checkLocalValuesIgnored(_ findings: inout [CheckFinding]) {
        guard let file = manifest.localValues?.file else { return }
        let ignored = (try? Shell.run(
            ["git", "check-ignore", "-q", "--no-index", "--", file], cwd: workspace.root, quiet: true,
            allowFailure: true)) == 0
        if isTracked(file) {
            findings.append(error("local_values_ignored", file, "is committed; `git rm --cached` it and rotate its values"))
        } else if !ignored {
            findings.append(error("local_values_ignored", file, "isn't in .gitignore"))
        }
    }

    private func isTracked(_ file: String) -> Bool {
        (try? Shell.run(
            ["git", "ls-files", "--error-unmatch", "--", file], cwd: workspace.root, quiet: true,
            allowFailure: true)) == 0
    }

    static let pullRequestTemplate = ".github/pull_request_template.md"

    /// Every PR needs a `# Release notes` section above `# Release info`, which app.yml's PR check lints. The DylKit
    /// plugin's rule tells agents how to write it.
    private func checkReleaseNotesFiles(_ findings: inout [CheckFinding]) {
        if let template = read(Self.pullRequestTemplate) {
            let headings = template.replacing(pattern: #"<!--[\s\S]*?-->"#, with: "").components(separatedBy: "\n")
                .compactMap { $0.firstMatch(of: /^\s*#{1,2}\s+(.+?)\s*$/).map { $0.1.lowercased() } }
            let info = headings.firstIndex(of: "release info") ?? headings.endIndex
            if headings.firstIndex(of: "release notes") ?? .max > info {
                findings.append(
                    error("release_notes", Self.pullRequestTemplate, "needs a `# Release notes` section above `# Release info`"))
            }
        } else {
            findings.append(
                error(
                    "release_notes", Self.pullRequestTemplate,
                    "missing; copy it from DylKit's Tests/Fixtures/SampleApp/ at the pinned tag"))
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
        let expectedURL = AppcastItem.enclosureURL(
            prefix: staged.downloadPrefix, fileName: staged.archive.lastPathComponent)
        if item.enclosureURL != expectedURL {
            findings.append(
                error("staged_release", file, "enclosure is \(item.enclosureURL ?? "missing"), expected \(expectedURL)")
            )
        }
    }
}
