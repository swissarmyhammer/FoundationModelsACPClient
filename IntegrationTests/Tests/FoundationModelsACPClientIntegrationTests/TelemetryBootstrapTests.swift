import Foundation
import Testing

// These tests drive the real `acp-client` binary and check that the telemetry
// bootstrap keeps standard output for the answer text alone (`cli-plan.md` §8,
// and rule 6 of the OpenTelemetry design of 2026-09-28).
//
// The default handler of swift-log writes to standard output. So an executable
// that does not bootstrap logging, or that bootstraps it with a handler that
// writes to standard output, puts log lines into the answer. Only a run of the
// built binary, with both descriptors captured from outside it, can see that.
//
// Each run gets an environment with no `OTEL_` variable in it, and then the
// variables that one test adds. A variable that the test runner inherited must
// not select the path a test means to check.

/// The number of minutes this file's suite allows itself.
///
/// Each test here spawns two real processes: the binary, and the agent it
/// starts. The bound each run really rests on is ``TransportTestDeadline/limit``.
/// This one is the backstop that ends a wedged suite.
private let telemetrySuiteTimeLimitMinutes = 5

/// The prompt every run in this file sends.
private let telemetryPrompt = "write a haiku"

/// The reply text the stub agent in this file streams. It carries no trailing
/// newline, because each assertion below compares bytes.
private let telemetryAnswer = "The stub agent answered."

/// `acp-client run` with and without the OpenTelemetry exporter variables.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client telemetry bootstrap",
    .serialized,
    .timeLimit(.minutes(telemetrySuiteTimeLimitMinutes))
)
struct TelemetryBootstrapTests {
    /// The prefix of every standard OpenTelemetry environment variable.
    private static let openTelemetryVariablePrefix = "OTEL_"

    /// The variable that turns the OTLP exporters on.
    private static let endpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The variable that turns the whole OpenTelemetry SDK off.
    private static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// The spellings of the value that sets ``sdkDisabledVariable``. The
    /// OpenTelemetry specification compares the value without regard to case,
    /// so each spelling must turn the SDK off. The first is the canonical
    /// spelling. The other two are not.
    private static let sdkDisabledSpellings = ["true", "TRUE", "TrUe"]

    /// The loopback address that the closed port stands on.
    private static let loopbackAddress = "127.0.0.1"

    /// The port number that asks the kernel for a free port.
    private static let anyFreePort: in_port_t = 0

    /// The number of `sockaddr` values the rebound address pointer covers.
    private static let oneSocketAddress = 1

