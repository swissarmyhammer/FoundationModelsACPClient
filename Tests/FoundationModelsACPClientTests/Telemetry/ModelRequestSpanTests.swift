import FoundationModelsACP
import FoundationModelsExtras
import InMemoryTracing
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPClient

// These tests cover the telemetry of each request that `ConnectionModel` and
// `SessionModel` send: one client span, one request count and one duration
// for each request, the W3C `traceparent` of that span in the `_meta` of the
// request, the trace parent of `session/cancel`, and no content in the
// telemetry.
//
// Each test runs in a `TelemetryCapture`. The capture binds its tracer and its
// metrics factory as the task-local values, so the models use them through
// `InstrumentationSystem.tracer` and `MetricsSystem.factory`. The tests do not
// bootstrap the logging system: the capture does that one time for the
// process.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub records the `_meta` of each message that it gets, which
// is the value that crosses the process boundary.

/// The fixtures of the model request telemetry tests.
private enum ModelRequestFixtures {
    /// The text of the prompt of each test. Rule 4: no span, log record or
    /// metric holds it.
    static let promptText = "Model request prompt: describe the indigo kestrel."

    /// The text of the answer that the agent sends during each prompt. Rule 4:
    /// no span, log record or metric holds it.
    static let answerText = "Model request answer: the saffron bell rings twice."

    /// The content of the prompt of each test.
    static let promptContent: [ContentBlock] = [.text(TextContent(text: promptText))]

    /// The working directory of each session request.
    static let workingDirectory = AbsolutePath(rawValue: "/")

    /// The request that opens the test session.
    static let newSessionRequest = NewSessionRequest(cwd: workingDirectory)

    /// The request that resumes the test session, with no replay.
    static let resumeRequest = ResumeSessionRequest(cwd: workingDirectory, sessionId: testSession)

    /// The request that changes the mode of the test session.
    static let setModeRequest = SetSessionConfigOptionRequest(
        configId: SessionConfigId(rawValue: "mode"),
        sessionId: testSession,
        value: .id(SessionConfigValueId(rawValue: "careful"))
    )

    /// The one page of the session list: no session.
    static let emptySessionList: [SessionListCursor?: ListSessionsResponse] = [nil: ListSessionsResponse(sessions: [])]

    /// The name of the `_meta` member that a caller gives beside the trace
    /// context.
    static let vendorMemberName = "vendor.example/modelTag"

    /// The value of the `_meta` member that a caller gives beside the trace
    /// context.
    static let vendorMemberValue = "model-tag-3"

    /// The `_meta` that a caller gives: one vendor member and no trace
    /// context.
    static let vendorMeta = JSONValue.object([vendorMemberName: .string(vendorMemberValue)])

    /// Connects a model that applies each chunk at once to a stub agent that
    /// answers each request that a model sends.
    ///
    /// The agent advertises each optional session method and one auth method
    /// that goes to `auth/login`, so no request stops at a capability check.
    /// It sends the answer text during each prompt, and confirms each cancel
    /// with an idle update.
    ///
    /// - Returns: The connected model, before `initialize`.
    @MainActor
    static func connect() async -> ConnectedModel {
        await ConnectedModel(model: ConnectionModel(coalescingCadence: .zero)) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [agentChunk(text: answerText)],
                cancelScript: [idleState(stopReason: .cancelled)],
                closeSessionError: nil,
                resumeSessionError: nil,
                capabilities: InitializeFixtures.fullCapabilities,
                authMethods: [InitializeFixtures.agentMethod],
                sessionListPages: emptySessionList
            )
        }
    }

    /// Sends `session/cancel` for a session, and waits until the agent
    /// confirms the cancel with an idle update.
    ///
    /// The agent records the `_meta` of the cancel before it sends the idle
    /// update, so the record holds the cancel when this call returns.
    ///
    /// - Parameters:
    ///   - session: The model of the session.
    ///   - meta: The `_meta` that the caller gives, or `nil`.
    /// - Throws: The error of the cancel.
    @MainActor
    static func cancelAndWaitForIdle(_ session: SessionModel, meta: JSONValue? = nil) async throws {
        let updates = session.updateTap()
        try await session.cancel(meta: meta)
        for await case .stateUpdate(.idle(_)) in updates {
            return
        }
    }
}

/// One request that a model sends, and the calls that send it.
///
/// The type is internal and not private, because each parameterized test of
/// the suite takes it as an argument.
enum ModelRequest: CaseIterable, Sendable, CustomTestStringConvertible {
    /// `ConnectionModel.initialize(_:)`.
    case initialize

