import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

@testable import AcpClientCore
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
// Each test drives the real `AgentSession` and `TurnRunner` over
// `InMemoryTransport.pair()`, with a `ScriptedStubAgent` on the far end. The
// stub records the `_meta` of each message it gets, which is the value that
// crosses the process boundary.
//
// Both packages export a type called `TerminalOutput`, and this file imports
// both, so the terminal layer of the binary is named
// `AcpClientCore.TerminalOutput` in full.

/// The text of the prompt of each turn in this file.
///
/// Rule 4 of the OpenTelemetry design: no span, log record or metric holds a
/// prompt. The capture of each turn forbids this text.
private let tracedPromptText = "Tell me the secret word of the traced turn."

/// The answer text that the agent sends before a turn is cancelled.
private let partialAnswerText = "The first half of the answer."

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

/// An ``AgentSession`` and a ``TurnRunner`` over one end of an in-memory pair,
/// with a ``ScriptedStubAgent`` on the other end.
@MainActor
private struct TracedSessionHarness {
    /// The connected seam.
    let session: AgentSession

    /// The turn of the session.
    let runner: TurnRunner

    /// The agent-side connection. A test holds it so the far end of the pair
    /// outlives the test body.
    let agentConnection: AgentSideConnection

    /// The stubs the agent-side factory built. The factory runs one time, so
    /// the list holds one element.
    private let builtAgents: ThreadSafeBuffer<ScriptedStubAgent>

    /// Where a test puts the interrupts of the running turn.
    private let interruptFeed: AsyncStream<TurnInterrupt>.Continuation

    /// The `_meta` of each message that the agent got, in arrival order.
    var receivedMeta: [ReceivedMeta] {
        builtAgents.elements.last?.receivedMeta ?? []
    }

    /// Builds the seam and the turn over a new pair and a new stub.
    ///
    /// - Parameters:
    ///   - script: The updates the stub sends before it answers the prompt.
    ///   - cancelScript: The updates the stub sends when `session/cancel`
    ///     arrives.
    ///   - closeSessionError: The error the stub answers `session/close` with.
    init(
        script: [SessionUpdate] = [idleState(stopReason: .endTurn)],
        cancelScript: [SessionUpdate] = [],
        closeSessionError: RequestError = .methodNotFound(ClientRequestSpan.Method.closeSession)
    ) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let builtAgents = ThreadSafeBuffer<ScriptedStubAgent>()
        self.builtAgents = builtAgents
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: script,
                cancelScript: cancelScript,
                closeSessionError: closeSessionError
            )
            builtAgents.append(stub)
            return stub
        }
        let terminal = AcpClientCore.TerminalOutput(
            verbosity: .normal,
            isStandardErrorATerminal: { false },
            sink: { _ in }
        )
        let (interrupts, interruptFeed) = AsyncStream<TurnInterrupt>.makeStream()
        self.interruptFeed = interruptFeed
        session = await AgentSession(over: clientEnd, terminal: terminal, cwd: nil)
        runner = TurnRunner(
            session: session,
            prompt: tracedPromptText,
            terminal: terminal,
            answerSink: { _ in },
            interrupts: interrupts
        )
    }

    /// Sends each request of one whole session: `initialize`, the turn, and
    /// `session/close`.
    ///
    /// - Throws: Whatever `initialize` or the turn threw.
    func runWholeSession() async throws {
        _ = try await session.initialize()
        _ = try await runner.run()
        await session.closeSession(testSession)
    }

    /// Gives the `_meta` that the agent got for one method.
    ///
    /// - Parameter method: The ACP method.
    /// - Returns: The `_meta` of each message of that method, in arrival
    ///   order.
    func receivedMeta(of method: String) -> [JSONValue?] {
        receivedMeta.filter { $0.method == method }.map(\.meta)
    }

    /// Sends one interrupt into the running turn, as a `Ctrl-C` does.
    ///
    /// - Parameter interrupt: What the press asks of the turn.
    func interrupt(_ interrupt: TurnInterrupt) {
        interruptFeed.yield(interrupt)
    }

    /// Tears the connection down, as every exit path of the binary does.
    func teardown() async {
        interruptFeed.finish()
        await session.teardown()
        withExtendedLifetime(agentConnection) {}
    }
}