    @Test("without OTEL variables, stdout holds the answer alone and stderr holds nothing")
    func withoutTheEndpointTheStreamsHoldNoLogLines() async throws {
        let result = try await Self.runTurn(adding: [:])

        #expect(result.exitCode == SectionNineExitCode.success)
        #expect(
            result.standardOutput == Data(telemetryAnswer.utf8),
            "stdout was \(result.standardOutput.count) bytes: \"\(text(result.standardOutput))\""
        )
        #expect(
            result.standardError.isEmpty,
            "stderr was \(result.standardError.count) bytes: \"\(text(result.standardError))\""
        )
    }

    @Test("with the endpoint on a closed port, the run exits 0 and stdout holds the answer alone")
    func withTheEndpointOnAClosedPortTheRunSucceeds() async throws {
        let endpoint = try Self.closedPortEndpoint()

        let result = try await Self.runTurn(adding: [Self.endpointVariable: endpoint])

        #expect(result.exitCode == SectionNineExitCode.success, "stderr was \"\(text(result.standardError))\"")
        #expect(
            result.standardOutput == Data(telemetryAnswer.utf8),
            "stdout was \(result.standardOutput.count) bytes: \"\(text(result.standardOutput))\""
        )
    }

    /// A spelling that is not lowercase must also turn the SDK off. If it did
    /// not, the binary would ask swift-otel for the exporters. swift-otel
    /// reads the spelling as "disabled" and refuses to make a backend, and the
    /// binary writes that failure to stderr. So the empty stderr is the check
    /// that the SDK-disabled path was taken.
    @Test(
        "with the endpoint set and the SDK disabled, the run exits 0, stdout holds the answer alone and stderr holds nothing",
        arguments: sdkDisabledSpellings
    )
    func withTheSDKDisabledTheRunSucceeds(sdkDisabledValue: String) async throws {
        let endpoint = try Self.closedPortEndpoint()

        let result = try await Self.runTurn(
            adding: [Self.endpointVariable: endpoint, Self.sdkDisabledVariable: sdkDisabledValue]
        )

        #expect(result.exitCode == SectionNineExitCode.success, "stderr was \"\(text(result.standardError))\"")
        #expect(
            result.standardOutput == Data(telemetryAnswer.utf8),
            "stdout was \(result.standardOutput.count) bytes: \"\(text(result.standardOutput))\""
        )
        #expect(
            result.standardError.isEmpty,
            "stderr was \(result.standardError.count) bytes: \"\(text(result.standardError))\""
        )
    }

    /// Runs one `acp-client run` turn against a well-behaved stub agent.
    ///
    /// - Parameter variables: The variables to add to an environment that holds
    ///   no `OTEL_` variable.
    /// - Returns: The finished run.
    /// - Throws: The write failure of the stub agent, or a run failure.
    private static func runTurn(adding variables: [String: String]) async throws -> CLIResult {
        let script = try makeWellBehavedAgent(answer: telemetryAnswer)
        defer { removeAgentScript(script) }
        return try await runAcpClient(
            runArguments(prompt: telemetryPrompt, script: script),
            environment: environment(adding: variables)
        )
    }

    /// Returns the environment of this process with no `OTEL_` variable, and
    /// then with `variables` added.
    ///
    /// - Parameter variables: The variables to add.
    /// - Returns: The environment for one run.
    private static func environment(adding variables: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix(openTelemetryVariablePrefix) }
            .merging(variables) { _, added in added }
    }

    /// Returns an `http` endpoint on a loopback port where nothing listens.
    ///
    /// The kernel gives a free port to a socket bound to port 0. The socket
    /// then closes, so no process listens on that port when the run starts.
    ///
    /// - Returns: The endpoint URL text.
    /// - Throws: ``TelemetryBootstrapTestError/closedPortUnavailable(errno:)``
    ///   when the socket cannot be opened, bound or read.
    private static func closedPortEndpoint() throws -> String {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw TelemetryBootstrapTestError.closedPortUnavailable(errno: errno)
        }
        defer { close(socketDescriptor) }
        let port = try boundPort(of: socketDescriptor)
        return "http://\(loopbackAddress):\(port)"
    }

    /// Binds `socketDescriptor` to a free loopback port and returns that port.
    ///
    /// - Parameter socketDescriptor: An open IPv4 stream socket.
    /// - Returns: The port number the kernel gave, in host byte order.
    /// - Throws: ``TelemetryBootstrapTestError/closedPortUnavailable(errno:)``
    ///   when the bind or the read of the address fails.
    private static func boundPort(of socketDescriptor: Int32) throws -> in_port_t {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = anyFreePort
        address.sin_addr.s_addr = inet_addr(loopbackAddress)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: oneSocketAddress) { generic in
                bind(socketDescriptor, generic, length) == 0
                    && getsockname(socketDescriptor, generic, &length) == 0
            }
        }
        guard bound else {
            throw TelemetryBootstrapTestError.closedPortUnavailable(errno: errno)
        }
        return in_port_t(bigEndian: address.sin_port)
    }
}

/// The failures of the telemetry bootstrap suite's own setup.
enum TelemetryBootstrapTestError: Error, CustomStringConvertible {
    /// No loopback port could be found, and `errno` says why.
    case closedPortUnavailable(errno: Int32)

    /// A human-readable description of this error.
    var description: String {
        switch self {
        case .closedPortUnavailable(let errno):
            return "No free loopback port could be found (errno \(errno))."
        }
    }
}
