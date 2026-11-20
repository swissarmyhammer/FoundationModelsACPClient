import Foundation
import Testing

// The start errors of the test servers of the `LiveAgentServer` package.
//
// A start error (a wrong argument list, a configuration that does not load,
// a profile that does not resolve) must not stop the server with a Swift
// runtime trap. The server writes one line with the reason to stderr, and
// exits with status 1. CI then shows the reason, and not a crash report.

/// Each test server tells a start error on stderr and exits with status 1.
struct ServerStartFailureTests {
    /// The prefix of the name of the temporary directory of the test.
    private static let temporaryDirectoryPrefix = "acp-client-server-start-failure"

    /// The exit status of a server that did not start.
    private static let startFailureStatus: Int32 = 1

    /// The part of the usage text of `LaunchArguments.Failure` that tells the
    /// count of arguments: the test gives no arguments.
    private static let noArgumentsReason = "(got 0 arguments)"

    /// The text of the Swift runtime when an error gets out of `main`.
    private static let runtimeTrapText = "Fatal error"

    /// A server with no arguments writes the reason as one line on stderr,
    /// and exits with status 1 with no runtime trap.
    ///
    /// - Parameter productName: The executable product of the server.
    @Test(arguments: [LiveAgentServerBuild.liveAgentServer, LiveAgentServerBuild.graphQLTunnelServer])
    func aServerWithAWrongArgumentListExitsWithStatusOneAndTellsTheReason(productName: String) async throws {
        let root = try IntegrationTemporaryDirectory.make(prefix: Self.temporaryDirectoryPrefix)
        defer { try? FileManager.default.removeItem(at: root) }

        let exit = try await LiveAgentServerBuild(rootDirectory: root).runToExit(productName, arguments: [])

        #expect(exit.reason == .exit, "the server stopped on signal \(exit.status)")
        #expect(exit.status == Self.startFailureStatus)
        #expect(exit.standardError.contains(Self.noArgumentsReason))
        #expect(!exit.standardError.contains(Self.runtimeTrapText))
        #expect(exit.standardError.split(whereSeparator: \.isNewline).count == 1)
    }
}
