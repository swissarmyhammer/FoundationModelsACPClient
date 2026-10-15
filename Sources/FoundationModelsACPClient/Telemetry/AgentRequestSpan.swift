import FoundationModelsACP
import Logging
import Tracing

/// Opens one server span for each ACP request or notification that the agent
/// sends to the client, in the W3C trace context that the agent put in the
/// `_meta` of the message.
///
/// The ACP extensibility rules reserve the root-level `traceparent`,
/// `tracestate` and `baggage` members of `_meta` for W3C trace context.
/// ``ClientRequestSpan`` puts that context on each request that the client
/// sends. This type reads it on each message that the agent sends, so that
/// the span of the client joins the trace of the agent. FoundationModelsACP
/// has no tracing code, thus this package makes the span.
///
/// ```swift
/// let response = try await AgentRequestSpan.run(
///     method: ClientRequestSpan.Method.requestPermission,
///     sessionId: request.sessionId,
///     meta: request.meta
/// ) { span in
///     try await answer(request, in: span)
/// }
/// ```
///
/// ## The parent of the span
///
/// When `meta` holds a valid W3C `traceparent`, the span is a child of the
/// span of the agent that the value names. When `meta` holds no valid
/// `traceparent`, the span is the root span of a new trace. It is never a
/// child of the span of the running task: the task that handles a message of
/// the agent gets the service context of the task that read the connection,
/// and that is the context of the code that opened the connection. With that
/// context, each request of the agent would become a child of an old span of
/// the host that has no relation to the request.
///
/// ## What the span holds
///
/// The span has the name ``ACPClientTelemetry/SpanName/agentRequest`` and the
/// kind `.server`. Rule 4: its attributes hold the ACP method, and the session
/// id when the message names a session. `body` gets the span, so that a
/// caller can add ``ACPClientTelemetry/AttributeKey/outcome`` and
/// ``ACPClientTelemetry/AttributeKey/routed``. No attribute holds a title, a
/// description, an option name, a message, a URL or form content.
///
/// The call also writes one "enter" log record through `TracedCall` of
/// FoundationModelsExtras when the message arrives (rule 8). A permission
/// request can wait for the user for a long time, and the record shows a
/// request that does not end.
///
/// The span records no metrics.
enum AgentRequestSpan {
    /// Runs the handling of one message of the agent in a new server span.
    ///
    /// The span ends when `body` returns or throws. When `body` throws, the
    /// span gets the error status and the `error.type` of the error, never
    /// its description, and the function throws the same error.
    ///
    /// - Parameters:
    ///   - method: The ACP wire method of the message, for example
    ///     ``ClientRequestSpan/Method/requestPermission``.
    ///   - sessionId: The session that the message names, or `nil` when the
    ///     message names no session.
    ///   - meta: The `_meta` of the message, as the agent sent it.
    ///   - tracer: The tracer of the span, or `nil` to use
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - logger: The logger of the "enter" record, or `nil` for a new logger
    ///     with the label ``ACPClientTelemetry/logLabel``.
    ///   - body: Handles the message. It gets the open span.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    nonisolated(nonsending) static func run<Output>(
        method: String,
        sessionId: SessionId?,
        meta: JSONValue?,
        tracer: (any Tracer)? = nil,
        logger: Logger? = nil,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        let activeTracer = tracer ?? InstrumentationSystem.tracer
        return try await ClientRequestSpan.withRequestSpan(
            named: ACPClientTelemetry.SpanName.agentRequest,
            ofKind: .server,
            in: startContext(of: meta, tracer: activeTracer),
            tracer: activeTracer,
            logger: logger,
            method: method,
            sessionId: sessionId,
            body
        )
    }

    /// Gives the service context that the span of one message starts in.
    ///
    /// - Parameters:
    ///   - meta: The `_meta` of the message.
    ///   - tracer: The tracer that extracts the span context of the agent.
    /// - Returns: The context with the span context of the agent when `meta`
    ///   holds a valid W3C `traceparent`, or else the top-level context, so
    ///   that the span starts a new trace.
    private static func startContext(of meta: JSONValue?, tracer: any Tracer) -> InstrumentationContext {
        ClientRequestSpan.ParentContext(extractingFrom: meta, tracer: tracer)?.instrumentationContext ?? .topLevel
    }
}
