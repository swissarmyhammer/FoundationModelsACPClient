// This file holds names only. The three APIs below are the APIs that read the
// names: a span goes through `Tracing`, a log record through `Logging` and a
// metric through `Metrics`. The imports keep the vocabulary and the APIs that
// use it in one module.
import Logging
import Metrics
import Tracing

/// The telemetry vocabulary of the library: the span names, the attribute
/// keys, the metric names, the log metadata keys and the logger label.
///
/// Rule 3 of the OpenTelemetry design of 2026-09-28: each package keeps all of
/// its telemetry names in one vocabulary file. No other source file of the
/// library writes a telemetry name as a string literal. A name here is part of
/// the observable surface of the library: a dashboard, a query or an alert
/// that a host application builds on it must keep working. Change a name only
/// as a deliberate break.
///
/// Each span name, metric name and logger label starts with
/// `FoundationModelsACPClient.`, so a record of this library is easy to find
/// in a trace that also holds the records of the host application. An
/// attribute key and a log metadata key have the dotted form of the
/// OpenTelemetry semantic conventions, for example `rpc.method`.
///
/// Rule 1: the library uses the `Tracing`, `Logging` and `Metrics` APIs only.
/// It installs no backend. Only the host application installs one.
/// Until a backend is installed, each span and each metric does nothing.
///
/// This type gives names only. It keeps no logger and no metric in a stored
/// value: a logger keeps the handler of the time that it was made, and a
/// metric keeps the factory of the time that it was made. Make each logger and
/// each metric at the time of the call, with the names here.
///
/// ## No content
///
/// Rule 4: a value that goes with one of these names is an id, an ACP method
/// name, a count, a duration, an error code, a value of
/// ``ACPClientTelemetry/OutcomeValue`` or a Boolean. It is never a prompt, a
/// response, tool arguments, tool output or other content of the user. Each
/// record leaves the process through the backend of the host, and the library
/// cannot know where that backend sends it.
public enum ACPClientTelemetry {
    /// The text that each span name, metric name and logger label starts with.
    private static let prefix = "FoundationModelsACPClient."

    /// The label of each logger of the library.
    public static let logLabel = prefix + "client"

    /// The span names of the library.
    public enum SpanName {
        /// The span of one outgoing ACP request, from the send to the answer.
        ///
        /// All requests use this one name, and the ACP method goes in the
        /// ``ACPClientTelemetry/AttributeKey/rpcMethod`` attribute. One name
        /// keeps the set of span names small and fixed, and a query that
        /// wants one method filters on the attribute.
        public static let request = prefix + "request"

        /// The span of one ACP request or notification that the agent sends
        /// to the client, from its arrival to the answer of the client.
        ///
        /// The span has the kind `.server`. It starts in the W3C trace
        /// context that the agent put in the `_meta` of the message, so it
        /// joins the trace of the agent. As for ``request``, all methods use
        /// this one name, and the ACP method goes in the
        /// ``ACPClientTelemetry/AttributeKey/rpcMethod`` attribute.
        public static let agentRequest = prefix + "agent.request"
    }

    /// The attribute keys of the spans of the library.
    ///
    /// Each key follows the OpenTelemetry semantic conventions where a
    /// convention exists.
    public enum AttributeKey {
        /// The ACP method of the request, for example `session/prompt`. This
        /// is the `rpc.method` key of the OpenTelemetry RPC conventions.
        public static let rpcMethod = "rpc.method"

        /// The ACP session id that the request is for. This is the
        /// `session.id` key of the OpenTelemetry attribute registry. A request
        /// that has no session, for example `initialize`, has no such
        /// attribute.
        public static let sessionID = "session.id"

        /// The JSON-RPC error code of a request that failed. This is the
        /// `rpc.jsonrpc.error_code` key of the OpenTelemetry JSON-RPC
        /// conventions, because ACP is JSON-RPC 2.0. A request that did not
        /// fail has no such attribute.
        public static let errorCode = "rpc.jsonrpc.error_code"

        /// The outcome of a request that the agent sent, as the client
        /// answered it. The value is always one of
        /// ``ACPClientTelemetry/OutcomeValue``, and never a string that the
        /// agent sent. No OpenTelemetry convention names this fact, so the
        /// key has the `acp.` namespace.
        public static let outcome = "acp.response.outcome"

        /// A Boolean: `true` when the client gave a request of the agent to
        /// a model that waits for the answer of the user, and `false` when
        /// the client answered it with a fallback. No OpenTelemetry
        /// convention names this fact, so the key has the `acp.` namespace.
        public static let routed = "acp.request.routed"
    }

    /// The metric names of the library. Each metric has the ACP method as a
    /// dimension, with the ``ACPClientTelemetry/AttributeKey/rpcMethod`` key.
    /// The error counter also has the error code as a dimension, with the
    /// ``ACPClientTelemetry/AttributeKey/errorCode`` key.
    public enum MetricName {
        /// The counter that counts each outgoing ACP request.
        public static let requests = prefix + "requests"

        /// The timer that records the duration of each outgoing ACP request,
        /// from the send to the answer.
        public static let requestDuration = prefix + "request.duration"

        /// The counter that counts each outgoing ACP request that failed.
        public static let requestErrors = prefix + "request.errors"
    }

    /// The error code values of the error counter
    /// ``ACPClientTelemetry/MetricName/requestErrors`` that are not a JSON-RPC
    /// error code.
    ///
    /// A request that the agent refuses with a `RequestError` has the
    /// JSON-RPC error code as its value, for example `-32602`. Each other
    /// failure has one of these values. The set of values is small and
    /// fixed, so that a metric backend keeps a small number of series
    /// (rule 4). A value never holds the message text of an error.
    public enum ErrorCodeValue {
        /// The connection to the agent closed, or the request timed out,
        /// before the agent answered. The error is a `ConnectionError`.
        public static let connection = "connection"

        /// The task of the request was cancelled. The error is a
        /// `CancellationError`.
        public static let cancelled = "cancelled"

        /// Another error that is not one of the errors above.
        public static let other = "other"
    }

    /// The values of the ``ACPClientTelemetry/AttributeKey/outcome``
    /// attribute.
    ///
    /// Each value is the name of an ACP permission outcome, an ACP
    /// elicitation action, or the result of an `elicitation/complete`. The set
    /// of values is small and fixed (rule 4). An outcome or an action that
    /// this set does not name gets ``other``: the attribute never holds a
    /// string that the agent sent.
    public enum OutcomeValue {
        /// The user selected one option of a permission request.
        public static let selected = "selected"

        /// The permission request was cancelled, for example because the
        /// turn was cancelled.
        public static let cancelled = "cancelled"

        /// The user accepted an elicitation.
        public static let accept = "accept"

        /// The user declined an elicitation.
        public static let decline = "decline"

        /// The user cancelled an elicitation.
        public static let cancel = "cancel"

        /// An `elicitation/complete` named an elicitation that the client
        /// waits for.
        public static let matched = "matched"

        /// An `elicitation/complete` named no elicitation that the client
        /// waits for.
        public static let unmatched = "unmatched"

        /// An outcome or an action that is not one of the values above.
        public static let other = "other"
    }

    /// The metadata keys of the log records of the library. Each key is the
    /// attribute key of the same value, so a log record and a span use one
    /// name for one fact.
    public enum LogMetadataKey {
        /// The ACP method of the request.
        public static let rpcMethod = AttributeKey.rpcMethod

        /// The ACP session id that the request is for.
        public static let sessionID = AttributeKey.sessionID

        /// The JSON-RPC error code of a request that failed.
        public static let errorCode = AttributeKey.errorCode
    }
}
