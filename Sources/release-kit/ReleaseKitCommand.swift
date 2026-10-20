import ArgumentParser
import DylToolSupport
import Foundation
import ReleaseKit

@main
struct ReleaseKitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-kit",
        abstract: "Version, bundle, sign and publish a Sparkle release, and check the release invariants.",
        discussion: """
            CI runs the steps in order: version, bundle, sign, appcast, check, publish. Each step reads \
            what the earlier ones left in build/release/.
            """,
        subcommands: [
            Version.self, Bundle.self, Sign.self, Appcast.self, Check.self, Publish.self, Notes.self,
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
            abstract: "Plan the next version and build from the merged PR body, tags and the live feed.")

        @OptionGroup var options: RootOption
        @Option(help: "The bump; auto reads the `# Release info` checkbox.") var type: BumpChoice = .auto
        @Option(help: "The merged PR's body, fetched by the forge wrapper. Empty or missing means the lookup failed.")
        var prBodyFile: String?

        func run() async throws {
            let pipeline = ReleasePipeline(workspace: try options.workspace())
            let prBody = prBodyFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let state = try await pipeline.version(explicitBump: type.bump, prBody: prBody)
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

        func run() throws {
            print(try ReleasePipeline(workspace: try options.workspace()).sign().path)
        }
    }

    struct Appcast: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write the notes and appcast, verify the EdDSA signature, and install the artifacts.")

        @OptionGroup var options: RootOption
        @Option(help: "The Sparkle private key; defaults to SPARKLE_ED_PRIVATE_KEY_BASE64, a local key file, or the Keychain.")
        var edKeyFile: String?

        func run() async throws {
            let pipeline = ReleasePipeline(workspace: try options.workspace())
            print(try await pipeline.appcast(edKeyFile: try pipeline.resolveEdKey(explicit: edKeyFile)).path)
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Tier 3 release checks against the repo.")

        @OptionGroup var options: RootOption

        func run() throws {
            let report = ReleaseChecks(workspace: try options.workspace()).run()
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
                state = ReleasePipeline.State(version: version, build: 0, subject: "Untitled", body: body)
            }
            guard let state else { throw ToolError("run `release-kit version` first, or pass --body-file") }
            let live = await ReleaseKit.Appcast.fetch(workspace.manifest.release.feedURL)
            print(try pipeline.releaseNotes(state: state, history: [live]))
        }
    }
}
