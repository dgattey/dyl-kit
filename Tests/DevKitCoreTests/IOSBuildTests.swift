import DylManifest
import Foundation
import Testing

@testable import DevKitCore

@Suite struct IOSBuildTests {
    @Test func findsTheSchemeForTheProduct() throws {
        #expect(try IOSBuild.scheme(for: "Sconeos", in: ["SconeDomain", "SconeKit-Package", "Sconeos"]) == "Sconeos")
        #expect(try IOSBuild.scheme(for: "Sample", in: ["SampleApp"]) == "SampleApp")
        #expect(try IOSBuild.scheme(for: "Sample", in: ["SampleApp", "Sample-Package"]) == "SampleApp")
        #expect(throws: (any Error).self) { try IOSBuild.scheme(for: "Sample", in: ["One", "Two"]) }
    }

    @Test func simulatorBuildsNeverCarryTheReleaseBundleId() throws {
        let toml = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../Fixtures/SampleApp/DylApp.toml")
        let text = try String(contentsOf: toml, encoding: .utf8)
        #expect(IOSBuild.devBundleId(try DylAppManifest.decode(text)) == "com.dylkit.Sample.ios.dev")
        let withoutIOSId = text.replacingOccurrences(of: #"bundle-id = "com.dylkit.Sample.ios""#, with: "")
        #expect(IOSBuild.devBundleId(try DylAppManifest.decode(withoutIOSId)) == "com.dylkit.Sample.dev")
    }

    /// Sudylko at v0.3.0: under `swift run`, Xcode 27 linked the simulator product against the macOS SDK.
    @Test func theSimulatorBuildNeverInheritsTheMacOSSDKRoot() {
        let arguments = IOSBuild.xcodebuildArguments(
            scheme: "SampleApp", derivedData: URL(fileURLWithPath: "/tmp/dd"), linkerFlags: ["-Xlinker", "x"])
        #expect(arguments.prefix(3) == ["-u", "SDKROOT", "xcodebuild"])
        #expect(arguments.last == "OTHER_LDFLAGS=$(inherited) -Xlinker x")
    }
}
