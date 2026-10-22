import Testing

@testable import ReleaseKit

@Suite struct LinkedSDKTests {
    private let swiftBuildOutput = """
        build/Sample:
        Load command 10
              cmd LC_BUILD_VERSION
          cmdsize 32
         platform MACOS
            minos 14.0
              sdk 14.0
           ntools 1
             tool LD
          version 1221.4
        """

    private let fatSimulatorOutput = """
        Sample (architecture x86_64):
        Load command 9
              cmd LC_BUILD_VERSION
         platform IOSSIMULATOR
            minos 17.0
              sdk 26.2
        Sample (architecture arm64):
        Load command 9
              cmd LC_BUILD_VERSION
         platform IOSSIMULATOR
            minos 17.0
              sdk 26.2
        """

    @Test func linkerFlagsRecordTheDeploymentTargetAndTheInstalledSDK() {
        #expect(
            ResourceCompiler.Platform.macOS.platformVersionFlags(minimumOS: "14.0", sdkVersion: "27.0") == [
                "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "27.0",
            ])
        #expect(
            ResourceCompiler.Platform.iOSSimulator.platformVersionFlags(minimumOS: "17.0", sdkVersion: "26.2") == [
                "-Xlinker", "-platform_version", "-Xlinker", "ios-simulator", "-Xlinker", "17.0", "-Xlinker", "26.2",
            ])
    }

    @Test func aDeploymentTargetRecordedAsTheSDKFails() {
        #expect(throws: (any Error).self) {
            try ResourceCompiler.Platform.verifySDK(vtoolOutput: swiftBuildOutput, binary: "Sample", sdkVersion: "27.0")
        }
    }

    @Test func everySliceMustRecordTheInstalledSDK() throws {
        try ResourceCompiler.Platform.verifySDK(vtoolOutput: fatSimulatorOutput, binary: "Sample", sdkVersion: "26.2")
        let oneStale = fatSimulatorOutput.replacing(
            "sdk 26.2\nSample (architecture arm64)", with: "sdk 17.0\nSample (architecture arm64)")
        #expect(throws: (any Error).self) {
            try ResourceCompiler.Platform.verifySDK(vtoolOutput: oneStale, binary: "Sample", sdkVersion: "26.2")
        }
    }

    @Test func trailingZeroComponentsMatch() throws {
        try ResourceCompiler.Platform.verifySDK(vtoolOutput: swiftBuildOutput, binary: "Sample", sdkVersion: "14")
        try ResourceCompiler.Platform.verifySDK(vtoolOutput: swiftBuildOutput, binary: "Sample", sdkVersion: "14.0.0")
    }

    @Test func noRecordedSDKFails() {
        #expect(throws: (any Error).self) {
            try ResourceCompiler.Platform.verifySDK(vtoolOutput: "Sample:\n", binary: "Sample", sdkVersion: "26.2")
        }
    }
}
