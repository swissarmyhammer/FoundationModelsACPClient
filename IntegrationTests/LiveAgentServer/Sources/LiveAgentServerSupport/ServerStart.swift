import Foundation

/// The start of a test server: the work before the server serves the
/// connection.
///
/// An error that gets out of `main` stops the process with a Swift runtime
/// trap, and CI then shows a crash report in place of the reason. Each
/// server makes its parts in ``make(_:)``, so a start error ends the process
/// with one line on stderr and the exit status ``failureStatus``. The
/// `acp-agent` executable of FoundationModelsACPAgent does the same for its
/// start errors.
public enum ServerStart {
    /// The exit status of a server that did not start.
    public static let failureStatus: Int32 = 1

    /// Runs the start work of a server, and gives its result.
    ///
    /// Use it only for the start work: the argument parse, the agent make,
    /// and the configuration load. The serve part of the server comes after
    /// it, so the normal end of the connection is not a start error.
    ///
    /// - Parameters:
    ///   - isolation: The actor of the caller. The start work runs on it, so
    ///     the closure and its result do not cross an isolation boundary.
    ///   - start: The start work.
    /// - Returns: The result of `start`. When `start` throws, the function
    ///   does not return: it writes `<executable>: <reason>` as one line to
    ///   stderr, and exits with ``failureStatus``.
    public static func make<Started>(
        isolation: isolated (any Actor)? = #isolation,
        _ start: () async throws -> Started
    ) async -> Started {
        do {
            return try await start()
        } catch {
            exitWithReason(of: error)
        }
    }

    /// Writes the reason of a start error as one line to stderr, and exits
    /// with ``failureStatus``.
    ///
    /// - Parameter error: The start error.
    private static func exitWithReason(of error: any Error) -> Never {
        let reason = String(describing: error).split(whereSeparator: \.isNewline).joined(separator: " ")
        let executableName = ProcessInfo.processInfo.processName
        FileHandle.standardError.write(Data("\(executableName): \(reason)\n".utf8))
        exit(failureStatus)
    }
}