    /// `ConnectionModel.newSession(_:)`.
    case newSession

    /// `ConnectionModel.resumeSession(_:)`.
    case resumeSession

    /// `ConnectionModel.refreshSessions(cwd:)`.
    case listSessions

    /// `ConnectionModel.close(_:)`.
    case closeSession

    /// `ConnectionModel.deleteSession(_:)`.
    case deleteSession

    /// `ConnectionModel.login(_:)`.
    case login

    /// `ConnectionModel.logout(_:)`.
    case logout

    /// `SessionModel.prompt(_:meta:)`.
    case prompt

    /// `SessionModel.cancel(meta:)`.
    case cancel

    /// `SessionModel.setConfigOption(_:)`.
    case setConfigOption

    /// The ACP wire method of the request.
    var method: String {
        switch self {
        case .initialize: ClientRequestSpan.Method.initialize
        case .newSession: ClientRequestSpan.Method.newSession
        case .resumeSession: ClientRequestSpan.Method.resumeSession
        case .listSessions: ClientRequestSpan.Method.listSessions
        case .closeSession: ClientRequestSpan.Method.closeSession
        case .deleteSession: ClientRequestSpan.Method.deleteSession
        case .login: ClientRequestSpan.Method.login
        case .logout: ClientRequestSpan.Method.logout
        case .prompt: ClientRequestSpan.Method.prompt
        case .cancel: ClientRequestSpan.Method.cancelSession
        case .setConfigOption: ClientRequestSpan.Method.setConfigOption
        }
    }

    /// The name of the test case: the ACP wire method.
    var testDescription: String {
        method
    }

    /// Sends `initialize`, then the requests that open the state that this
    /// request needs, then this request, each one through the models.
    ///
    /// Each request of the sequence has a method of its own, so the request
    /// of this case is the one request of its method.
    ///
    /// - Parameter connected: The connected model.
    /// - Throws: The error of a request.
    @MainActor
    func send(over connected: ConnectedModel) async throws {
        let model = connected.model
        try await connected.initialize()
        switch self {
        case .initialize:
            break
        case .newSession:
            _ = try await model.newSession(ModelRequestFixtures.newSessionRequest)
        case .resumeSession:
            _ = try await model.resumeSession(ModelRequestFixtures.resumeRequest)
        case .listSessions:
            try await model.refreshSessions()
        case .closeSession:
            try await model.close(model.newSession(ModelRequestFixtures.newSessionRequest))
        case .deleteSession:
            try await model.deleteSession(testSession)
        case .login:
            try await model.login(InitializeFixtures.login)
        case .logout:
            try await model.logout(LogoutAuthRequest())
        case .prompt:
            _ = try await model.newSession(ModelRequestFixtures.newSessionRequest)
                .prompt(ModelRequestFixtures.promptContent)
        case .cancel:
            try await ModelRequestFixtures.cancelAndWaitForIdle(
                model.newSession(ModelRequestFixtures.newSessionRequest)
            )
        case .setConfigOption:
            try await model.newSession(ModelRequestFixtures.newSessionRequest)
                .setConfigOption(ModelRequestFixtures.setModeRequest)
        }
    }
}

