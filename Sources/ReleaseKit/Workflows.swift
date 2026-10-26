import Foundation
import Yams

/// A GitHub Actions workflow, read for what it runs on and the check runs its jobs report.
struct Workflow: Sendable {
    struct Job: Sendable {
        var id: String
        /// `name:`, which may hold `${{ }}` expressions.
        var name: String?
        /// The reusable workflow a job calls, as written after `uses:`.
        var uses: String?
        var hasMatrix: Bool

        /// The check run's own name: `name:` or the job id.
        var title: String { name ?? id }
    }

    var path: String
    /// Each event and its `types:`; nil types when the workflow takes the event's default types.
    var triggers: [String: [String]?]
    var jobs: [Job]

    /// - Throws: when the text isn't YAML or isn't a mapping.
    init(path: String, text: String) throws {
        self.path = path
        guard let root = try compose(yaml: text, .basic)?.mapping else {
            throw WorkflowError("\(path) isn't a YAML mapping")
        }
        triggers = Self.triggers(root.value("on"))
        jobs = (root.value("jobs")?.mapping ?? [:]).compactMap { key, value in
            guard let id = key.scalar?.string, let job = value.mapping else { return nil }
            return Job(
                id: id, name: job.value("name")?.scalar?.string, uses: job.value("uses")?.scalar?.string,
                hasMatrix: job.value("strategy")?.mapping?.value("matrix") != nil)
        }
    }

    /// `on:` as a single event, a list of events, or a mapping of events to their settings.
    private static func triggers(_ node: Node?) -> [String: [String]?] {
        if let event = node?.scalar?.string { return [event: nil] }
        if let events = node?.sequence {
            return Dictionary(events.compactMap { $0.scalar?.string }.map { ($0, nil) }) { first, _ in first }
        }
        var triggers: [String: [String]?] = [:]
        for (key, value) in node?.mapping ?? [:] {
            guard let event = key.scalar?.string else { continue }
            let types = value.mapping?.value("types")
            triggers.updateValue(
                types?.sequence.map { $0.compactMap { $0.scalar?.string } } ?? types?.scalar.map { [$0.string] },
                forKey: event)
        }
        return triggers
    }

    /// Only called by other workflows, so it reports nothing on its own.
    var isReusableOnly: Bool { !triggers.isEmpty && triggers.keys.allSatisfy { $0 == "workflow_call" } }

    func types(of event: String) -> [String]? { triggers[event] ?? nil }

    func calls(_ reusable: String) -> Bool { jobs.contains { $0.uses?.hasPrefix(reusable + "@") == true } }
}

struct WorkflowError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Node.Mapping {
    /// The value under a plain key; `.basic` composing leaves every scalar, `on` included, a string.
    fileprivate func value(_ key: String) -> Node? {
        first { $0.key.scalar?.string == key }?.value
    }
}

/// A status check a ruleset requires. GitHub Actions is integration 15368; nil accepts the context from any source.
public struct RequiredCheck: Decodable, Equatable, Sendable {
    public var context: String
    public var integrationId: Int?

    public init(context: String, integrationId: Int? = nil) {
        self.context = context
        self.integrationId = integrationId
    }

    static let actionsIntegration = 15368
}

/// What the default branch's rulesets require of a PR, or why they couldn't be read.
public enum BranchRules: Sendable, Equatable {
    case read(branch: String, required: [RequiredCheck])
    case unreadable(String)

    /// Reads the repo from `GITHUB_REPOSITORY` and the token from `GITHUB_TOKEN`, as on Actions, or locally from the
    /// `origin` remote and `gh auth token`.
    ///
    /// - Blocking: runs git and gh when the environment lacks the repo or token.
    public static func fetch(
        root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport()
    ) async -> BranchRules {
        do {
            let github = try GitHub(environment: GitHub.filling(environment, from: root), transport: transport)
            let branch = try await github.defaultBranch()
            return .read(branch: branch, required: try await github.requiredChecks(branch: branch))
        } catch {
            return .unreadable("\(error)")
        }
    }
}

/// The check-run names a repo's workflows report, as patterns where `*` stands for anything an expression, a matrix or
/// an unknown reusable workflow fills in.
struct CheckNames: Sendable {
    /// The jobs in DylKit's reusable workflows, by file; a test keeps these in step with the files.
    static let dylKitJobs = [
        "app.yml": ["changes", "verify", "release", "live-site"], "release-info.yml": ["release-info"],
    ]

    private(set) var patterns: [String] = []

    /// - Parameter local: reads a workflow in this repo by its path, for `uses: ./.github/workflows/…`.
    init(workflows: [Workflow], local: (String) -> Workflow?) {
        for workflow in workflows where !workflow.isReusableOnly {
            patterns += Self.names(workflow.jobs, local: local, depth: 0)
        }
    }

    private static func names(_ jobs: [Workflow.Job], local: (String) -> Workflow?, depth: Int) -> [String] {
        jobs.flatMap { job -> [String] in
            let title = expressionsAsWildcards(job.title)
            guard let uses = job.uses else { return job.hasMatrix ? [title, "\(title) (*)"] : [title] }
            let called: [String]?
            if uses.hasPrefix("./"), depth < 3 {
                called = local(String(uses.dropFirst(2))).map { names($0.jobs, local: local, depth: depth + 1) }
            } else if uses.hasPrefix("dgattey/dyl-kit/.github/workflows/"),
                let file = uses.split(separator: "/").last?.split(separator: "@").first
            {
                called = dylKitJobs[String(file)]
            } else {
                called = nil
            }
            return (called ?? ["*"]).map { "\(title) / \($0)" }
        }
    }

    private static func expressionsAsWildcards(_ name: String) -> String {
        name.replacing(/\$\{\{.*?\}\}/, with: "*")
    }

    func produces(_ context: String) -> Bool {
        patterns.contains { pattern in
            let regex = pattern.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
            return (try? Regex(regex)).map { context.wholeMatch(of: $0) != nil } ?? false
        }
    }
}
