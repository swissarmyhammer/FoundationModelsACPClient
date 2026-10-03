import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

/// A stub agent that sends a fixed update script during one prompt turn.
///
/// The connection read loop applies each notification in wire order before
/// it delivers the prompt acknowledgement, so a test can assert on the final
/// observable state after the prompt call returns.
///
/// The stub answers `session/new` with the session the script belongs to,
/// because a test that drives the whole turn path opens a session before it
/// prompts. The answer carries the `newSessionCommands` the test chose, and
/// the stub sends the `newSessionScript` before the answer, so a test can
/// prove that an update which comes before the session id is not lost.
///
/// `session/resume` sends the `resumeSessionScript` as the replay, and then
/// refuses with the error the test chose, or answers with the
/// `resumeSessionCommands` when the test chose no error. The default is the
/// `methodNotFound` refusal of an agent that does not implement the method.
/// A stub built with a resume gate holds the answer, after the replay, until
/// the test opens that gate.
///
/// Every other session method stays unanswered: no test needs one, and a
/// stub that answers a method it does not model would hide a mistake.
///
/// `session/cancel` sends the `cancelScript` the test chose. The default is no
/// script at all, which is the agent that IGNORES a cancellation; a test that
/// drives the `cli-plan.md` §11 interrupt gives it an `idle` update carrying
/// the `cancelled` stop reason, which is how the schema confirms a
/// cancellation.
///
/// `session/close` refuses with the error the test chose, or accepts the
/// close when the test chose no error. The default is the `methodNotFound`
/// refusal an agent that does not implement the optional method sends, and a
/// test that drives the other branch of `AgentSession.closeSession(_:)` asks
/// for an error with another code.
///
/// `session/set_config_option` accepts each request with no option, so a
/// test can prove that the request reached the agent.
///
/// A stub built with an elicitation asks the client for that elicitation
/// before it sends the script. The prompt turn then ends only after the
/// client answered, which is how a test proves that a headless client
/// refuses at once rather than waiting for a person. A stub built with a
/// permission request asks for that permission first, in the same way.
///
/// A stub built with a prompt error refuses each prompt with that error, and
/// sends no update. `ContentSafetyTests` uses it to prove that the message
/// text of a refusal does not go into telemetry.
///
/// The stub records the working directory of each `session/new` it answered,
/// because `--cwd` is the session's working directory and the wire request is
/// the only place that value is observable. `AgentSessionTests` reads
/// ``lastWorkingDirectory`` to assert the path the binary resolved.
///
/// The stub also records the `_meta` of each request and notification that it
/// gets, because the `_meta` is where the W3C trace context of the client
/// crosses the process boundary. `ClientRequestSpanTests` reads
/// ``receivedMeta`` to find the `traceparent` that the agent got.
///
/// The stub answers `initialize` with the capabilities and the auth methods
/// that the test chose. The default is no capability and no auth method.
/// `auth/login` succeeds, or refuses with the error that the test chose.
/// `auth/logout` always succeeds. `ConnectionModelInitializeTests` uses these
/// three to drive the capability flags and the auth state of
/// ``ConnectionModel``.
///
/// A stub built with a login gate holds each `auth/login` until the test
/// opens that gate, so the login request stays in flight.
/// `ConnectionModelElicitationTests` sends a request-scoped elicitation while
/// the login waits, and then opens the gate to finish the request.
///
/// A stub built with a new-session gate holds each `session/new` until the
/// test opens that gate, in the same way. `ConnectionModelSessionTests` holds
/// the answer so that it can close the connection between the answer and the
/// moment the model reads it.
///
/// `session/list` answers with the page that the test keyed by the cursor of
/// the request, and refuses a cursor with no page with `invalidParams`. A
/// stub built with a gate for a cursor holds the answer of that page until
/// the test opens the gate. `session/delete` accepts each delete. The stub
/// records each list request and each delete request, so
/// `ConnectionModelListTests` can assert on their order and their
/// parameters.
///
/// The `script` goes out BEFORE the prompt answer, which is the order a test
/// wants when it asserts on landed state after the prompt call returned. That
/// order cannot tell a client that ends its turn on the prompt answer from
/// one that ends it on `idle`, because the answer is last either way. The
/// `deferredScript` is the other order: each of its steps goes out after the
/// answer, when the test opens that step's gate. `TurnRunnerTests` uses it to
/// prove that the turn outlives the acknowledgement.
final class ScriptedStubAgent: Agent {
    /// The ACP wire method of the set-config-option request, as the stub
    /// records it.
    static let setConfigOptionMethod = "session/set_config_option"

    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The session that the script belongs to.
    private let session: SessionId

