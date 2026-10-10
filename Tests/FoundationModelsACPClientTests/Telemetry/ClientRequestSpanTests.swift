import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPClient

// These tests cover `ClientRequestSpan`, the helper that opens one client span
// for each outgoing ACP request and puts the W3C trace context of that span
// into the `_meta` of the request. With it, the spans of the agent join the
// trace of the client.
//
// Each test runs in a `TelemetryCapture`. The capture binds a
// `W3CInMemoryTracer` as the task-local tracer, so the code under test uses it
// through `InstrumentationSystem.tracer`, and the tracer injects a real W3C
// `traceparent`. The tests do not bootstrap the logging system: the capture
// does that one time for the process.
//
// Each test drives the real `ConnectionModel` and `SessionModel` through a
// `TracedSessionHarness`, with a `ScriptedStubAgent` on the far end. The stub
// records the `_meta` of each message it gets, which is the value that
// crosses the process boundary.

/// The name of the `_meta` member that a caller gives beside the trace
/// context.
private let vendorMemberName = "vendor.example/requestTag"

/// The value of the `_meta` member that a caller gives beside the trace
/// context.
private let vendorMemberValue = "tag-7"

/// The ACP requests that one whole session sends: `initialize`, then
/// `session/new`, then `session/prompt`, then `session/close`.
private let sessionRequestMethods = [
    ClientRequestSpan.Method.initialize,
    ClientRequestSpan.Method.newSession,
    ClientRequestSpan.Method.prompt,
    ClientRequestSpan.Method.closeSession,
]

/// The ACP requests of one whole session that name a session. `initialize`
/// comes before each session, and the session id of `session/new` is not
/// known until the agent answers.
private let requestMethodsWithSessionID = [
    ClientRequestSpan.Method.prompt,
    ClientRequestSpan.Method.closeSession,
]

@Suite("client request span")
struct ClientRequestSpanTests {
    /// Each request of one whole session gives exactly one finished span of
    /// kind `.client`, with the request span name and the method attribute.
    @MainActor @Test("each request of a session gives one finished client span", .timeLimit(.minutes(1)))
    func eachRequestGivesOneClientSpan() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let harness = await TracedSessionHarness()
            try await harness.runWholeSession()
            await harness.teardown()

            for method in sessionRequestMethods {
                let spans = context.requestSpans(of: method)
                #expect(spans.count == 1, "\(method) gave \(spans.count) spans.")
                #expect(spans.first?.kind == .client, "The span of \(method) is not of kind client.")
            }
        }
    }

    /// A request that names a session puts the session id on its span.
    @MainActor @Test("a request that names a session puts the session id on its span", .timeLimit(.minutes(1)))
    func aRequestThatNamesASessionPutsItOnTheSpan() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let harness = await TracedSessionHarness()
            try await harness.runWholeSession()
            await harness.teardown()

            for method in requestMethodsWithSessionID {
                let span = try #require(context.requestSpans(of: method).first)
                #expect(
                    span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == .string(testSession.rawValue),
                    "The span of \(method) has no session id."
                )
            }
        }
    }

    /// The `_meta` that the agent gets holds a `traceparent` with the trace id
    /// and the span id of the matching client span. This is what lets the
    /// spans of the agent join the trace of the client.
    @MainActor @Test("the agent gets the traceparent of each client span", .timeLimit(.minutes(1)))
    func theAgentGetsTheTraceparentOfEachClientSpan() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let harness = await TracedSessionHarness()
            try await harness.runWholeSession()
            await harness.teardown()

            for method in sessionRequestMethods {
                let span = try #require(context.requestSpans(of: method).first)
                let meta = try #require(harness.receivedMeta(of: method).first, "The agent got no \(method).")
                let identity = try RequestTelemetry.traceparentIdentity(in: meta)
                #expect(identity.traceID == span.traceID, "The traceparent of \(method) names another trace.")
                #expect(identity.spanID == span.spanID, "The traceparent of \(method) names another span.")
            }
        }
    }

    /// Each request writes one "enter" log record when it starts (rule 8), so
    /// that a request that hangs is visible before its span ends.
    @MainActor @Test("each request writes one enter log record", .timeLimit(.minutes(1)))
    func eachRequestWritesOneEnterRecord() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let harness = await TracedSessionHarness()
            try await harness.runWholeSession()
            await harness.teardown()

            for method in sessionRequestMethods {
                let records = context.logRecords.filter { record in
                    record.metadata[ACPClientTelemetry.LogMetadataKey.rpcMethod] == .string(method)
                }
                #expect(records.count == 1, "\(method) wrote \(records.count) enter records.")
                #expect(records.first?.level == TracedCall.enterLevel)
            }
        }
    }

    /// A request that the agent refuses gives a span with the error status
    /// and the JSON-RPC error code. The span records no error object, because
    /// a tracing backend writes the message text of a recorded error, and
    /// rule 4 keeps that text out of telemetry.
    @MainActor @Test("a refused request gives an error span with the error code", .timeLimit(.minutes(1)))
    func aRefusedRequestGivesAnErrorSpanWithItsCode() async throws {
        let refusal = RequestError.invalidParams
        try await TelemetryCapture.run(forbidding: [refusal.message]) { context in
            let harness = await TracedSessionHarness(closeSessionError: refusal)
            try await harness.openAndCloseOneSession()
            await harness.teardown()

            let span = try #require(context.requestSpans(of: ClientRequestSpan.Method.closeSession).first)
            #expect(span.status?.code == .error)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.errorCode)
                    == .int64(Int64(refusal.code.wireValue))
            )
            #expect(span.errors.isEmpty, "The span recorded the error object: \(span.errors.map(\.error)).")
        }
    }

    /// A request that the agent answers gives a span with no error status and
    /// no error code.
    @MainActor @Test("an answered request gives a span with no error", .timeLimit(.minutes(1)))
    func anAnsweredRequestGivesASpanWithNoError() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let harness = await TracedSessionHarness()
            try await harness.initialize()
            await harness.teardown()

            let span = try #require(context.requestSpans(of: ClientRequestSpan.Method.initialize).first)
            #expect(span.status?.code != .error)
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.errorCode) == nil)
        }
    }

    /// The helper adds the trace context to the `_meta` that the caller gave,
    /// and keeps each other member of it.
    @MainActor @Test("the helper keeps each other member of the given meta", .timeLimit(.minutes(1)))
    func theHelperKeepsEachOtherMetaMember() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let given = JSONValue.object([vendorMemberName: .string(vendorMemberValue)])

            let sent = try await ClientRequestSpan.run(
                method: ClientRequestSpan.Method.prompt,
                sessionId: testSession,
                meta: given,
                tracer: context.tracer,
                logger: context.logger
            ) { meta in
                meta
            }

            let span = try #require(context.requestSpans(of: ClientRequestSpan.Method.prompt).first)
            let identity = try #require(SpanIdentity(traceID: span.traceID, spanID: span.spanID))
            #expect(
                sent == .object([
                    vendorMemberName: .string(vendorMemberValue),
                    SpanIdentity.traceparentField: .string(identity.traceparent),
                ])
            )
        }
    }
}
