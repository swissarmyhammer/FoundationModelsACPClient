import Foundation
import FoundationModelsACP
import Testing

// These tests drive the real `acp-client` binary and check two things.
//
// First, the telemetry bootstrap keeps standard output for the answer text
// alone (`cli-plan.md` §8, and rule 6 of the OpenTelemetry design of
// 2026-09-28). The default handler of swift-log writes to standard output. So
// an executable that does not bootstrap logging, or that bootstraps it with a
// handler that writes to standard output, puts log lines into the answer. Only
// a run of the built binary, with both descriptors captured from outside it,
// can see that.
//
// Second, the binary flushes the OTLP exporters before the process ends, and a
// collector that is not there or that never answers cannot hold the process
// longer than the shutdown bound. An exporter sends in batches, and a process
// exit does not flush it. Only a run of the built binary against a real
// receiver can see what arrived before the process ended.
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

    /// The variable that selects the OTLP transport.
    private static let protocolVariable = "OTEL_EXPORTER_OTLP_PROTOCOL"

    /// The value of ``protocolVariable`` that selects OTLP/HTTP with a
    /// protobuf body, which is what ``OTLPTestReceiver`` reads.
    private static let httpProtobufProtocol = "http/protobuf"

    /// The path that the OTLP/HTTP trace exporter posts to, below the
    /// endpoint.
    private static let tracesPath = "/v1/traces"

    /// The variable that turns the whole OpenTelemetry SDK off.
    private static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// The spellings of the value that sets ``sdkDisabledVariable``. The
    /// OpenTelemetry specification compares the value without regard to case,
    /// so each spelling must turn the SDK off. The first is the canonical
    /// spelling. The other two are not.
    private static let sdkDisabledSpellings = ["true", "TRUE", "TrUe"]

    /// The number of seconds in ``shutdownBound``.
    private static let shutdownBoundSeconds = 2

    /// The longest time the binary gives the exporters to flush before it
    /// exits. The binary states the same bound in `TelemetryServices`.
    private static let shutdownBound: Duration = .seconds(shutdownBoundSeconds)

    /// The number of seconds in ``timingTolerance``.
    private static let timingToleranceSeconds = 3

    /// The time a run with telemetry on can take past the time of the same run
    /// with telemetry off and the ``shutdownBound``. It covers the start of the
    /// exporters and the jitter of a busy test host.
    private static let timingTolerance: Duration = .seconds(timingToleranceSeconds)

    /// The command line that asks for the help text.
    private static let helpArguments = ["--help"]

    /// A command line with no agent command, which is a usage error.
    private static let usageErrorArguments = ["run", telemetryPrompt]

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

    /// The check reads the receiver after the process ended, and it does not
    /// wait. The receiver records a request before it answers, and the
    /// exporter waits for the answer before the process exits. So a trace
    /// request that is not in the record did not arrive before the process
    /// ended.
    @Test("with the endpoint on a local receiver, one run delivers its spans before the process ends")
    func withALocalReceiverTheRunDeliversItsSpans() async throws {
        let receiver = try OTLPTestReceiver.start(replying: .success)
        defer { receiver.stop() }

        let result = try await Self.runTurn(adding: Self.exporterVariables(endpoint: receiver.endpoint))

        #expect(result.exitCode == SectionNineExitCode.success, "stderr was \"\(text(result.standardError))\"")
        #expect(
            result.standardOutput == Data(telemetryAnswer.utf8),
            "stdout was \(result.standardOutput.count) bytes: \"\(text(result.standardOutput))\""
        )
        #expect(
            receiver.requestPaths.contains(Self.tracesPath),
            "No POST to \(Self.tracesPath) came before the process ended. The requests were \(receiver.requestPaths)."
        )
    }

    @Test("with the endpoint on a closed port, the run ends within the shutdown bound")
    func withTheEndpointOnAClosedPortTheRunEndsInTime() async throws {
        let endpoint = try Self.closedPortEndpoint()

        try await Self.expectRunEndsInTime(adding: Self.exporterVariables(endpoint: endpoint))
    }

    /// A receiver that reads each request and never answers is the worst
    /// collector: without the bound, each export waits for the whole exporter
    /// timeout.
    @Test("with a receiver that never answers, the run ends within the shutdown bound")
    func withASilentReceiverTheRunEndsInTime() async throws {
        let receiver = try OTLPTestReceiver.start(replying: .none)
        defer { receiver.stop() }

        try await Self.expectRunEndsInTime(adding: Self.exporterVariables(endpoint: receiver.endpoint))
    }

    @Test("with the endpoint on a local receiver, a refused turn keeps the refusal exit code")
    func withALocalReceiverARefusalKeepsItsExitCode() async throws {
        let receiver = try OTLPTestReceiver.start(replying: .success)
        defer { receiver.stop() }

        let result = try await Self.runTurn(
            adding: Self.exporterVariables(endpoint: receiver.endpoint),
            stopReason: .refusal
        )

        #expect(result.exitCode == SectionNineExitCode.refusal, "stderr was \"\(text(result.standardError))\"")
    }

    @Test("with the endpoint on a local receiver, a usage error keeps the usage exit code")
    func withALocalReceiverAUsageErrorKeepsItsExitCode() async throws {
        let receiver = try OTLPTestReceiver.start(replying: .success)
        defer { receiver.stop() }

        let result = try await runAcpClient(
            Self.usageErrorArguments,
            environment: Self.environment(adding: Self.exporterVariables(endpoint: receiver.endpoint))
        )

        #expect(result.exitCode == SectionNineExitCode.usage, "stderr was \"\(text(result.standardError))\"")
    }

    /// `--help` must write the same text to the same stream, and exit with the
    /// same code, whether telemetry is on or off.
    @Test("with the endpoint on a local receiver, --help writes the same text to stdout and exits 0")
    func withALocalReceiverTheHelpTextIsUnchanged() async throws {
        let receiver = try OTLPTestReceiver.start(replying: .success)
        defer { receiver.stop() }

        let withoutTelemetry = try await runAcpClient(Self.helpArguments, environment: Self.environment(adding: [:]))
        let withTelemetry = try await runAcpClient(
            Self.helpArguments,
            environment: Self.environment(adding: Self.exporterVariables(endpoint: receiver.endpoint))
        )

        #expect(withTelemetry.exitCode == SectionNineExitCode.success)
        #expect(withoutTelemetry.exitCode == SectionNineExitCode.success)
        #expect(!withTelemetry.standardOutput.isEmpty, "--help wrote nothing to stdout.")
        #expect(
            withTelemetry.standardOutput == withoutTelemetry.standardOutput,
            """
            --help wrote other text with telemetry on. With it: \
            "\(text(withTelemetry.standardOutput))". Without it: \
            "\(text(withoutTelemetry.standardOutput))".
            """
        )
        #expect(
            withTelemetry.standardError.isEmpty,
            "stderr was \(withTelemetry.standardError.count) bytes: \"\(text(withTelemetry.standardError))\""
        )
    }

    /// Runs one turn with telemetry off and one with `variables` added, and
    /// expects the second to take no longer than the first, plus
    /// ``shutdownBound`` and ``timingTolerance``.
    ///
    /// - Parameter variables: The exporter variables of the second run.
    /// - Throws: The write failure of the stub agent, or a run failure.
    private static func expectRunEndsInTime(adding variables: [String: String]) async throws {
        let clock = ContinuousClock()
        let normalRunTime = try await clock.measure { _ = try await runTurn(adding: [:]) }
        var result: CLIResult?
        let telemetryRunTime = try await clock.measure { result = try await runTurn(adding: variables) }

        let limit = normalRunTime + shutdownBound + timingTolerance
        #expect(result?.exitCode == SectionNineExitCode.success)
        #expect(
            telemetryRunTime <= limit,
            """
            The run with telemetry on took \(telemetryRunTime). The run with \
            telemetry off took \(normalRunTime), so the limit was \(limit).
            """
        )
    }

    /// Runs one `acp-client run` turn against a well-behaved stub agent.
    ///
    /// - Parameters:
    ///   - variables: The variables to add to an environment that holds no
    ///     `OTEL_` variable.
    ///   - stopReason: The stop reason the stub agent ends its turn with.
    /// - Returns: The finished run.
    /// - Throws: The write failure of the stub agent, or a run failure.
    private static func runTurn(
        adding variables: [String: String],
        stopReason: StopReason = .endTurn
    ) async throws -> CLIResult {
        let script = try makeWellBehavedAgent(answer: telemetryAnswer, stopReason: stopReason)
        defer { removeAgentScript(script) }
        return try await runAcpClient(
            runArguments(prompt: telemetryPrompt, script: script),
            environment: environment(adding: variables)
        )
    }

    /// Returns the variables that send each OTLP export to `endpoint` over
    /// OTLP/HTTP with a protobuf body.
    ///
    /// - Parameter endpoint: The endpoint URL text.
    /// - Returns: The variables to add to the environment of a run.
    private static func exporterVariables(endpoint: String) -> [String: String] {
        [endpointVariable: endpoint, protocolVariable: httpProtobufProtocol]
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
    /// - Throws: ``LoopbackSocketError/unavailable(errno:)`` when the socket
    ///   cannot be opened, bound or read.
    private static func closedPortEndpoint() throws -> String {
        let (descriptor, port) = try LoopbackSocket.bound()
        close(descriptor)
        return LoopbackSocket.endpoint(port: port)
    }
}