    /// The working directory of each `session/new` this stub answered, in
    /// arrival order.
    ///
    /// The connection serves `session/new` on a task of its own, so the
    /// record must tolerate a write from a thread other than the test body's.
    private let workingDirectories = ThreadSafeBuffer<AbsolutePath>()

    /// The working directory of the last `session/new` this stub answered, or
    /// `nil` when it answered none.
    var lastWorkingDirectory: AbsolutePath? {
        workingDirectories.elements.last
    }

    /// The `_meta` of each request and notification this stub got, in
    /// arrival order.
    ///
    /// The connection serves each message on a task of its own, so the record
    /// must tolerate a write from a thread other than the test body's.
    private let receivedMetaRecord = ThreadSafeBuffer<ReceivedMeta>()

    /// The `_meta` of each request and notification this stub got, in
    /// arrival order.
    var receivedMeta: [ReceivedMeta] {
        receivedMetaRecord.elements
    }

    /// The updates to send, in order, when a prompt arrives.
    private let script: [SessionUpdate]

    /// The elicitation to ask for when a prompt arrives, or `nil` to ask
    /// for none.
    private let elicitation: CreateElicitationRequest?

    /// The permission request to send when a prompt arrives, or `nil` to
    /// send none.
    private let permissionRequest: RequestPermissionRequest?

    /// The error to refuse each prompt with, or `nil` to answer each prompt.
    private let promptError: RequestError?

    /// The error this stub answers `session/close` with, or `nil` to accept
    /// each close.
    private let closeSessionError: RequestError?

    /// The updates to send, in order, before the `session/new` answer.
    private let newSessionScript: [SessionUpdate]

    /// The command list of the `session/new` answer, or `nil` to leave the
    /// member out.
    private let newSessionCommands: [AvailableCommand]?

    /// The updates to send, in order, as the replay of a `session/resume`,
    /// before its answer.
    private let resumeSessionScript: [SessionUpdate]

    /// The command list of the `session/resume` answer, or `nil` to leave
    /// the member out.
    private let resumeSessionCommands: [AvailableCommand]?

    /// The error this stub answers `session/resume` with, or `nil` to
    /// accept each resume.
    private let resumeSessionError: RequestError?

    /// The gate that must open before each `session/resume` answers, or
    /// `nil` to answer each resume at once.
    private let resumeSessionGate: UpdateGate?

    /// The updates to send after the prompt answer, one step per gate.
    private let deferredScript: [GatedUpdates]

    /// The updates to send when `session/cancel` arrives, in order.
    ///
    /// An empty script is the agent that IGNORES a cancellation, which is a
    /// conformant thing for an agent to be: `session/cancel` is a
    /// notification, and the schema confirms a cancellation with an `idle`
    /// `state_update` that this agent is free never to send.
    private let cancelScript: [SessionUpdate]

    /// The capabilities this stub answers `initialize` with.
    private let capabilities: AgentCapabilities

    /// The auth methods this stub answers `initialize` with, or `nil` to
    /// leave the member out.
    private let authMethods: [AuthMethod]?

    /// The error to refuse each `auth/login` with, or `nil` to accept each
    /// login.
    private let loginError: RequestError?

    /// The gate that must open before each `auth/login` answers, or `nil` to
    /// answer each login at once.
    private let loginGate: UpdateGate?

    /// The gate that must open before each `session/new` answers, or `nil`
    /// to answer each new session at once.
    private let newSessionGate: UpdateGate?

    /// The page that `session/list` answers, keyed by the cursor of the
    /// request. The `nil` key is the first page.
    private let sessionListPages: [SessionListCursor?: ListSessionsResponse]

    /// The gate that must open before the page of a cursor answers, keyed by
    /// that cursor. A cursor with no gate answers at once.
    private let sessionListGates: [SessionListCursor?: UpdateGate]

    /// Each `session/list` request this stub got, in arrival order.
    ///
    /// The connection serves each request on a task of its own, so the record
    /// must tolerate a write from a thread other than the test body's.
    private let listRequestRecord = ThreadSafeBuffer<ListSessionsRequest>()

    /// Each `session/list` request this stub got, in arrival order.
    var listRequests: [ListSessionsRequest] {
        listRequestRecord.elements
    }

    /// Each `session/delete` request this stub got, in arrival order.
    private let deleteRequestRecord = ThreadSafeBuffer<DeleteSessionRequest>()

    /// Each `session/delete` request this stub got, in arrival order.
    var deleteRequests: [DeleteSessionRequest] {
        deleteRequestRecord.elements
    }

