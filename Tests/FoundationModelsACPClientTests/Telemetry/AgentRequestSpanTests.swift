import FoundationModelsACP
import FoundationModelsExtras
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPClient

// These tests cover `AgentRequestSpan`, the helper that opens one server span
// for each request or notification that the agent sends to the client. The
// span starts in the W3C trace context that the agent put in the `_meta` of
// the message, so that the span joins the trace of the agent.
//
// Each test runs in a `TelemetryCapture` and gives the tracer and the logger
// of the capture to the helper. The tracer is a `W3CInMemoryTracer`, so it
// extracts a real W3C `traceparent`.

/// The trace id of the `traceparent` that the agent sends in the tests.
private let agentTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"

/// The span id of the `traceparent` that the agent sends in the tests: the
/// span of the agent that sent the request.
private let agentSpanID = "00f067aa0ba902b7"

/// A `traceparent` value that the W3C format does not allow: the trace id
/// has upper-case letters.
private let invalidTraceparent = "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01"

/// The name of the span that the tests open around the helper, so that the
/// helper runs inside another span.
private let outerSpanName = "test.outer"

/// The error that the body of the helper throws in the tests.
private struct BodyFailure: Error, Equatable {}

/// The `_meta` values that hold no valid `traceparent`: no `_meta`, a `_meta`
/// with no `traceparent`, and a `_meta` with an invalid `traceparent`.
private let metasWithNoValidTraceparent: [JSONValue?] = [
    nil,
    .object([:]),
    .object([SpanIdentity.traceparentField: .string(invalidTraceparent)]),
]

@Suite("agent request span")
struct AgentRequestSpanTests {
    /// The helper opens exactly one span, with the agent request span name
    /// and the kind `.server`.
    @Test("the helper opens one server span with the agent request name")
    func theHelperOpensOneServerSpan() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.runAgentRequest(meta: nil, in: context)

            let spans = context.agentRequestSpans
            #expect(spans.count == 1, "The helper opened \(spans.count) spans.")
            #expect(spans.first?.kind == .server)
        }
    }

    /// A valid `traceparent` in the `_meta` makes the span a child of the
    /// span of the agent: the same trace id, and the span id of the agent as
    /// the parent span id.
    @Test("a valid traceparent makes the span a child of the span of the agent")
    func aValidTraceparentGivesTheParent() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let agentSpan = try #require(SpanIdentity(traceID: agentTraceID, spanID: agentSpanID))
            let meta = JSONValue.object([SpanIdentity.traceparentField: .string(agentSpan.traceparent)])

            try await Self.runAgentRequest(meta: meta, in: context)

            let span = try #require(context.agentRequestSpans.first)
            #expect(span.traceID == agentTraceID)
            #expect(span.parentSpanID == agentSpanID)
        }
    }

    /// A `_meta` with no valid `traceparent` makes the span a root span of a
    /// new trace, also when the helper runs inside another span. The call
    /// does not fail.
    @Test(
        "a meta with no valid traceparent gives a root span, also inside another span",
        arguments: metasWithNoValidTraceparent
    )
    func noValidTraceparentGivesARootSpan(meta: JSONValue?) async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            try await context.tracer.withSpan(outerSpanName) { _ in
                try await Self.runAgentRequest(meta: meta, in: context)
            }

            let outer = try #require(context.spans.first { $0.operationName == outerSpanName })
            let span = try #require(context.agentRequestSpans.first)
            #expect(span.parentSpanID == nil, "The span is a child of \(String(describing: span.parentSpanID)).")
            #expect(span.traceID != outer.traceID, "The span joined the trace of the outer span.")
        }
    }

    /// The span holds the ACP method and the session id of the request.
    @Test("the span holds the method and the session id")
    func theSpanHoldsTheMethodAndTheSessionID() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.runAgentRequest(sessionId: testSession, meta: nil, in: context)

            let span = try #require(context.agentRequestSpans.first)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.rpcMethod)
                    == .string(ClientRequestSpan.Method.requestPermission)
            )
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == .string(testSession.rawValue))
        }
    }

    /// A request that names no session gives a span with no session id.
    @Test("a request with no session gives a span with no session id")
    func aRequestWithNoSessionGivesNoSessionID() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.runAgentRequest(meta: nil, in: context)

            let span = try #require(context.agentRequestSpans.first)
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == nil)
        }
    }

    /// The body gets the open span, so that a caller can add attributes to
    /// it.
    @Test("the body gets the span of the request")
    func theBodyGetsTheSpan() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            try await AgentRequestSpan.run(
                method: ClientRequestSpan.Method.createElicitation,
                sessionId: nil,
                meta: nil,
                tracer: context.tracer,
                logger: context.logger
            ) { span in
                span.attributes[ACPClientTelemetry.AttributeKey.outcome] = ACPClientTelemetry.OutcomeValue.accept
            }

            let span = try #require(context.agentRequestSpans.first)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.outcome)
                    == .string(ACPClientTelemetry.OutcomeValue.accept)
            )
        }
    }

    /// An error that the body throws goes back to the caller unchanged.
    @Test("an error of the body goes back to the caller unchanged")
    func anErrorOfTheBodyGoesBackUnchanged() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            await #expect(throws: BodyFailure()) {
                try await AgentRequestSpan.run(
                    method: ClientRequestSpan.Method.completeElicitation,
                    sessionId: nil,
                    meta: nil,
                    tracer: context.tracer,
                    logger: context.logger
                ) { _ in
                    throw BodyFailure()
                }
            }
        }
    }

    /// The names of the methods that the agent sends are the ACP wire names.
    @Test("the agent method names are the ACP wire names")
    func theAgentMethodNamesAreTheWireNames() {
        #expect(ClientRequestSpan.Method.requestPermission == "session/request_permission")
        #expect(ClientRequestSpan.Method.createElicitation == "elicitation/create")
        #expect(ClientRequestSpan.Method.completeElicitation == "elicitation/complete")
    }

    /// Runs one `session/request_permission` through the helper, with the
    /// tracer and the logger of the capture, and a body that does nothing.
    ///
    /// - Parameters:
    ///   - sessionId: The session that the request names, or `nil`.
    ///   - meta: The `_meta` of the request.
    ///   - context: The capture of the test.
    /// - Throws: The error of the helper.
    private static func runAgentRequest(
        sessionId: SessionId? = nil,
        meta: JSONValue?,
        in context: TelemetryCapture.Context
    ) async throws {
        try await AgentRequestSpan.run(
            method: ClientRequestSpan.Method.requestPermission,
            sessionId: sessionId,
            meta: meta,
            tracer: context.tracer,
            logger: context.logger
        ) { _ in }
    }
}
