import Foundation
import Testing

/// Builds the `live-agent-server` executable of the `LiveAgentServer`
/// package, and gives its path.
///
/// The package stands beside the manifest of this test package, outside the
/// graph of this package: the manifest of `LiveAgentServer` tells why. Thus
/// `swift test` does not build it, and the test builds it here with
/// `swift build --package-path`. The second build of one run finds the
/// products of the first and builds nothing.
///
/// The output of each `swift build` goes to a log file, and not to the
/// output of the test. A failed build throws an error that holds the log.
struct LiveAgentServerBuild {
    /// The name of the executable product of the package.
    static let productName = "live-agent-server"

    /// The directory of the `LiveAgentServer` package. This file is in
    /// `IntegrationTests/Tests/<target>/`, and the package is in
    /// `IntegrationTests/LiveAgentServer/`.
    static let packageDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "LiveAgentServer", directoryHint: .isDirectory)

    /// The `env` executable, which finds `swift` on the `PATH` of the test.
    private static let environmentLauncher = URL(filePath: "/usr/bin/env")

    /// A `swift build` that did not end with the exit status 0.
    struct Failure: Error, CustomStringConvertible {
        /// The arguments that followed `swift`.
        let arguments: [String]

        /// The exit status of `swift`.
        let status: Int32

        /// The output of `swift`: stdout and stderr together.
        let output: String

        /// The command, the exit status and the output.
        var description: String {
            "swift \(arguments.joined(separator: " ")) exited with status \(status):\n\(output)"
        }
    }

    /// The directory that holds the log file of each `swift build`.
    let logDirectory: URL

    /// Builds the executable, and gives its absolute path.
    ///
    /// - Returns: The absolute path of the executable.
    /// - Throws: ``Failure`` for a failed `swift build`, the error of a log
    ///   file, or the error of `#require` when `--show-bin-path` wrote no
    ///   path.
    func makeExecutable() async throws -> String {
        _ = try await runSwiftBuild(["--product", Self.productName], logName: "build.log")
        let binPathOutput = try await runSwiftBuild(["--show-bin-path"], logName: "bin-path.log")
        let binDirectory = try #require(
            binPathOutput.split(whereSeparator: \.isNewline).last,
            "swift build --show-bin-path wrote no path")
        return URL(filePath: String(binDirectory), directoryHint: .isDirectory)
            .appending(path: Self.productName)
            .path
    }

    /// Runs `swift build --package-path <package> <arguments>`, and waits
    /// for its end.
    ///
    /// - Parameters:
    ///   - arguments: The arguments after `swift build --package-path
    ///     <package>`.
    ///   - logName: The name of the log file in ``logDirectory`` that
    ///     receives stdout and stderr.
    /// - Returns: The output of the command: stdout and stderr together.
    /// - Throws: ``Failure`` when the command ends with a status other than
    ///   0, or the error of the log file or of the start of the command.
    private func runSwiftBuild(_ arguments: [String], logName: String) async throws -> String {
        let swiftArguments = ["build", "--package-path", Self.packageDirectory.path] + arguments
        let logFile = logDirectory.appending(path: logName)
        try Data().write(to: logFile)
        let log = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = Self.environmentLauncher
        process.arguments = ["swift"] + swiftArguments
        process.standardOutput = log
        process.standardError = log
        let status = try await Self.run(process)
        let output = try String(contentsOf: logFile, encoding: .utf8)
        guard status == 0 else {
            throw Failure(arguments: swiftArguments, status: status, output: output)
        }
        return output
    }

    /// Starts `process`, and waits for its end without a block of the
    /// thread.
    ///
    /// - Parameter process: The configured process, not started.
    /// - Returns: The exit status of the process.
    /// - Throws: The error of the start of the process.
    private static func run(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { ended in
                continuation.resume(returning: ended.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
