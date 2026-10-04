import FoundationModelsACP
import FoundationModelsExtras
import InMemoryTracing
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPClient

// The queries that the request telemetry tests share. `ClientRequestSpanTests`,
// `ClientRequestMetricsTests`, `ContentSafetyTests` and `ModelRequestSpanTests`
// read the spans, the metric dimensions and the `traceparent` of an ACP
// request through these queries, so each query has one copy.

extension TelemetryCapture.Context {
    /// Gives the finished request spans of one ACP method.
    ///
    /// - Parameter method: The ACP method.
    /// - Returns: Each finished span whose name is the request span name and
    ///   whose method attribute is `method`.
    func requestSpans(of method: String) -> [FinishedInMemorySpan] {
        spans.filter { span in
            span.operationName == ACPClientTelemetry.SpanName.request
                && span.attributes.get(ACPClientTelemetry.AttributeKey.rpcMethod) == .string(method)
        }
    }

    /// Records an issue for each signal that the capture did not see: a span,
    /// a log record or a metric.
    ///
    /// A leak check over empty telemetry finds no leak. This check makes sure
    /// that the leak check read real records.
    ///
    /// - Parameter sourceLocation: The source location that each issue names.
    func expectEachSignal(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!spans.isEmpty, "The capture saw no span.", sourceLocation: sourceLocation)
        #expect(!logRecords.isEmpty, "The capture saw no log record.", sourceLocation: sourceLocation)
        #expect(!metricRecords.isEmpty, "The capture saw no metric.", sourceLocation: sourceLocation)
    }
}

/// The values that the request telemetry tests compare with the telemetry of
/// a request.
enum RequestTelemetry {
    /// The dimension that names one ACP method.
    ///
    /// - Parameter method: The ACP method.
    /// - Returns: The method, with the method attribute key as the dimension
    ///   name.
    static func methodDimension(_ method: String) -> (String, String) {
        (ACPClientTelemetry.AttributeKey.rpcMethod, method)
    }

    /// Reads the ids of the `traceparent` in one `_meta` value.
    ///
    /// - Parameter meta: The `_meta` that the agent got.
    /// - Returns: The ids of the span that the `traceparent` names.
    /// - Throws: An issue when `meta` holds no valid `traceparent`.
    static func traceparentIdentity(in meta: JSONValue?) throws -> SpanIdentity {
        let traceContext = try #require(
            TraceContextMeta.extract(from: meta),
            "The _meta holds no traceparent: \(String(describing: meta))"
        )
        return try #require(SpanIdentity(traceparent: traceContext.traceparent))
    }
}
