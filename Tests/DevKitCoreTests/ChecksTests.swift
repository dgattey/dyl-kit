import Testing

@testable import DevKitCore

@Suite struct ChecksTests {
    /// Saga: a `.package(path:)` DylKit has no `.build/checkouts/dyl-kit`, so the shared config comes from SwiftPM.
    @Test func findsDylKitAnywhereInTheDependencyTree() {
        let json = """
            {"identity": "saga", "path": "/r/saga", "dependencies": [
              {"identity": "sparkle", "path": "/r/saga/.build/checkouts/Sparkle", "dependencies": []},
              {"identity": "helpers", "path": "/r/helpers", "dependencies": [
                {"identity": "dyl-kit", "path": "/Users/d/repos/dyl-kit", "dependencies": []}
              ]}
            ]}
            """
        #expect(Checks.dylKitPath(dependenciesJSON: json) == "/Users/d/repos/dyl-kit")
        #expect(Checks.dylKitPath(dependenciesJSON: #"{"identity": "x", "path": "/x", "dependencies": []}"#) == nil)
    }
}
