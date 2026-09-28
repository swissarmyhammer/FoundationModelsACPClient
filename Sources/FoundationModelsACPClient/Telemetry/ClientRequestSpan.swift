import FoundationModelsACP
import FoundationModelsExtras
import Logging
import Metrics
import Tracing

/// Opens one client span for each outgoing ACP request, and puts the W3C trace
/// context of that span into the `_meta` of the request.
///
/// Rule 7 of the OpenTelemetry design of 2026-09-28: the W3C `traceparent` and
/// `tracestate` values cross the process boundary in the ACP `_meta`. The
/// agent extracts them, and its spans then join the trace of the client.
/// ``TraceContextMeta`` of FoundationModelsACP is the codec for `_meta`. This
/// type adapts that codec to the tracer.
///
/// A host that sends ACP requests through its own `ClientSideConnection` uses
/// this type as the binary does: it builds each request with the `_meta` that
/// the `send` closure gets.
///
/// ```swift
/// let response = try await ClientRequestSpan.run(
///     method: ClientRequestSpan.Method.prompt,
///     sessionId: sessionId
/// ) { meta in
///     try await connection.prompt(PromptRequest(prompt: blocks, sessionId: sessionId, meta: meta))
/// }
/// ```
///
/// ## What the span holds
///
/// The span has the name ``ACPClientTelemetry/SpanName/request`` and the kind
/// `.client`. Rule 4: its attributes hold the ACP method, the session id when
/// the request names a session, and the JSON-RPC error code when the request
/// failed. They never hold a prompt, a response or a `_meta` value.
///
/// The call also writes one "enter" log record through `TracedCall` of
/// FoundationModelsExtras when the request starts (rule 8). A tracing backend
/// exports a span only when the span ends, and `session/prompt` can wait for a
/// long time. The record shows a request that does not end.
///
/// ## Errors
///
/// A request that fails gives a span with the error status. When the error is
/// a `RequestError`, the span also holds its code. The span does not record
/// the error object: a tracing backend writes the message text of a recorded
/// error, and rule 4 keeps that text out of telemetry. The call throws the
/// same error that `send` threw.
///
/// ## Metrics
///
/// Each request also records three metrics, through the `Metrics` API:
///
/// - One count on the counter ``ACPClientTelemetry/MetricName/requests``.
/// - One duration on the timer ``ACPClientTelemetry/MetricName/requestDuration``,
///   from the send to the answer or the error. A swift-metrics `Timer` holds
///   nanoseconds, and an OpenTelemetry backend exports it as a duration
///   histogram. That is the shape of the OpenTelemetry `rpc.client.duration`
///   metric.
/// - When `send` throws, one count on the counter
///   ``ACPClientTelemetry/MetricName/requestErrors``.
///
/// Rule 4: the dimensions of each metric are the ACP method and, for the
/// error counter, the error code only. The error code is the JSON-RPC code of
/// a `RequestError`, or a value of ``ACPClientTelemetry/ErrorCodeValue``. A
/// dimension never holds the session id, because each session would then
/// make a new series. It never holds content or the message text of an
/// error.
///
/// The call makes each metric at the time of the call, from the metrics
/// factory that the caller gives or from `MetricsSystem.factory`. A metric
/// keeps the factory of the time that it was made, so a metric in a stored
/// value would not see a factory that a test or a host binds later.
public enum ClientRequestSpan {
    /// The ACP wire method names that the `acp-client` binary sends. A host
    /// can give each of these, or another ACP method name, as the `method` of
    /// ``run(method:sessionId:meta:parent:tracer:logger:metricsFactory:_:)``.
    public enum Method {
        /// The `initialize` request.
        public static let initialize = "initialize"

        /// The request that opens a session.
        public static let newSession = "session/new"

        /// The request that sends one prompt.
        public static let prompt = "session/prompt"

        /// The request that closes a session.
        public static let closeSession = "session/close"

        /// The notification that cancels the turn of a session.
        public static let cancelSession = "session/cancel"
    }

    /// The trace context that a request span starts in.
    ///
    /// A request span is a child of the span of this context. The value is
    /// opaque, so that a caller can keep and give a context without the
    /// tracing API. ``current`` gives the context of the running task. In the
    /// `send` closure of
    /// ``run(method:sessionId:meta:parent:tracer:logger:metricsFactory:_:)``,
    /// that is the context of the request span.
    ///
    /// A request that belongs to an earlier request, but runs on another task,
    /// uses this type to join the trace of that request. For example, the
    /// `session/cancel` of a turn is a child of the `session/prompt` of the
    /// turn.
    public struct ParentContext: Sendable {
        /// The service context that holds the span context.
        let serviceContext: ServiceContext

