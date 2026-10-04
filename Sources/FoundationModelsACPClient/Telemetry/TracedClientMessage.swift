import FoundationModelsACP
import FoundationModelsExtras
import Tracing

/// An ACP request or notification that the client sends in a client request
/// span.
///
/// Each conforming type names its ACP wire method and the session that it
/// names, and lets ``ClientRequestSpan/send(_:parent:through:)`` put the W3C
/// trace context of the span into its `_meta`. The models send each request
/// through that function, so each request of the models gets the span, the
/// metrics and the trace context of
/// ``ClientRequestSpan/run(method:sessionId:meta:parent:tracer:logger:metricsFactory:_:)``.
protocol TracedClientMessage: Sendable {
    /// The ACP wire method of the message, for example
    /// ``ClientRequestSpan/Method/prompt``.
    static var method: String { get }

    /// The session that the message names, or `nil` when the message names no
    /// session.
    var tracedSessionId: SessionId? { get }

    /// The `_meta` of the message.
    var meta: JSONValue? { get set }
}

extension ClientRequestSpan {
    /// Sends one ACP request or notification in a new client span.
    ///
    /// The function keeps each member of the `_meta` that the caller put on
    /// `message`, adds the W3C trace context of the span to it, and gives the
    /// message with that `_meta` to `send`. The span, the "enter" log record
    /// and the metrics are those of
    /// ``run(method:sessionId:meta:parent:tracer:logger:metricsFactory:_:)``,
    /// with the method and the session of the message.
    ///
    /// - Parameters:
    ///   - message: The message as the caller made it.
    ///   - parent: The trace context to start the span in, or `nil` for the
    ///     context of the running task.
    ///   - send: Sends the message. It gets the message with the traced
    ///     `_meta`.
    /// - Returns: The value of `send`.
    /// - Throws: The error of `send`.
    nonisolated(nonsending) static func send<Message: TracedClientMessage, Output>(
        _ message: Message,
        parent: ParentContext? = nil,
        through send: nonisolated(nonsending) (Message) async throws -> Output
    ) async throws -> Output {
        try await run(
            method: Message.method,
            sessionId: message.tracedSessionId,
            meta: message.meta,
            parent: parent
        ) { meta in
            var traced = message
            traced.meta = meta
            return try await send(traced)
        }
    }
}

extension ClientRequestSpan.ParentContext {
    /// Reads the trace context that a `_meta` value names.
    ///
    /// A caller gives the `_meta` of an earlier request, for example the
    /// `_meta` of the `session/prompt` of a turn, so that a later request of
    /// the same work joins its trace as a child of its span. The context keeps
    /// the values of the context of the running task, and takes the span
    /// context that `tracer` extracts from the W3C `traceparent` and
    /// `tracestate` members.
    ///
    /// - Parameters:
    ///   - meta: The `_meta` value to read.
    ///   - tracer: The tracer that extracts the span context. The default is
    ///     `InstrumentationSystem.tracer`, the tracer of each request span.
    /// - Returns: `nil` when `meta` holds no valid W3C `traceparent`.
    init?(extractingFrom meta: JSONValue?, tracer: any Tracer = InstrumentationSystem.tracer) {
        guard let traceContext = TraceContextMeta.extract(from: meta) else {
            return nil
        }
        var fields = [SpanIdentity.traceparentField: traceContext.traceparent]
        fields[SpanIdentity.tracestateField] = traceContext.tracestate
        var context = ServiceContext.current ?? .topLevel
        tracer.extract(fields, into: &context, using: TraceFieldExtractor())
        self.init(serviceContext: context)
    }
}

/// Reads each W3C trace context field from a dictionary of fields.
private struct TraceFieldExtractor: Extractor {
    /// Reads the field under `key`.
    ///
    /// - Parameters:
    ///   - key: The name of the field.
    ///   - carrier: The fields, keyed by their names.
    /// - Returns: The value of the field, or `nil` when the dictionary has no
    ///   such field.
    func extract(key: String, from carrier: [String: String]) -> String? {
        carrier[key]
    }
}

// The ACP messages that the models send. Each one names its wire method, and
// the session that the span of the message names.

extension InitializeRequest: TracedClientMessage {
    /// The `initialize` method.
    static let method = ClientRequestSpan.Method.initialize

    /// `nil`: `initialize` names no session.
    var tracedSessionId: SessionId? { nil }
}

extension NewSessionRequest: TracedClientMessage {
    /// The `session/new` method.
    static let method = ClientRequestSpan.Method.newSession

    /// `nil`: the agent gives the session id in its answer.
    var tracedSessionId: SessionId? { nil }
}

extension ResumeSessionRequest: TracedClientMessage {
    /// The `session/resume` method.
    static let method = ClientRequestSpan.Method.resumeSession

    /// The session to resume.
    var tracedSessionId: SessionId? { sessionId }
}

extension ListSessionsRequest: TracedClientMessage {
    /// The `session/list` method.
    static let method = ClientRequestSpan.Method.listSessions

    /// `nil`: the list names no session.
    var tracedSessionId: SessionId? { nil }
}

extension CloseSessionRequest: TracedClientMessage {
    /// The `session/close` method.
    static let method = ClientRequestSpan.Method.closeSession

    /// The session to close.
    var tracedSessionId: SessionId? { sessionId }
}

extension DeleteSessionRequest: TracedClientMessage {
    /// The `session/delete` method.
    static let method = ClientRequestSpan.Method.deleteSession

    /// The session to delete.
    var tracedSessionId: SessionId? { sessionId }
}

extension LoginAuthRequest: TracedClientMessage {
    /// The `auth/login` method.
    static let method = ClientRequestSpan.Method.login

    /// `nil`: a login names no session.
    var tracedSessionId: SessionId? { nil }
}

extension LogoutAuthRequest: TracedClientMessage {
    /// The `auth/logout` method.
    static let method = ClientRequestSpan.Method.logout

    /// `nil`: a logout names no session.
    var tracedSessionId: SessionId? { nil }
}

extension PromptRequest: TracedClientMessage {
    /// The `session/prompt` method.
    static let method = ClientRequestSpan.Method.prompt

    /// The session to prompt.
    var tracedSessionId: SessionId? { sessionId }
}

extension CancelSessionNotification: TracedClientMessage {
    /// The `session/cancel` method.
    static let method = ClientRequestSpan.Method.cancelSession

    /// The session whose turn to cancel.
    var tracedSessionId: SessionId? { sessionId }
}

extension SetSessionConfigOptionRequest: TracedClientMessage {
    /// The `session/set_config_option` method.
    static let method = ClientRequestSpan.Method.setConfigOption

    /// The session whose option to change.
    var tracedSessionId: SessionId? { sessionId }
}
