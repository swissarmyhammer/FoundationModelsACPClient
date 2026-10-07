import Foundation
import FoundationModelsACP
import Testing

@testable import AcpClientCore
@testable import FoundationModelsACPClient

// The tests of the order guarantee of `SessionModel.selectPermission(_:option:)`
// and `SessionModel.cancelPermission(_:)`: each call returns only after the
// connection wrote the permission response to the transport, or after the
// connection discarded that response. Thus a request that the caller sends
// after the call goes on the wire after the response.
//
// `InMemoryTransport.pair()` gives the real ACP wire, with a
// `ScriptedStubAgent` on the agent end. A `FrameTeeTransport` wraps the agent
// end. Its forwarding task reads the frames of the client in wire order, and
// it records each frame before the agent reads it. A record in the handlers of
// the agent would race: the agent handles the permission response and the
// prompt on different tasks.

/// The kind of one frame that the client wrote, for the frames that these
/// tests put in order.
private enum ClientFrame: Equatable {
    /// The response to a `session/request_permission` request.
    case permissionResponse

    /// A `session/prompt` request.
    case prompt

    /// Classifies one line that the client wrote.
    ///
    /// - Parameter line: The text of the line, with no direction mark.
    /// - Returns: The kind of the frame, or `nil` for a frame of another
    ///   kind.
    init?(line: Substring) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        if object["method"] as? String == ClientRequestSpan.Method.prompt {
            self = .prompt
        } else if let result = object["result"] as? [String: Any], result["outcome"] != nil {
            self = .permissionResponse
        } else {
            return nil
        }
    }
}

/// A connection model with one open session over an in-memory pair, whose
/// agent end records each frame that the client wrote.
@MainActor
private struct RecordedSession {
    /// The model under test.
    let model: ConnectionModel

    /// The open session of the stub agent.
    let session: SessionModel

    /// The agent-side connection. Each test sends its permission requests
    /// through it.
    let agentConnection: AgentSideConnection

    /// Each line that crossed the agent end, with its direction mark.
    private let lines: ThreadSafeBuffer<String>

    /// The permission responses and the prompts that the client wrote, in
    /// wire order.
    var clientFrames: [ClientFrame] {
        lines.elements.compactMap { line in
            guard line.hasPrefix(FrameTeeTransport.inboundMark) else { return nil }
            return ClientFrame(line: line.dropFirst(FrameTeeTransport.inboundMark.count))
        }
    }

    /// Connects a new model to a new stub agent, sends `initialize`, and
    /// opens the session of the stub agent.
    ///
    /// - Throws: The error of the `initialize` or of the `session/new`.
    init() async throws {
        let lines = ThreadSafeBuffer<String>()
        self.lines = lines
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let recordedAgentEnd = FrameTeeTransport(wrapping: agentEnd) { lines.append($0) }
        agentConnection = await AgentSideConnection(stream: recordedAgentEnd) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
        model = ConnectionModel()
        _ = await model.connect(over: clientEnd)
        _ = try await model.initialize(makeInitializeRequest())
        session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
    }

    /// Sends a permission request from the agent, and waits until the
    /// session holds it as pending.
    ///
    /// - Returns: The task of the agent's call, and the pending request.
    /// - Throws: `CancellationError` when the test time limit cancels the
    ///   wait.
    func startPermission() async throws -> (Task<RequestPermissionResponse, any Error>, PendingPermissionRequest) {
        let request = SessionModelFixtures.permissionRequest()
        let call = Task { [agentConnection] in
            try await agentConnection.requestPermission(request)
        }
        try await waitUntil { !session.pendingPermissions.isEmpty }
        return (call, try #require(session.pendingPermissions.first))
    }
}

/// A `Client` in front of the router of a connection model that closes the
/// connection after the router answers a permission request.
///
/// The close comes before the handler returns, so the connection discards
/// the response and never writes it.
@MainActor
private final class ClosingClient: Client {
    /// The router that this client stands in front of.
    private let router: any Client

    /// The model whose connection this client closes.
    private weak var model: ConnectionModel?

    /// Whether this client closed the connection.
    private(set) var didCloseTheConnection = false

    /// Makes the client.
    ///
    /// - Parameters:
    ///   - router: The router that this client stands in front of.
    ///   - model: The model whose connection this client closes.
    init(router: any Client, model: ConnectionModel) {
        self.router = router
        self.model = model
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await router.sessionUpdate(notification)
    }

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        let response = try await router.requestPermission(params)
        await model?.connection?.close()
        didCloseTheConnection = true
        return response
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        try await router.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await router.elicitationComplete(notification)
    }
}

/// Builds the ``ClosingClient`` of a connection, and keeps it, so a test can
/// read what it did.
@MainActor
private final class ClosingClientFactory {
    /// The client that ``wrap(_:)`` built, or `nil` before the connection.
    private(set) var built: ClosingClient?