/// Gives the finished request spans of one ACP method.
///
/// - Parameters:
///   - method: The ACP method.
///   - context: The capture that holds the spans.
/// - Returns: Each finished span whose name is the request span name and whose
///   method attribute is `method`.
private func requestSpans(of method: String, in context: TelemetryCapture.Context) -> [FinishedInMemorySpan] {
    context.spans.filter { span in
        span.operationName == ACPClientTelemetry.SpanName.request
            && span.attributes.get(ACPClientTelemetry.AttributeKey.rpcMethod) == .string(method)
    }
}

/// Reads the ids of the `traceparent` in one `_meta` value.
///
/// - Parameter meta: The `_meta` that the agent got.
/// - Returns: The ids of the span that the `traceparent` names.
/// - Throws: An issue when `meta` holds no valid `traceparent`.
private func traceparentIdentity(in meta: JSONValue?) throws -> SpanIdentity {
    let traceContext = try #require(TraceContextMeta.extract(from: meta), "The _meta holds no traceparent: \(String(describing: meta))")
    return try #require(SpanIdentity(traceparent: traceContext.traceparent))
}

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
                let spans = requestSpans(of: method, in: context)
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
                let span = try #require(requestSpans(of: method, in: context).first)
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
                let span = try #require(requestSpans(of: method, in: context).first)
                let meta = try #require(harness.receivedMeta(of: method).first, "The agent got no \(method).")
                let identity = try traceparentIdentity(in: meta)
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

    /// `session/cancel` carries the trace of the current turn: its
    /// `traceparent` names the trace of the `session/prompt` span, and its own
    /// span is a child of that prompt span.
    ///
    /// The interrupt is sent only after the agent got the prompt, so the press
    /// lands inside the turn.
    @MainActor @Test("session/cancel carries the trace of the current turn", .timeLimit(.minutes(1)))
    func theCancelCarriesTheTraceOfTheTurn() async throws {
        try await TelemetryCapture.run(forbidding: [tracedPromptText]) { context in
            let harness = await TracedSessionHarness(
                script: [agentChunk(text: partialAnswerText)],
                cancelScript: [idleState(stopReason: .cancelled)]
            )
            _ = try await harness.session.initialize()
            let turn = Task { @MainActor in try await harness.runner.run() }
            #expect(
                await eventually { !harness.receivedMeta(of: ClientRequestSpan.Method.prompt).isEmpty },
                "The agent never got the prompt."
            )
            harness.interrupt(.cancelTurn)
            #expect(try await turn.value == .stopped(.cancelled))
            #expect(
                await eventually { !requestSpans(of: ClientRequestSpan.Method.cancelSession, in: context).isEmpty },
                "The session/cancel span never ended."
            )
            await harness.teardown()

            let promptSpan = try #require(requestSpans(of: ClientRequestSpan.Method.prompt, in: context).first)
            let cancelSpan = try #require(requestSpans(of: ClientRequestSpan.Method.cancelSession, in: context).first)
            let meta = try #require(harness.receivedMeta(of: ClientRequestSpan.Method.cancelSession).first)
            let identity = try traceparentIdentity(in: meta)
            #expect(identity.traceID == promptSpan.traceID)
            #expect(identity.spanID == cancelSpan.spanID)
            #expect(cancelSpan.parentSpanID == promptSpan.spanID)
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
            await harness.session.closeSession(testSession)
            await harness.teardown()

            let span = try #require(requestSpans(of: ClientRequestSpan.Method.closeSession, in: context).first)
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
            _ = try await harness.session.initialize()
            await harness.teardown()

            let span = try #require(requestSpans(of: ClientRequestSpan.Method.initialize, in: context).first)
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

            let span = try #require(requestSpans(of: ClientRequestSpan.Method.prompt, in: context).first)
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