    /// Creates the stub.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - session: The session that the script belongs to.
    ///   - script: The updates to send during the prompt turn, before the
    ///     prompt answer.
    ///   - deferredScript: The updates to send after the prompt answer, one
    ///     step per gate, in order.
    ///   - cancelScript: The updates to send when `session/cancel` arrives.
    ///     The default is none, which is the agent that ignores a
    ///     cancellation.
    ///   - elicitation: The elicitation to ask for at the start of the
    ///     prompt turn, or `nil` to ask for none.
    ///   - permissionRequest: The permission to ask for at the start of the
    ///     prompt turn, before the elicitation, or `nil` to ask for none.
    ///   - promptError: The error to refuse each prompt with, or `nil` to
    ///     answer each prompt.
    ///   - closeSessionError: The error to answer `session/close` with, or
    ///     `nil` to accept each close.
    ///   - newSessionScript: The updates to send before the `session/new`
    ///     answer.
    ///   - newSessionCommands: The command list of the `session/new` answer,
    ///     or `nil` to leave the member out.
    ///   - resumeSessionScript: The updates to send as the replay of a
    ///     `session/resume`, before its answer.
    ///   - resumeSessionCommands: The command list of the `session/resume`
    ///     answer, or `nil` to leave the member out.
    ///   - resumeSessionError: The error to answer `session/resume` with, or
    ///     `nil` to accept each resume.
    ///   - resumeSessionGate: The gate that must open before each
    ///     `session/resume` answers, or `nil` to answer each resume at once.
    ///   - capabilities: The capabilities to answer `initialize` with.
    ///   - authMethods: The auth methods to answer `initialize` with, or
    ///     `nil` to leave the member out.
    ///   - loginError: The error to refuse each `auth/login` with, or `nil`
    ///     to accept each login.
    ///   - loginGate: The gate that must open before each `auth/login`
    ///     answers, or `nil` to answer each login at once.
    ///   - newSessionGate: The gate that must open before each `session/new`
    ///     answers, or `nil` to answer each new session at once.
    ///   - sessionListPages: The page that `session/list` answers, keyed by
    ///     the cursor of the request; the `nil` key is the first page.
    ///   - sessionListGates: The gate that must open before the page of a
    ///     cursor answers, keyed by that cursor.
    init(
        connection: AgentSideConnection,
        session: SessionId,
        script: [SessionUpdate],
        deferredScript: [GatedUpdates] = [],
        cancelScript: [SessionUpdate] = [],
        elicitation: CreateElicitationRequest? = nil,
        permissionRequest: RequestPermissionRequest? = nil,
        promptError: RequestError? = nil,
        closeSessionError: RequestError? = .methodNotFound("session/close"),
        newSessionScript: [SessionUpdate] = [],
        newSessionCommands: [AvailableCommand]? = nil,
        resumeSessionScript: [SessionUpdate] = [],
        resumeSessionCommands: [AvailableCommand]? = nil,
        resumeSessionError: RequestError? = .methodNotFound(ClientRequestSpan.Method.resumeSession),
        resumeSessionGate: UpdateGate? = nil,
        capabilities: AgentCapabilities = AgentCapabilities(),
        authMethods: [AuthMethod]? = nil,
        loginError: RequestError? = nil,
        loginGate: UpdateGate? = nil,
        newSessionGate: UpdateGate? = nil,
        sessionListPages: [SessionListCursor?: ListSessionsResponse] = [:],
        sessionListGates: [SessionListCursor?: UpdateGate] = [:]
    ) {
        self.connection = connection
        self.session = session
        self.script = script
        self.deferredScript = deferredScript
        self.cancelScript = cancelScript
        self.elicitation = elicitation
        self.permissionRequest = permissionRequest
        self.promptError = promptError
        self.closeSessionError = closeSessionError
        self.newSessionScript = newSessionScript
        self.newSessionCommands = newSessionCommands
        self.resumeSessionScript = resumeSessionScript
        self.resumeSessionCommands = resumeSessionCommands
        self.resumeSessionError = resumeSessionError
        self.resumeSessionGate = resumeSessionGate
        self.capabilities = capabilities
        self.authMethods = authMethods
        self.loginError = loginError
        self.loginGate = loginGate
        self.newSessionGate = newSessionGate
        self.sessionListPages = sessionListPages
        self.sessionListGates = sessionListGates
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        record(params.meta, of: ClientRequestSpan.Method.initialize)
        return InitializeResponse(
            info: Implementation(name: "stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion,
            authMethods: authMethods,
            capabilities: capabilities
        )
    }

    func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
        record(params.meta, of: ConnectionModel.WireMethod.login)
        await loginGate?.wait()
        if let loginError {
            throw loginError
        }
        return LoginAuthResponse()
    }

