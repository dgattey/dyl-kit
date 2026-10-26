import DylToolSupport
import Foundation
import Testing

@testable import DevKitCore

@Suite struct ChecksTests {
    /// A `.package(path:)` DylKit has no `.build/checkouts/dyl-kit`, so the shared config comes from SwiftPM.
    @Test func findsDylKitAnywhereInTheDependencyTree() {
        let json = """
            {"identity": "app", "path": "/r/app", "dependencies": [
              {"identity": "sparkle", "path": "/r/app/.build/checkouts/Sparkle", "dependencies": []},
              {"identity": "helpers", "path": "/r/helpers", "dependencies": [
                {"identity": "dyl-kit", "path": "/Users/d/repos/dyl-kit", "dependencies": []}
              ]}
            ]}
            """
        #expect(Checks.dylKitPath(dependenciesJSON: json) == "/Users/d/repos/dyl-kit")
        #expect(Checks.dylKitPath(dependenciesJSON: #"{"identity": "x", "path": "/x", "dependencies": []}"#) == nil)
    }

    /// With no `included:`, SwiftLint walked `.build` and failed on about 275 hits in Sparkle's sources.
    @Test(.enabled(if: Shell.which("swiftlint") != nil))
    func appWithoutIncludedSkipsBuildFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dylkit-swiftlint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let untyped = "import Foundation\nlet x = try? JSONSerialization.jsonObject(with: Data())\n"
        let files = [
            "Sources/App/App.swift": "let app = 1\n",
            ".build/checkouts/Sparkle/Untyped.swift": untyped,
            "build/release/Untyped.swift": untyped,
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let shared = URL(filePath: #filePath).appending(path: "../../../lint/swiftlint.yml").standardized.path
        let configs = [shared, try Checks.excludeBuildFolders(root: root)]
        let swiftlint = try #require(Shell.which("swiftlint"))
        let output = try Shell.capture(
            [swiftlint, "lint", "--strict", "--quiet"] + configs.flatMap { ["--config", $0] },
            cwd: root, includeStderr: true)
        #expect(output.isEmpty)
    }
}
