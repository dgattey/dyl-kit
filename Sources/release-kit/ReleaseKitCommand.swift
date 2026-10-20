import ArgumentParser
import DylCore
import DylToolSupport
import Foundation
import ReleaseKit

@main
struct ReleaseKitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-kit",
        abstract: "Version, bundle, sign and publish a Sparkle release, and check the release invariants.",
        discussion: """
            CI runs the steps in order: version, bundle, sign, appcast, check, publish, check --live. Each step reads \
            what the earlier ones left in build/release/. `release` runs them all locally.
            """,
        subcommands: [
            Version.self, Bundle.self, Sign.self, Appcast.self, Check.self, Publish.self, Release.self, Notes.self,
            PRCheck.self,
        ]
    )
}

struct RootOption: ParsableArguments {
    @Option(help: "The app repo (the directory with DylApp.toml). Defaults to the nearest ancestor that has one.")
    var root: String?

    func workspace() throws -> Workspace { try Workspace.locate(root) }
}

enum BumpChoice: String, ExpressibleByArgument, CaseIterable {
    case auto, patch, minor, major

    var bump: AppVersion.Bump? { AppVersion.Bump(rawValue: rawValue) }
}

/// - Blocking: reads the file.
private func readBody(_ path: String?) throws -> String? {
    guard let path else { return nil }
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw ToolError("can't read \(path): \(error.localizedDescription)")
    }
}

extension ReleaseKitCommand {
    struct Version: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Plan the next version and build from the merge commit, tags and the live feed.")

        @OptionGroup var options: RootOption
        @Option(help: "The bump; auto reads the `# Release info` checkbox.") var type: BumpChoice = .auto
        @Option(help: "Read the PR body from this file instead of the merge commit message.") var bodyFile: String?

        func run() async throws {
            let pipeline = ReleasePipeline(workspace: try options.workspace())
            let state = try await pipeline.version(explicitBump: type.bump, body: try readBody(bodyFile))
            print("version=\(state.version)")
            print("build=\(state.build)")
        }
    }

    struct Bundle: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build the release .app into build/release/stage.")

        @OptionGroup var options: RootOption

        func run() throws {
            print(try ReleasePipeline(workspace: try options.workspace()).bundle().path)
        }
    }

    struct Sign: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign the staged app inside-out, verify it and zip it.")

        @OptionGroup var options: RootOption
        @Option(help: "The codesign identity; ad-hoc by default.") var identity: String = Signer.adHoc

        func run() throws {
            var pipeline = ReleasePipeline(workspace: try options.workspace())
            pipeline.identity = identity
            print(try pipeline.sign().path)
        }
    }

    struct Appcast: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write the notes and appcast, verify the EdDSA signature, and install the artifacts.")

        @OptionGroup var options: RootOption
        @Option(help: "The Sparkle private key; defaults to SPARKLE_ED_PRIVATE_KEY_BASE64 or a repo-local key.")
        var edKeyFile: String?

        func run() async throws {
            let pipeline = ReleasePipeline(workspace: try options.workspace())
            print(try await pipeline.appcast(edKeyFile: try pipeline.resolveEdKey(explicit: edKeyFile)).path)
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tier 3 release checks against the repo, or with --live against the deployed site.")

        @OptionGroup var options: RootOption
        @Option(help: "Also check this built .app (signature, rpaths, Info.plist).") var bundle: String?
        @Flag(help: "Check what users' updaters see instead of the repo.") var live = false
        @Option(help: "With --live, the version the site must serve; defaults to the planned release, if any.")
        var expect: String?
        @Option(help: "With --live, seconds to wait for the deploy to serve it.") var wait: Int = 0

        func run() async throws {
            let workspace = try options.workspace()
            let checks = ReleaseChecks(workspace: workspace)
            let report: CheckReport
            if live {
                let planned = try? ReleasePipeline(workspace: workspace).state().version
                report = await checks.live(expectedVersion: expect ?? planned, wait: .seconds(wait))
            } else {
                report = checks.run(bundle: bundle.map { URL(fileURLWithPath: $0) })
            }
            report.print()
            if !report.passed { throw ExitCode.failure }
        }
    }

    struct Publish: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Commit the artifacts, tag v<version>, and push both with plain git.")

        @OptionGroup var options: RootOption
        @Flag(help: "Commit and tag without pushing.") var noPush = false

        func run() throws {
            try ReleasePipeline(workspace: try options.workspace()).publish(push: !noPush)
        }
    }

    struct Release: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run version, bundle, sign, appcast and check in one go; --publish also commits and tags.")

        @OptionGroup var options: RootOption
        @Option(help: "The bump; auto reads the `# Release info` checkbox.") var type: BumpChoice = .auto
        @Option(help: "The codesign identity; ad-hoc by default.") var identity: String = Signer.adHoc
        @Option(help: "The Sparkle private key.") var edKeyFile: String?
        @Flag(help: "Commit, tag and push the release.") var publish = false

        func run() async throws {
            let workspace = try options.workspace()
            var pipeline = ReleasePipeline(workspace: workspace)
            pipeline.identity = identity
            let key = try pipeline.resolveEdKey(explicit: edKeyFile)
            _ = try await pipeline.version(explicitBump: type.bump)
            try pipeline.bundle()
            try pipeline.sign()
            try await pipeline.appcast(edKeyFile: key)
            let report = ReleaseChecks(workspace: workspace).run()
            report.print()
            guard report.passed else { throw ExitCode.failure }
            if publish { try pipeline.publish(push: true) }
        }
    }

    struct Notes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the cumulative HTML release notes for the planned release or a PR body.")

        @OptionGroup var options: RootOption
        @Option(help: "Format this PR body instead of the planned release's.") var bodyFile: String?
        @Option(help: "The version heading when formatting --body-file.") var version: String = "next"

        func run() async throws {
            let workspace = try options.workspace()
            let pipeline = ReleasePipeline(workspace: workspace)
            var state = try? pipeline.state()
            if let body = try readBody(bodyFile) {
                state = ReleasePipeline.State(
                    current: "", version: version, bump: "", build: 0, subject: "Untitled", body: body)
            }
            guard let state else { throw ToolError("run `release-kit version` first, or pass --body-file") }
            let live = await LiveFeed.fetch(workspace.manifest.release.feedURL)
            print(try pipeline.releaseNotes(state: state, history: [live]))
        }
    }

    struct PRCheck: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pr-check", abstract: "Fail unless a PR body checks exactly one Release info box.")

        @Option(help: "The PR body, written out of the forge's event payload.") var bodyFile: String

        func run() throws {
            if let problem = ReleaseInfo.validate(try readBody(bodyFile) ?? "") {
                FileHandle.standardError.write(Data("pr-check: \(problem)\n".utf8))
                throw ExitCode.failure
            }
            print("pr-check: release info OK")
        }
    }
}
