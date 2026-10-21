import Testing

@testable import DevKitCore

@Suite struct IOSBuildTests {
    @Test func findsTheSchemeForTheProduct() throws {
        #expect(try IOSBuild.scheme(for: "Sconeos", in: ["SconeDomain", "SconeKit-Package", "Sconeos"]) == "Sconeos")
        #expect(try IOSBuild.scheme(for: "Sample", in: ["SampleApp"]) == "SampleApp")
        #expect(try IOSBuild.scheme(for: "Sample", in: ["SampleApp", "Sample-Package"]) == "SampleApp")
        #expect(throws: (any Error).self) { try IOSBuild.scheme(for: "Sample", in: ["One", "Two"]) }
    }
}
