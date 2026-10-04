import Foundation
import FoundationModelsACP
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import AcpClientCore
@testable import FoundationModelsACPClient

// These tests cover the request metrics of `ClientRequestSpan`: the request
// counter, the duration timer and the error counter of each outgoing ACP
// request.
//
// Each test runs in a `TelemetryCapture`. The capture binds its test metrics
// factory as the task-local factory, so the code under test uses it through
// `MetricsSystem.factory`. The tests do not bootstrap the logging system: the
// capture does that one time for the process.
//
// Rule 4 of the OpenTelemetry design: a metric dimension holds the ACP method
// and the error code only. It never holds a session id, a prompt or error
// message text.

/// The dimensions of the error counter of one ACP method and one error code.
///
/// - Parameters:
///   - method: The ACP method.
///   - errorCode: The error code value of the dimension.
/// - Returns: The method and the error code, with the attribute keys as the
///   dimension names.
private func errorDimensions(method: String, errorCode: String) -> [(String, String)] {
    [RequestTelemetry.methodDimension(method), (ACPClientTelemetry.AttributeKey.errorCode, errorCode)]
}

/// Gives the error counters of one ACP method.
///
/// - Parameters:
///   - method: The ACP method.
///   - factory: The metrics factory that holds the counters.
/// - Returns: Each error counter whose method dimension is `method`.
private func errorCounters(of method: String, in factory: TestMetrics) -> [TestCounter] {
    factory.counters.filter { counter in
        counter.label == ACPClientTelemetry.MetricName.requestErrors
            && counter.dimensions.contains { $0 == RequestTelemetry.methodDimension(method) }
    }
}

/// An error that is not an ACP error, a connection error or a cancellation.
private struct UnclassifiedFailure: Error {}

/// Each error that a `send` can throw, beside the error code value that the
/// error counter must hold for it.
private let classifiedFailures: [(any Error & Sendable, String)] = [
    (ConnectionError.closed, ACPClientTelemetry.ErrorCodeValue.connection),
    (ConnectionError.timedOut, ACPClientTelemetry.ErrorCodeValue.connection),
    (CancellationError(), ACPClientTelemetry.ErrorCodeValue.cancelled),
    (UnclassifiedFailure(), ACPClientTelemetry.ErrorCodeValue.other),
    (RequestError.invalidParams, String(RequestError.invalidParams.code.wireValue)),
]

@Suite("client request metrics")
struct ClientRequestMetricsTests {
    /// One successful `session/prompt` gives one request count and one
    /// duration sample with the method as the dimension, and no error count.
    @MainActor @Test("a successful prompt gives one count and one duration, and no error", .timeLimit(.minutes(1)))
    func aSuccessfulPromptGivesOneCountAndOneDuration() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let idleGate = UpdateGate()
            let harness = await TracedSessionHarness(
                script: [],
                deferredScript: [GatedUpdates(gate: idleGate, updates: [idleState(stopReason: .endTurn)])]
            )
            _ = try await harness.session.initialize()
            let turn = Task { @MainActor in
                try await harness.runner.run()
            }
            let dimensions = [RequestTelemetry.methodDimension(ClientRequestSpan.Method.prompt)]

            // The turn ends on `idle` and cancels a prompt that is still in
            // flight. The agent sends `idle` only after the prompt answer
            // reached the client, which the request counter shows, so the
            // prompt is never cancelled.
            let answered = await eventually {
                context.metricsFactory.counters.contains { counter in
                    counter.label == ACPClientTelemetry.MetricName.requests
                        && counter.dimensions.contains { $0 == dimensions[0] }
                }
            }
            #expect(answered, "The prompt answer never reached the client.")
            idleGate.open()
            _ = try await turn.value
            await harness.teardown()

            let requests = try context.metricsFactory.expectCounter(ACPClientTelemetry.MetricName.requests, dimensions)
            let durations = try context.metricsFactory.expectTimer(ACPClientTelemetry.MetricName.requestDuration, dimensions)
            #expect(requests.totalValue == 1)
            #expect(durations.values.count == 1)
            #expect(errorCounters(of: ClientRequestSpan.Method.prompt, in: context.metricsFactory).isEmpty)
        }
    }

    /// A `session/close` that the agent refuses gives one error count, with
    /// the method and the JSON-RPC error code as the dimensions.
    @MainActor @Test("a refused session/close gives one error count with the method and the code", .timeLimit(.minutes(1)))
    func aRefusedCloseGivesOneErrorCount() async throws {
        let refusal = RequestError.invalidParams
        try await TelemetryCapture.run(forbidding: [refusal.message]) { context in
            let harness = await TracedSessionHarness(closeSessionError: refusal)
            try await harness.openAndCloseOneSession()
            await harness.teardown()

            let errors = try context.metricsFactory.expectCounter(
                ACPClientTelemetry.MetricName.requestErrors,
                errorDimensions(method: ClientRequestSpan.Method.closeSession, errorCode: String(refusal.code.wireValue))
            )
            #expect(errors.totalValue == 1)
        }
    }

    /// No metric dimension of a whole session holds the session id, the
    /// prompt or the message of an error. Each dimension name is the method
    /// key or the error code key.
    @MainActor @Test("no metric dimension holds a session id or content", .timeLimit(.minutes(1)))
    func noMetricDimensionHoldsASessionIDOrContent() async throws {
        let refusal = RequestError.invalidParams
        let forbidden = [testSession.rawValue, tracedPromptText, refusal.message]
        try await TelemetryCapture.run(forbidding: [tracedPromptText, refusal.message]) { context in
            let harness = await TracedSessionHarness(closeSessionError: refusal)
            try await harness.runWholeSession()
            await harness.teardown()

            let dimensions = context.metricRecords.flatMap(\.dimensions)
            #expect(!dimensions.isEmpty, "The session made no metric.")
            let allowedKeys = [ACPClientTelemetry.AttributeKey.rpcMethod, ACPClientTelemetry.AttributeKey.errorCode]
            for dimension in dimensions {
                #expect(allowedKeys.contains(dimension.key), "The dimension \(dimension.key) is not allowed.")
                #expect(
                    !forbidden.contains { dimension.value.contains($0) },
                    "The dimension \(dimension.key) holds \(dimension.value)."
                )
            }
        }
    }

    /// A request whose `send` throws gives one error count with the error
    /// code value of the error: the JSON-RPC code, `connection`, `cancelled`
    /// or `other`. The metrics go to the factory that the caller gave, and
    /// not to the task-local factory.
    @MainActor @Test(
        "a failed request gives the error code value of its error",
        .timeLimit(.minutes(1)),
        arguments: classifiedFailures
    )
    func aFailedRequestGivesTheErrorCodeValue(failure: any Error & Sendable, errorCode: String) async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let factory = TestMetrics()
            await #expect(throws: (any Error).self) {
                try await ClientRequestSpan.run(
                    method: ClientRequestSpan.Method.prompt,
                    sessionId: testSession,
                    metricsFactory: factory
                ) { _ -> Void in
                    throw failure
                }
            }

            let errors = try factory.expectCounter(
                ACPClientTelemetry.MetricName.requestErrors,
                errorDimensions(method: ClientRequestSpan.Method.prompt, errorCode: errorCode)
            )
            let requests = try factory.expectCounter(
                ACPClientTelemetry.MetricName.requests,
                [RequestTelemetry.methodDimension(ClientRequestSpan.Method.prompt)]
            )
            #expect(errors.totalValue == 1)
            #expect(requests.totalValue == 1)
            #expect(context.metricRecords.isEmpty, "The metrics went to the task-local factory.")
        }
    }
}