        /// The trace context of the running task.
        ///
        /// It is the top-level context when the task has no context.
        public static var current: ParentContext {
            ParentContext(serviceContext: ServiceContext.current ?? .topLevel)
        }
    }

    /// Sends one ACP request or notification in a new client span.
    ///
    /// The function opens the span, writes the "enter" log record, adds the
    /// W3C trace context of the span to `meta`, and calls `send` with the
    /// result. The span ends when `send` returns or throws.
    ///
    /// When the tracer injects no valid W3C `traceparent`, for example the
    /// no-op tracer of a process that bootstrapped no backend, `send` gets
    /// `meta` unchanged.
    ///
    /// - Parameters:
    ///   - method: The ACP wire method, for example ``Method/prompt``.
    ///   - sessionId: The session that the request names, or `nil` when the
    ///     request names no session.
    ///   - meta: The `_meta` that the caller wants to send. The function keeps
    ///     each member, and sets the trace context members.
    ///   - parent: The trace context to start the span in, or `nil` for the
    ///     context of the running task.
    ///   - tracer: The tracer of the span, or `nil` to use
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - logger: The logger of the "enter" record, or `nil` for a new logger
    ///     with the label ``ACPClientTelemetry/logLabel``.
    ///   - metricsFactory: The factory that makes the request metrics. The
    ///     default is `MetricsSystem.factory` at call time: the task-local
    ///     factory of `withMetricsFactory` when a caller bound one, or else
    ///     the factory that the process bootstrapped.
    ///   - send: Sends the request. It gets the `_meta` to put on the request.
    /// - Returns: The value of `send`.
    /// - Throws: The error of `send`.
    public nonisolated(nonsending) static func run<Output>(
        method: String,
        sessionId: SessionId?,
        meta: JSONValue? = nil,
        parent: ParentContext? = nil,
        tracer: (any Tracer)? = nil,
        logger: Logger? = nil,
        metricsFactory: any MetricsFactory = MetricsSystem.factory,
        _ send: nonisolated(nonsending) (_ meta: JSONValue?) async throws -> Output
    ) async throws -> Output {
        let activeTracer = tracer ?? InstrumentationSystem.tracer
        let startContext = parent ?? .current
        let result: Result<Output, any Error> = try await ServiceContext.withValue(startContext.serviceContext) {
            try await TracedCall.run(
                ACPClientTelemetry.SpanName.request,
                ofKind: .client,
                tracer: activeTracer,
                logger: logger ?? Logger(label: ACPClientTelemetry.logLabel),
                attributes: { attributes in
                    attributes[ACPClientTelemetry.AttributeKey.rpcMethod] = method
                    attributes[ACPClientTelemetry.AttributeKey.sessionID] = sessionId?.rawValue
                },
                metadata: enterMetadata(method: method, sessionId: sessionId)
            ) { span in
                await outcome(
                    of: send,
                    meta: injected(into: meta, from: span, by: activeTracer),
                    in: span,
                    metrics: RequestMetrics(method: method, factory: metricsFactory)
                )
            }
        }
        return try result.get()
    }

    /// Gives the metadata of the "enter" record of one request.
    ///
    /// - Parameters:
    ///   - method: The ACP wire method.
    ///   - sessionId: The session that the request names, or `nil`.
    /// - Returns: The method, and the session id when the request names one.
    private static func enterMetadata(method: String, sessionId: SessionId?) -> Logger.Metadata {
        var metadata: Logger.Metadata = [ACPClientTelemetry.LogMetadataKey.rpcMethod: "\(method)"]
        if let sessionId {
            metadata[ACPClientTelemetry.LogMetadataKey.sessionID] = "\(sessionId.rawValue)"
        }
        return metadata
    }

