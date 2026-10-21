import Foundation

public struct ToolError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// Runs external commands for the host tools. Every call goes through `/usr/bin/env` so `PATH` lookup matches
/// the shell the scripts used to run in.
public enum Shell {
    /// Runs `arguments`, streaming all of its output to this process's stderr: stdout carries only the tool's own
    /// results, which CI pipes into files such as `$GITHUB_OUTPUT`.
    ///
    /// - Blocking: waits for the child process.
    @discardableResult
    public static func run(
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        allowFailure: Bool = false
    ) throws -> Int32 {
        let process = makeProcess(arguments, cwd: cwd, environment: environment)
        process.standardOutput = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            throw ToolError("`\(arguments.joined(separator: " "))` exited with status \(process.terminationStatus)")
        }
        return process.terminationStatus
    }

    /// Runs `arguments` and returns its stdout with surrounding whitespace trimmed. Stderr passes through.
    ///
    /// - Blocking: waits for the child process.
    public static func capture(
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        allowFailure: Bool = false
    ) throws -> String {
        let process = makeProcess(arguments, cwd: cwd, environment: environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            throw ToolError("`\(arguments.joined(separator: " "))` exited with status \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The absolute path of `tool` on `PATH`, or nil.
    ///
    /// - Blocking: runs `which`.
    public static func which(_ tool: String) -> String? {
        guard let path = try? capture(["which", tool], allowFailure: true), !path.isEmpty else { return nil }
        return path
    }

    private static func makeProcess(_ arguments: [String], cwd: URL?, environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        return process
    }
}

/// Progress lines on stderr, prefixed with the tool name, so stdout stays machine-readable.
public enum Log {
    public static let tool = URL(fileURLWithPath: CommandLine.arguments.first ?? "dylkit").lastPathComponent

    public static func step(_ message: String) {
        FileHandle.standardError.write(Data("\(tool): \(message)\n".utf8))
    }

    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(tool): warning: \(message)\n".utf8))
    }
}