    func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
        record(params.meta, of: ConnectionModel.WireMethod.logout)
        return LogoutAuthResponse()
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        record(params.meta, of: ClientRequestSpan.Method.newSession)
        workingDirectories.append(params.cwd)
        await newSessionGate?.wait()
        for update in newSessionScript {
            try await send(update)
        }
        return NewSessionResponse(sessionId: session, availableCommands: newSessionCommands)
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        record(params.meta, of: ConnectionModel.WireMethod.listSessions)
        listRequestRecord.append(params)
        await sessionListGates[params.cursor]?.wait()
        guard let page = sessionListPages[params.cursor] else {
            throw RequestError.invalidParams
        }
        return page
    }

    func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        record(params.meta, of: ConnectionModel.WireMethod.deleteSession)
        deleteRequestRecord.append(params)
        return DeleteSessionResponse()
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        record(params.meta, of: ClientRequestSpan.Method.resumeSession)
        for update in resumeSessionScript {
            try await send(update)
        }
        await resumeSessionGate?.wait()
        if let resumeSessionError {
            throw resumeSessionError
        }
        return ResumeSessionResponse(availableCommands: resumeSessionCommands)
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        record(params.meta, of: ClientRequestSpan.Method.closeSession)
        if let closeSessionError {
            throw closeSessionError
        }
        return CloseSessionResponse()
    }

    func setSessionConfigOption(_ params: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
        record(params.meta, of: Self.setConfigOptionMethod)
        return SetSessionConfigOptionResponse(configOptions: [])
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        record(params.meta, of: ClientRequestSpan.Method.prompt)
        if let promptError {
            throw promptError
        }
        if let permissionRequest {
            _ = try await connection.requestPermission(permissionRequest)
        }
        if let elicitation {
            _ = try await connection.createElicitation(elicitation)
        }
        for update in script {
            try await send(update)
        }
        startDeferredScript()
        return testPromptResponse
    }

    func sessionCancel(_ params: CancelSessionNotification) async {
        record(params.meta, of: ClientRequestSpan.Method.cancelSession)
        for update in cancelScript {
            // A notification has no answer that could carry a failure, and a
            // client that tore its connection down right after it cancelled is
            // a shape `cli-plan.md` §11 allows. Neither is a reason to trap.
            try? await send(update)
        }
    }

    /// Records the `_meta` of one request or notification that this stub got.
    ///
    /// - Parameters:
    ///   - meta: The `_meta` of the message, or `nil` when it has none.
    ///   - method: The ACP method of the message.
    private func record(_ meta: JSONValue?, of method: String) {
        receivedMetaRecord.append(ReceivedMeta(method: method, meta: meta))
    }

    /// Sends one update for this stub's session.
    ///
    /// - Parameter update: The update to send.
    /// - Throws: Whatever the connection threw.
    private func send(_ update: SessionUpdate) async throws {
        try await connection.sessionUpdate(
            UpdateSessionNotification(sessionId: session, update: update)
        )
    }

    /// Starts the task that sends ``deferredScript``, one step per gate.
    ///
    /// The task is unstructured on purpose. The whole point of the deferred
    /// script is that the agent ANSWERS the prompt while the turn is still
    /// running, so the sending has to outlive `prompt(_:)`, and a structured
    /// child of `prompt(_:)` could not. An empty script ends the task at
    /// once.
    private func startDeferredScript() {
        let steps = deferredScript
        Task { [self] in
            for step in steps {
                await step.gate.wait()
                for update in step.updates {
                    do {
                        try await send(update)
                    } catch {
                        // The test tore the connection down before it opened
                        // this gate, so the rest of the script has nowhere
                        // left to go.
                        return
                    }
                }
            }
        }
    }
}

/// The `_meta` of one request or notification that a ``ScriptedStubAgent``
/// got.
struct ReceivedMeta: Sendable {
    /// The ACP method of the message, for example `session/prompt`.
    let method: String

    /// The `_meta` of the message, or `nil` when it has none.
    let meta: JSONValue?
}

/// A one-way gate that a test opens to release a stub agent's next updates.
///
/// A test that wants an update to arrive at a chosen moment cannot race it:
/// it holds the gate closed, asserts what it needs to assert, and then opens
/// the gate. A gate opens one time and stays open.
final class UpdateGate: Sendable {
    /// The stream whose end is the opening of the gate.
    ///
    /// Nothing is ever yielded into it. The waiting side asks for one element
    /// and is resumed when ``open()`` finishes the stream.
    private let stream: AsyncStream<Void>

    /// The continuation that opens the gate.
    private let continuation: AsyncStream<Void>.Continuation

    /// Builds a closed gate.
    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Opens the gate, and lets the waiting side through.
    func open() {
        continuation.finish()
    }

    /// Waits until the gate opens.
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// One step of a ``ScriptedStubAgent`` deferred script: the updates to send,
/// and the gate that releases them.
struct GatedUpdates: Sendable {
    /// The gate that must open before the updates go out.
    let gate: UpdateGate

    /// The updates to send once the gate opens, in order.
    let updates: [SessionUpdate]
}
