/// Bundling, signing and Sparkle's tools need Xcode, so they run only on macOS. CI runs them on macos runners.
public enum HostPlatform {
    public static func requireMacOS(_ step: String) throws {
        #if !os(macOS)
        throw ToolError("\(step) needs macOS with Xcode; on Linux, release-kit's version, check and notes run")
        #endif
    }
}
