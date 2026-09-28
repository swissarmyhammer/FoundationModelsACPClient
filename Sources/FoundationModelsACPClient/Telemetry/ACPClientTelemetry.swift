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
/// It installs no backend. Only the `acp-client` executable installs one.
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
/// name, a count, a duration or an error code. It is never a prompt, a
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
    }

    /// The metric names of the library. Each metric has the ACP method as a
    /// dimension, with the ``ACPClientTelemetry/AttributeKey/rpcMethod`` key.
    public enum MetricName {
        /// The counter that counts each outgoing ACP request.
        public static let requests = prefix + "requests"

        /// The timer that records the duration of each outgoing ACP request,
        /// from the send to the answer.
        public static let requestDuration = prefix + "request.duration"

        /// The counter that counts each outgoing ACP request that failed.
        public static let requestErrors = prefix + "request.errors"
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
