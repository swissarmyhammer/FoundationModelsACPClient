import FoundationModelsACP
import FoundationModelsExtras
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPClient

// These tests cover the server span that `ModelClient` opens for each
// permission request, each elicitation and each `elicitation/complete` of the
// agent. The span shows how long the agent waited for the user, and it joins
// the trace of the agent.
//
// Each test drives the real `ConnectionModel` and `SessionModel` through a
// `TracedSessionHarness` in a `TelemetryCapture`, with a `ScriptedStubAgent` on
// the far end of `InMemoryTransport.pair()`. The router of the model gives each
// permission request to the open session model, and the test answers each
// request through that model, as a user does. The capture binds its tracer as
// the task-local tracer, so the router uses it through
// `InstrumentationSystem.tracer`.

/// The trace id of the `traceparent` that the agent sends in the tests.
private let agentTraceID = "0af7651916cd43dd8448eb211c80319c"

/// The span id of the `traceparent` that the agent sends in the tests: the
/// span of the agent that sent the permission request.
private let agentSpanID = "b7ad6b7169203331"

/// The id of a session that no model holds.
private let unknownSession = SessionId(rawValue: "session-not-open")

/// The form values that the user gives to an accepted form elicitation.
private let formContent: JSONValue = .object(["name": .string("orion")])

/// The id of an elicitation that no model holds.
private let unknownElicitationID = ElicitationId(rawValue: "elicit-unknown")

/// One answer that the user gives to an elicitation, and the outcome that the
/// span of the elicitation records for it.
enum ElicitationAnswer: CaseIterable, Sendable {
    /// The user accepts the elicitation, with the form values.
    case accept

    /// The user declines the elicitation.
    case decline

    /// The user cancels the elicitation.
    case cancel

    /// The outcome that the span records for this answer.
    var outcome: String {
        switch self {
        case .accept: ACPClientTelemetry.OutcomeValue.accept
        case .decline: ACPClientTelemetry.OutcomeValue.decline
        case .cancel: ACPClientTelemetry.OutcomeValue.cancel
        }
    }

    /// Gives this answer to one pending elicitation of a session.
    ///
    /// - Parameters:
    ///   - id: The id of the pending elicitation.
    ///   - session: The session model that holds the elicitation.
    @MainActor
    func give(to id: PendingElicitation.ID, in session: SessionModel) {
        switch self {
        case .accept: session.acceptElicitation(id, content: formContent)
        case .decline: session.declineElicitation(id)
        case .cancel: session.cancelElicitation(id)
        }
    }
}

@MainActor
@Suite("agent request span routing", .timeLimit(.minutes(1)))
struct AgentRequestSpanRoutingTests {
    // MARK: - Permission requests

    /// A permission request that the user answers gives one server span with
    /// the method, the session id, `routed = true` and the `selected` outcome.
    @Test("a selected permission gives a routed server span with the selected outcome")
    func aSelectedPermissionGivesARoutedSelectedSpan() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let harness = await Self.permissionHarness()
            try await Self.runTurn(of: harness) { session in
                try await Self.selectThePermission(in: session)
            }