    /// Adds the W3C trace context of a span to a `_meta` value.
    ///
    /// - Parameters:
    ///   - meta: The `_meta` that the caller gave.
    ///   - span: The span of the request.
    ///   - tracer: The tracer that made the span.
    /// - Returns: `meta` with the `traceparent` and `tracestate` of the span,
    ///   or `meta` unchanged when the tracer injects no valid `traceparent`.
    private static func injected(into meta: JSONValue?, from span: any Span, by tracer: any Tracer) -> JSONValue? {
        let fields = SpanIdentity.injectedFields(of: span.context, by: tracer)
        guard let traceparent = fields[SpanIdentity.traceparentField],
              let traceContext = TraceContextMeta(
                  traceparent: traceparent,
                  tracestate: fields[SpanIdentity.tracestateField]
              )
        else {
            return meta
        }
        return traceContext.inject(into: meta)
    }

    /// Calls `send`, records a failure on the span, and records the request
    /// metrics.
    ///
    /// The error goes back in the result and not as a throw. A throw out of
    /// the body of `TracedCall.run` makes the span record the error object,
    /// and a tracing backend then writes the message text of the error.
    ///
    /// - Parameters:
    ///   - send: Sends the request.
    ///   - meta: The `_meta` to give to `send`.
    ///   - span: The span of the request.
    ///   - metrics: The metrics of the request.
    /// - Returns: The value of `send`, or the error that it threw.
    private nonisolated(nonsending) static func outcome<Output>(
        of send: nonisolated(nonsending) (_ meta: JSONValue?) async throws -> Output,
        meta: JSONValue?,
        in span: any Span,
        metrics: RequestMetrics
    ) async -> Result<Output, any Error> {
        let start = ContinuousClock.now
        let result: Result<Output, any Error>
        do {
            result = .success(try await send(meta))
        } catch {
            recordFailure(error, on: span)
            result = .failure(error)
        }
        metrics.record(result, duration: ContinuousClock.now - start)
        return result
    }

    /// Records a failed request on its span: the error status, and the
    /// JSON-RPC error code when the error is a `RequestError`.
    ///
    /// Rule 4: the span gets no error message and no error data.
    ///
    /// - Parameters:
    ///   - error: The error of the request.
    ///   - span: The span of the request.
    private static func recordFailure(_ error: any Error, on span: any Span) {
        span.setStatus(SpanStatus(code: .error))
        if let requestError = error as? RequestError {
            span.attributes[ACPClientTelemetry.AttributeKey.errorCode] = requestError.code.wireValue
        }
    }

    /// The request metrics of one ACP method, and the factory that makes
    /// them.
    ///
    /// The value makes each metric at the time that it records, so that each
    /// metric uses the factory of the call and not a factory of an earlier
    /// time.
    private struct RequestMetrics {
        /// The ACP wire method of the request.
        let method: String

        /// The factory that makes the metrics.
        let factory: any MetricsFactory

        /// The dimensions of the request counter and of the timer: the ACP
        /// method only.
        private var methodDimensions: [(String, String)] {
            [(ACPClientTelemetry.AttributeKey.rpcMethod, method)]
        }

        /// Records one request: one count, one duration, and one error count
        /// when the request failed.
        ///
        /// - Parameters:
        ///   - result: The value of `send`, or the error that it threw.
        ///   - duration: The time from the send to the answer or the error.
        func record<Output>(_ result: Result<Output, any Error>, duration: Duration) {
            Counter(label: ACPClientTelemetry.MetricName.requests, dimensions: methodDimensions, factory: factory)
                .increment()
            Metrics.Timer(
                label: ACPClientTelemetry.MetricName.requestDuration,
                dimensions: methodDimensions,
                factory: factory
            ).record(duration: duration)
            guard case .failure(let error) = result else {
                return
            }
            Counter(
                label: ACPClientTelemetry.MetricName.requestErrors,
                dimensions: methodDimensions + [(ACPClientTelemetry.AttributeKey.errorCode, Self.errorCode(of: error))],
                factory: factory
            ).increment()
        }

        /// Gives the error code value of a failed request.
        ///
        /// Rule 4: the value is a code from a small, fixed set. It is never
        /// the message text of the error.
        ///
        /// - Parameter error: The error of the request.
        /// - Returns: The JSON-RPC code of a `RequestError`, or a value of
        ///   ``ACPClientTelemetry/ErrorCodeValue`` for each other error.
        private static func errorCode(of error: any Error) -> String {
            switch error {
            case let requestError as RequestError:
                String(requestError.code.wireValue)
            case is ConnectionError:
                ACPClientTelemetry.ErrorCodeValue.connection
            case is CancellationError:
                ACPClientTelemetry.ErrorCodeValue.cancelled
            default:
                ACPClientTelemetry.ErrorCodeValue.other
            }
        }
    }
}