    /// The model whose connection the client closes. The test sets it before
    /// the connection.
    weak var model: ConnectionModel?

    /// Builds the closing client in front of a router.
    ///
    /// - Parameter router: The router of the connection model.
    /// - Returns: The client that the connection serves.
    func wrap(_ router: any Client) -> any Client {
        guard let model else { return router }
        let client = ClosingClient(router: router, model: model)
        built = client
        return client
    }
}

/// Keeps each "written" signal that a permission decision registers, and
/// never gives one, so a caller that waits for the signal stays suspended
/// until something else ends the wait.
@MainActor
private final class HeldSignals {
    /// The signals that the decisions registered, in registration order.
    private var signals: [@Sendable () -> Void] = []

    /// The number of signals that the decisions registered.
    var count: Int {
        signals.count
    }

    /// Keeps one signal.
    ///
    /// - Parameter signal: The signal that a decision registered.
    func keep(_ signal: @escaping @Sendable () -> Void) {
        signals.append(signal)
    }
}

/// The order tests, in one suite so that `swift test --filter
/// PermissionReplyOrderTests` selects them. A wait that never ends would
/// suspend for ever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PermissionReplyOrderTests {
    /// The number of permission rounds that each order test runs.
    private static let roundCount = 100

    /// The id of the option that the user selects.
    private let allowOptionId = SessionModelFixtures.allowOption.optionId

    @Test func selectPermissionResponseIsWrittenBeforeTheNextPrompt() async throws {
        try await expectEachResponseBeforeTheNextPrompt { session, id in
            await session.selectPermission(id, option: allowOptionId)
        }
    }

    @Test func cancelPermissionResponseIsWrittenBeforeTheNextPrompt() async throws {
        try await expectEachResponseBeforeTheNextPrompt { session, id in
            await session.cancelPermission(id)
        }
    }

    @Test func selectPermissionReturnsWhenTheConnectionClosesFirst() async throws {
        let factory = ClosingClientFactory()
        let model = ConnectionModel()
        factory.model = model
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
        _ = await model.connect(over: clientEnd) { [factory] router in factory.wrap(router) }
        let session = model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        model.register(session)
        let request = SessionModelFixtures.permissionRequest()
        let call = Task { try await agentConnection.requestPermission(request) }
        try await waitUntil { !session.pendingPermissions.isEmpty }
        let pending = try #require(session.pendingPermissions.first)

        await session.selectPermission(pending.id, option: allowOptionId)

        // The call returns only after the handler returned, so the client
        // closed the connection first, and the connection discarded the
        // response.
        #expect(try #require(factory.built).didCloseTheConnection)
        call.cancel()
    }

    @Test func selectPermissionReturnsWhenTheSessionCloses() async throws {
        let session = SessionModelFixtures.immediateModel()
        let held = HeldSignals()
        let decision = Task {
            await session.awaitPermissionDecision(for: SessionModelFixtures.permissionRequest()) { held.keep($0) }
        }
        try await waitUntil { !session.pendingPermissions.isEmpty }
        let pending = try #require(session.pendingPermissions.first)
        // A child task, so the time limit of the suite cancels a select that
        // never returns.
        async let selected: Void = session.selectPermission(pending.id, option: allowOptionId)
        // The decision registered its signal and never gives it, so the
        // select waits.
        try await waitUntil { held.count == 1 }

        session.markClosed()

        await selected
        #expect(await decision.value.outcome == .selected(SelectedPermissionOutcome(optionId: allowOptionId)))
    }

    @Test func selectPermissionWithAnUnknownIdReturnsAtOnce() async throws {
        let recorded = try await RecordedSession()
        let (call, pending) = try await recorded.startPermission()

        await recorded.session.selectPermission(UUID(), option: allowOptionId)

        #expect(recorded.session.pendingPermissions.map(\.id) == [pending.id])
        await recorded.session.cancelPermission(pending.id)
        #expect(try await call.value.outcome == .cancelled)
    }

    /// Runs ``roundCount`` permission rounds. Each round resolves the request
    /// of the agent, then sends a prompt, and the test expects the response
    /// of each round on the wire before the prompt of that round.
    ///
    /// - Parameter resolve: Resolves one pending request of the session.
    /// - Throws: The error of a request, or `CancellationError` when the test
    ///   time limit cancels a wait.
    private func expectEachResponseBeforeTheNextPrompt(
        resolve: (SessionModel, PendingPermissionRequest.ID) async -> Void
    ) async throws {
        let recorded = try await RecordedSession()
        for _ in 0..<Self.roundCount {
            let (call, pending) = try await recorded.startPermission()
            await resolve(recorded.session, pending.id)
            _ = try await recorded.session.prompt([textBlock("Go on.")])
            _ = try await call.value
        }
        let oneRound: [ClientFrame] = [.permissionResponse, .prompt]
        #expect(recorded.clientFrames == Array(repeating: oneRound, count: Self.roundCount).flatMap(\.self))
    }
}