            let spans = context.agentRequestSpans(of: ClientRequestSpan.Method.requestPermission)
            #expect(spans.count == 1, "The permission request gave \(spans.count) spans.")
            let span = try #require(spans.first)
            #expect(span.kind == .server)
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == .string(testSession.rawValue))
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(true))
            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.selected))
        }
    }

    /// A permission request that the user cancels gives the `cancelled`
    /// outcome. The client MUST answer `cancelled` when it cancels a turn, so
    /// the outcome is normal and the span has no error status.
    @Test("a cancelled permission gives the cancelled outcome and no error status")
    func aCancelledPermissionGivesTheCancelledOutcome() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let harness = await Self.permissionHarness()
            try await Self.runTurn(of: harness) { session in
                try await waitUntil { !session.pendingPermissions.isEmpty }
                let pending = try #require(session.pendingPermissions.first)
                await session.cancelPermission(pending.id)
            }

            let span = try #require(context.agentRequestSpans(of: ClientRequestSpan.Method.requestPermission).first)
            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.cancelled))
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(true))
            #expect(span.status?.code != .error, "The cancelled permission has the error status.")
        }
    }

    /// A permission request for a session that is not open gets the fallback
    /// answer: `routed = false` and the `cancelled` outcome.
    @Test("a permission for a session that is not open gives routed false and the cancelled outcome")
    func aPermissionForAClosedSessionIsNotRouted() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let request = RequestPermissionRequest(
                options: [SessionModelFixtures.allowOption],
                sessionId: unknownSession,
                title: "Run the tool?"
            )
            let harness = await Self.permissionHarness(request: request)
            try await Self.runTurn(of: harness) { _ in }

            let span = try #require(context.agentRequestSpans(of: ClientRequestSpan.Method.requestPermission).first)
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(false))
            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.cancelled))
        }
    }

    /// A valid `traceparent` in the `_meta` of the permission request makes the
    /// span a child of the span of the agent.
    @Test("a traceparent in the meta of the agent makes the span its child")
    func aTraceparentMakesTheSpanAChildOfTheAgent() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let agentSpan = try #require(SpanIdentity(traceID: agentTraceID, spanID: agentSpanID))
            var request = SessionModelFixtures.permissionRequest()
            request.meta = .object([SpanIdentity.traceparentField: .string(agentSpan.traceparent)])
            let harness = await Self.permissionHarness(request: request)
            try await Self.runTurn(of: harness) { session in
                try await Self.selectThePermission(in: session)
            }

            let span = try #require(context.agentRequestSpans(of: ClientRequestSpan.Method.requestPermission).first)
            #expect(span.traceID == agentTraceID)
            #expect(span.parentSpanID == agentSpanID)
        }
    }

    /// The span ends only after the user answers, so its duration holds the
    /// wait for the user.
    @Test("the span ends after the user answers")
    func theSpanEndsAfterTheUserAnswers() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let harness = await Self.permissionHarness()
            try await Self.runTurn(of: harness) { session in
                try await waitUntil { !session.pendingPermissions.isEmpty }
                let spansBeforeTheAnswer = context.agentRequestSpans(of: ClientRequestSpan.Method.requestPermission)
                #expect(spansBeforeTheAnswer.isEmpty, "The span ended before the user answered.")
                try await Self.selectThePermission(in: session)
            }

            #expect(context.agentRequestSpans(of: ClientRequestSpan.Method.requestPermission).count == 1)
        }
    }

    // MARK: - Elicitations

    /// A session-scoped elicitation gives the outcome of the answer of the
    /// user, the session id and `routed = true`.
    @Test("a session elicitation gives the outcome of the answer", arguments: ElicitationAnswer.allCases)
    func aSessionElicitationGivesTheOutcomeOfTheAnswer(answer: ElicitationAnswer) async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))
            let harness = await TracedSessionHarness(elicitation: request)
            try await Self.runTurn(of: harness) { session in
                try await waitUntil { !session.pendingElicitations.isEmpty }
                let pending = try #require(session.pendingElicitations.first)
                answer.give(to: pending.id, in: session)
            }

            let span = try #require(context.agentRequestSpans(of: ClientRequestSpan.Method.createElicitation).first)
            #expect(span.outcome == .string(answer.outcome))
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == .string(testSession.rawValue))
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(true))
        }
    }

    /// A request-scoped elicitation has no session id. With no client request
    /// in flight, no model takes it: `routed = false` and the `cancel`
    /// outcome.
    @Test("a request-scoped elicitation has no session id")
    func aRequestScopedElicitationHasNoSessionID() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let request = ElicitationFixtures.formRequest(scope: .request(ElicitationFixtures.requestScope))
            let span = try await Self.elicitationSpan(of: request, in: context)

            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == nil)
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(false))
            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.cancel))
        }
    }

    /// An elicitation of a mode that the client does not know goes to no
    /// model: `routed = false` and the `cancel` outcome.
    @Test("an elicitation of an unknown mode gives routed false")
    func anElicitationOfAnUnknownModeIsNotRouted() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let request = CreateElicitationRequest(
                message: ElicitationFixtures.formMessage,
                mode: .unknown("telepathy", .object([:]))
            )
            let span = try await Self.elicitationSpan(of: request, in: context)

            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(false))
            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.cancel))
        }
    }

    // MARK: - Elicitation complete

    /// An `elicitation/complete` that names an elicitation that a model holds
    /// gives the `matched` outcome.
    @Test("an elicitation complete that a model holds gives the matched outcome")
    func aHeldElicitationCompleteGivesMatched() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
            let harness = await TracedSessionHarness(elicitation: request)
            try await Self.runTurn(of: harness) { session in
                try await waitUntil { !session.pendingElicitations.isEmpty }
                try await harness.agentConnection.elicitationComplete(
                    CompleteElicitationNotification(elicitationId: ElicitationFixtures.urlID)
                )
            }

            let span = try await Self.completionSpan(in: context)
            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.matched))
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.routed) == .bool(true))
        }
    }

    /// An `elicitation/complete` that names no elicitation that a model holds
    /// gives the `unmatched` outcome.
    @Test("an elicitation complete that no model holds gives the unmatched outcome")
    func anUnheldElicitationCompleteGivesUnmatched() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let harness = await TracedSessionHarness()
            try await harness.initialize()
            try await harness.agentConnection.elicitationComplete(
                CompleteElicitationNotification(elicitationId: unknownElicitationID)
            )
            let span = try await Self.completionSpan(in: context)
            await harness.teardown()

            #expect(span.outcome == .string(ACPClientTelemetry.OutcomeValue.unmatched))
        }
    }

    // MARK: - Outcome mapping

    /// A permission outcome that this schema revision does not know gives
    /// `other`, never the string that the agent sent.
    @Test("an unknown permission outcome gives other")
    func anUnknownPermissionOutcomeGivesOther() {
        let outcome = RequestPermissionOutcome.unknown("revoked", .object([:]))

        #expect(ModelClient.permissionOutcome(of: outcome) == ACPClientTelemetry.OutcomeValue.other)
    }

    /// An elicitation response with an action that is not `accept`,
    /// `decline` or `cancel`, with no action, or that is not an object, gives
    /// `other`, never the string that the response holds.
    @Test(
        "an elicitation response with no known action gives other",
        arguments: [
            JSONValue.object([ElicitationResponseWire.actionKey: .string("postpone")]),
            JSONValue.object([:]),
            JSONValue.string(ElicitationResponseWire.acceptAction),
        ]
    )
    func anElicitationResponseWithNoKnownActionGivesOther(response: JSONValue) {
        #expect(ModelClient.elicitationOutcome(of: response) == ACPClientTelemetry.OutcomeValue.other)
    }

    // MARK: - Helpers

    /// Makes a harness whose stub asks for one permission when the prompt
    /// arrives, with the router of the model in front of the session models.
    ///
    /// - Parameter request: The permission request of the stub.
    /// - Returns: The harness.
    private static func permissionHarness(
        request: RequestPermissionRequest = SessionModelFixtures.permissionRequest()
    ) async -> TracedSessionHarness {
        await TracedSessionHarness(permissionRequest: request, permissionRoute: .model)
    }

    /// Sends `initialize`, runs one turn while `answer` answers the requests
    /// of the agent, and closes the connection.
    ///
    /// - Parameters:
    ///   - harness: The harness of the test.
    ///   - answer: Answers the requests of the agent through the session
    ///     model of the turn.
    /// - Throws: Whatever `initialize`, the turn or `answer` threw.
    private static func runTurn(
        of harness: TracedSessionHarness,
        answering answer: (SessionModel) async throws -> Void
    ) async throws {
        try await harness.initialize()
        let turn = try await harness.startTurn()
        try await answer(turn.session)
        try await turn.finish()
        await harness.teardown()
    }

    /// Waits until the session holds a pending permission request, and
    /// selects its allow option.
    ///
    /// - Parameter session: The session model of the turn.
    /// - Throws: `CancellationError` when the test time limit cancels the
    ///   wait.
    private static func selectThePermission(in session: SessionModel) async throws {
        try await waitUntil { !session.pendingPermissions.isEmpty }
        let pending = try #require(session.pendingPermissions.first)
        await session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)
    }

    /// Sends one elicitation from the agent with no session open, and gives
    /// the span of the elicitation.
    ///
    /// - Parameters:
    ///   - request: The elicitation that the agent sends.
    ///   - context: The capture of the test.
    /// - Returns: The span of the elicitation.
    /// - Throws: Whatever `initialize` or the elicitation threw, or an issue
    ///   when the elicitation gave no span.
    private static func elicitationSpan(
        of request: CreateElicitationRequest,
        in context: TelemetryCapture.Context
    ) async throws -> FinishedInMemorySpan {
        let harness = await TracedSessionHarness()
        try await harness.initialize()
        _ = try await harness.agentConnection.createElicitation(request)
        await harness.teardown()
        return try #require(context.agentRequestSpans(of: ClientRequestSpan.Method.createElicitation).first)
    }

    /// Waits until the span of the `elicitation/complete` notification ends,
    /// and gives it. The agent gets no answer to a notification, so the test
    /// waits for the span itself.
    ///
    /// - Parameter context: The capture of the test.
    /// - Returns: The span of the notification.
    /// - Throws: `CancellationError` when the test time limit cancels the
    ///   wait.
    private static func completionSpan(in context: TelemetryCapture.Context) async throws -> FinishedInMemorySpan {
        try await waitUntil { !context.agentRequestSpans(of: ClientRequestSpan.Method.completeElicitation).isEmpty }
        return try #require(context.agentRequestSpans(of: ClientRequestSpan.Method.completeElicitation).first)
    }
}

extension FinishedInMemorySpan {
    /// The value of the outcome attribute of the span, or `nil` when the span
    /// has none.
    fileprivate var outcome: SpanAttribute? {
        attributes.get(ACPClientTelemetry.AttributeKey.outcome)
    }
}
