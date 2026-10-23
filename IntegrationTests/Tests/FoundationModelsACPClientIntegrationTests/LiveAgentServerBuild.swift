import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

/// Builds an executable of the `LiveAgentServer` package, gives its path,
/// and starts it as an external agent.
///
/// The package stands beside the manifest of this test package, outside the
/// graph of this package: the manifest of `LiveAgentServer` tells why. Thus
/// `swift test` does not build it, and the test builds it here with
/// `swift build --package-path`. A later build of one run finds the products
/// of the first and builds nothing.
///
/// The stdout and the stderr of each `swift build` go to two log files, and
/// not to the output of the test. A failed build throws an error that holds the log.
struct LiveAgentServerBuild {
    /// The executable of the real agent with a real model.
    static let liveAgentServer = "live-agent-server"

    /// The executable of the real agent with its GraphQL tunnel, the stub
    /// model path, and the small probe endpoint.
    static let graphQLTunnelServer = "graphql-tunnel-server"

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

    /// The temporary directory of the test. It holds the log file of each
    /// `swift build`, and the state of each server that ``startServer(_:workspace:)``
    /// starts.
    let rootDirectory: URL

    /// Builds an executable, and starts it as an external agent over stdio.
    ///
    /// The server writes its state under ``rootDirectory``, and loads its
    /// configuration from `workspace`.
    ///
    /// - Parameters:
    ///   - productName: The executable product of the package, for example
    ///     ``liveAgentServer``.
    ///   - workspace: The working directory of the configuration load of the
    ///     agent.
    /// - Returns: The agent process. Its transport carries the connection.
    /// - Throws: The error of the build or of the start of the process.
    func startServer(_ productName: String, workspace: URL) async throws -> AgentProcess {
        let executable = try await makeExecutable(productName)
        return try AgentProcess(command: executable, arguments: [rootDirectory.path, workspace.path])
    }

    /// Builds an executable, and gives its absolute path.
    ///
    /// - Parameter productName: The executable product of the package.
    /// - Returns: The absolute path of the executable.
    /// - Throws: ``Failure`` for a failed `swift build`, the error of a log
    ///   file, or the error of `#require` when `--show-bin-path` wrote no
    ///   path.
    func makeExecutable(_ productName: String) async throws -> String {
        _ = try await runSwiftBuild(["--product", productName], logName: "build-\(productName).log")
        let binPathOutput = try await runSwiftBuild(["--show-bin-path"], logName: "bin-path.log")
        let binDirectory = try #require(
            binPathOutput.split(whereSeparator: \.isNewline).last,
            "swift build --show-bin-path wrote no path")
        return URL(filePath: String(binDirectory), directoryHint: .isDirectory)
            .appending(path: productName)
            .path
    }

    /// Runs `swift build --package-path <package> <arguments>`, and waits
    /// for its end.
    ///
    /// - Parameters:
    ///   - arguments: The arguments after `swift build --package-path
    ///     <package>`.
    ///   - logName: The name of the log file in ``rootDirectory`` that
    ///     receives stdout. Stderr goes to the file with the same name and
    ///     the suffix `.err`. Tests run in parallel and share one package, so
    ///     SwiftPM can write a "waiting" notice to stderr. A separate file
    ///     keeps that notice out of the stdout that the caller parses.
    /// - Returns: The stdout of the command.
    /// - Throws: ``Failure`` when the command ends with a status other than
    ///   0, or the error of the log file or of the start of the command.
    private func runSwiftBuild(_ arguments: [String], logName: String) async throws -> String {
        let swiftArguments = ["build", "--package-path", Self.packageDirectory.path] + arguments
        let outputFile = rootDirectory.appending(path: logName)
        let errorFile = rootDirectory.appending(path: logName + ".err")
        try Data().write(to: outputFile)
        try Data().write(to: errorFile)
        let process = Process()
        process.executableURL = Self.environmentLauncher
        process.arguments = ["swift"] + swiftArguments
        process.standardOutput = try FileHandle(forWritingTo: outputFile)
        process.standardError = try FileHandle(forWritingTo: errorFile)
        let status = try await Self.run(process)
        let output = try String(contentsOf: outputFile, encoding: .utf8)
        guard status == 0 else {
            let errors = try String(contentsOf: errorFile, encoding: .utf8)
            throw Failure(arguments: swiftArguments, status: status, output: output + errors)
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

/// A new temporary directory of an integration test.
enum IntegrationTemporaryDirectory {
    /// Makes a new temporary directory, with each symbolic link of its path
    /// resolved.
    ///
    /// - Parameter prefix: The prefix of the name of the directory.
    /// - Returns: The directory.
    /// - Throws: The error of the directory creation.
    static func make(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    /// Makes the `workspace` directory of a test in its temporary directory:
    /// the working directory of the agent and of its sessions.
    ///
    /// - Parameter root: The temporary directory of the test.
    /// - Returns: The workspace directory.
    /// - Throws: The error of the directory creation.
    static func makeWorkspace(in root: URL) throws -> URL {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}

extension InitializeRequest {
    /// The `initialize` request of an integration test, with the protocol
    /// version and the capabilities of the library.
    ///
    /// - Parameter clientName: The client name that the test gives.
    /// - Returns: The request.
    static func integrationTest(clientName: String) -> InitializeRequest {
        InitializeRequest(
            info: Implementation(name: clientName, version: "1.0.0"),
            protocolVersion: ACPClient.supportedProtocolVersion,
            capabilities: ACPClient.advertisedCapabilities)
    }
}
