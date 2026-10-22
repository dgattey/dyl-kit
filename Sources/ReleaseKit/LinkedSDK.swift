import DylToolSupport
import Foundation

/// macOS and iOS 26 draw an app's old design when its binary records an SDK below 26, and Swift Build records the
/// deployment target as the SDK. So builds hand the linker both versions and fail when the binary records another SDK.
extension ResourceCompiler.Platform {
    private var linkerName: String {
        switch self {
        case .macOS: "macos"
        case .iOSSimulator: "ios-simulator"
        }
    }

    /// The installed SDK's version, such as `26.2`.
    ///
    /// - Blocking: runs `xcrun`.
    public func sdkVersion() throws -> String {
        try Shell.capture(["xcrun", "--sdk", sdk, "--show-sdk-version"])
    }

    /// Compiler-driver arguments that make the linker record `minimumOS` and `sdkVersion` in `LC_BUILD_VERSION`.
    public func platformVersionFlags(minimumOS: String, sdkVersion: String) -> [String] {
        ["-platform_version", linkerName, minimumOS, sdkVersion].flatMap { ["-Xlinker", $0] }
    }

    /// Fails unless every slice of `binary` records `sdkVersion`.
    ///
    /// - Blocking: runs `vtool`.
    public static func verifySDK(of binary: URL, sdkVersion: String) throws {
        try verifySDK(
            vtoolOutput: try Shell.capture(["xcrun", "vtool", "-show-build", binary.path]),
            binary: binary.lastPathComponent, sdkVersion: sdkVersion)
    }

    static func verifySDK(vtoolOutput: String, binary: String, sdkVersion: String) throws {
        let recorded = vtoolOutput.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count == 2 && fields[0] == "sdk" ? String(fields[1]) : nil
        }
        guard recorded.isEmpty || recorded.contains(where: { components($0) != components(sdkVersion) }) else { return }
        let found = recorded.isEmpty ? "no SDK" : "SDK \(Set(recorded).sorted().joined(separator: ", "))"
        throw ToolError(
            "\(binary) records \(found) but the installed SDK is \(sdkVersion), so the OS would draw its old design")
    }

    private static func components(_ version: some StringProtocol) -> [Int] {
        var components = version.split(separator: ".").compactMap { Int($0) }
        while components.last == 0 { components.removeLast() }
        return components
    }
}