/// The telemetry tests of the requests of the models, in one suite so that
/// `swift test --filter ModelRequestSpanTests` selects them. A wait for an
/// update that never comes would suspend for ever, so the suite has a time
/// limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ModelRequestSpanTests {
    /// Each request of the models gives exactly one finished span of kind
    /// `.client`, with the request span name and the method attribute.
    @Test(arguments: ModelRequest.allCases)
    func eachModelRequestGivesOneClientSpan(request: ModelRequest) async throws {
        try await TelemetryCapture.run(forbidding: [ModelRequestFixtures.promptText]) { context in
            let connected = await ModelRequestFixtures.connect()
            try await request.send(over: connected)

            let spans = context.requestSpans(of: request.method)
            #expect(spans.count == 1, "\(request.method) gave \(spans.count) spans.")
            #expect(spans.first?.kind == .client, "The span of \(request.method) is not of kind client.")
        }
    }

    /// Each request of the models records one request count and one
    /// duration, with the method as the dimension.
    @Test(arguments: ModelRequest.allCases)
    func eachModelRequestRecordsOneCountAndOneDuration(request: ModelRequest) async throws {
        try await TelemetryCapture.run(forbidding: [ModelRequestFixtures.promptText]) { context in
            let connected = await ModelRequestFixtures.connect()
            try await request.send(over: connected)

            let dimensions = [RequestTelemetry.methodDimension(request.method)]
            let requests = try context.metricsFactory.expectCounter(ACPClientTelemetry.MetricName.requests, dimensions)
            let durations = try context.metricsFactory.expectTimer(ACPClientTelemetry.MetricName.requestDuration, dimensions)
            #expect(requests.totalValue == 1)
            #expect(durations.values.count == 1)
        }
    }

    /// The `_meta` that the agent gets for each request of the models holds
    /// a `traceparent` with the trace id and the span id of the span of that
    /// request.
    @Test(arguments: ModelRequest.allCases)
    func theAgentGetsTheTraceparentOfEachModelRequestSpan(request: ModelRequest) async throws {
        try await TelemetryCapture.run(forbidding: [ModelRequestFixtures.promptText]) { context in
            let connected = await ModelRequestFixtures.connect()
            try await request.send(over: connected)

            let span = try #require(context.requestSpans(of: request.method).first)
            let meta = try #require(connected.receivedMeta(of: request.method).first, "The agent got no \(request.method).")
            let identity = try RequestTelemetry.traceparentIdentity(in: meta)
            #expect(identity.traceID == span.traceID, "The traceparent of \(request.method) names another trace.")
            #expect(identity.spanID == span.spanID, "The traceparent of \(request.method) names another span.")
        }
    }

    /// The models keep each member of the `_meta` that the caller gives, and
    /// add the trace context of the request span to it.
    @Test func aModelRequestKeepsTheMetaOfTheCallerAndAddsTheTraceContext() async throws {
        try await TelemetryCapture.run(forbidding: [ModelRequestFixtures.promptText]) { context in
            let connected = await ModelRequestFixtures.connect()
            try await connected.initialize()
            let session = try await connected.model.newSession(ModelRequestFixtures.newSessionRequest)
            _ = try await session.prompt(ModelRequestFixtures.promptContent, meta: ModelRequestFixtures.vendorMeta)

            let span = try #require(context.requestSpans(of: ClientRequestSpan.Method.prompt).first)
            let identity = try #require(SpanIdentity(traceID: span.traceID, spanID: span.spanID))
            let meta = try #require(connected.receivedMeta(of: ClientRequestSpan.Method.prompt).first)
            #expect(
                meta == .object([
                    ModelRequestFixtures.vendorMemberName: .string(ModelRequestFixtures.vendorMemberValue),
                    SpanIdentity.traceparentField: .string(identity.traceparent),
                ])
            )
        }
    }

    /// A `session/cancel` whose `_meta` holds the `traceparent` of the
    /// prompt span is a child of that prompt span, in the trace of the
    /// prompt. The agent gets the `traceparent` of the cancel span.
    @Test func aCancelWithThePromptTraceparentIsAChildOfThePromptSpan() async throws {
        try await TelemetryCapture.run(forbidding: [ModelRequestFixtures.promptText]) { context in
            let connected = await ModelRequestFixtures.connect()
            try await connected.initialize()
            let session = try await connected.model.newSession(ModelRequestFixtures.newSessionRequest)
            _ = try await session.prompt(ModelRequestFixtures.promptContent)
            let promptMeta = try #require(connected.receivedMeta(of: ClientRequestSpan.Method.prompt).first)

            try await ModelRequestFixtures.cancelAndWaitForIdle(session, meta: promptMeta)

            let promptSpan = try #require(context.requestSpans(of: ClientRequestSpan.Method.prompt).first)
            let cancelSpan = try #require(context.requestSpans(of: ClientRequestSpan.Method.cancelSession).first)
            let cancelMeta = try #require(connected.receivedMeta(of: ClientRequestSpan.Method.cancelSession).first)
            let identity = try RequestTelemetry.traceparentIdentity(in: cancelMeta)
            #expect(cancelSpan.traceID == promptSpan.traceID)
            #expect(cancelSpan.parentSpanID == promptSpan.spanID)
            #expect(identity.spanID == cancelSpan.spanID)
        }
    }

    /// No span, log record or metric of each request of the models holds the
    /// prompt or the answer of the turn.
    @Test func theModelRequestsPutNoContentIntoTelemetry() async throws {
        let content = [ModelRequestFixtures.promptText, ModelRequestFixtures.answerText]
        try await TelemetryCapture.run(forbidding: content) { context in
            for request in ModelRequest.allCases {
                let connected = await ModelRequestFixtures.connect()
                try await request.send(over: connected)
            }

            context.expectEachSignal()
        }
    }
}
