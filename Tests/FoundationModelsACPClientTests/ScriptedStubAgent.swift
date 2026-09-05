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
/// prompts. Every other session method stays unanswered: no test needs one,
/// and a stub that answers a method it does not model would hide a mistake.
///
/// `session/cancel` sends the `cancelScript` the test chose. The default is no
/// script at all, which is the agent that IGNORES a cancellation; a test that
/// drives the `cli-plan.md` §11 interrupt gives it an `idle` update carrying
/// the `cancelled` stop reason, which is how the schema confirms a
/// cancellation.
///
/// `session/close` refuses with the error the test chose. The default is the
/// `methodNotFound` refusal an agent that does not implement the optional
/// method sends, and a test that drives the other branch of
/// `AgentSession.closeSession(_:)` asks for an error with another code.
///
/// A stub built with an elicitation asks the client for that elicitation
/// before it sends the script. The prompt turn then ends only after the
/// client answered, which is how a test proves that a headless client
/// refuses at once rather than waiting for a person.
///
/// The stub records the working directory of each `session/new` it answered,
/// because `--cwd` is the session's working directory and the wire request is
/// the only place that value is observable. `AgentSessionTests` reads
/// ``lastWorkingDirectory`` to assert the path the binary resolved.
///
/// The `script` goes out BEFORE the prompt answer, which is the order a test
/// wants when it asserts on landed state after the prompt call returned. That
/// order cannot tell a client that ends its turn on the prompt answer from
/// one that ends it on `idle`, because the answer is last either way. The
/// `deferredScript` is the other order: each of its steps goes out after the
/// answer, when the test opens that step's gate. `TurnRunnerTests` uses it to
/// prove that the turn outlives the acknowledgement.
final class ScriptedStubAgent: Agent {
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

    /// The updates to send, in order, when a prompt arrives.
    private let script: [SessionUpdate]

    /// The elicitation to ask for when a prompt arrives, or `nil` to ask
    /// for none.
    private let elicitation: CreateElicitationRequest?

    /// The error this stub answers `session/close` with.
    private let closeSessionError: RequestError

    /// The updates to send after the prompt answer, one step per gate.
    private let deferredScript: [GatedUpdates]

    /// The updates to send when `session/cancel` arrives, in order.
    ///
    /// An empty script is the agent that IGNORES a cancellation, which is a
    /// conformant thing for an agent to be: `session/cancel` is a
    /// notification, and the schema confirms a cancellation with an `idle`
    /// `state_update` that this agent is free never to send.
    private let cancelScript: [SessionUpdate]

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
    ///   - closeSessionError: The error to answer `session/close` with.
    init(
        connection: AgentSideConnection,
        session: SessionId,
        script: [SessionUpdate],
        deferredScript: [GatedUpdates] = [],
        cancelScript: [SessionUpdate] = [],
        elicitation: CreateElicitationRequest? = nil,
        closeSessionError: RequestError = .methodNotFound("session/close")
    ) {
        self.connection = connection
        self.session = session
        self.script = script
        self.deferredScript = deferredScript
        self.cancelScript = cancelScript
        self.elicitation = elicitation
        self.closeSessionError = closeSessionError
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        workingDirectories.append(params.cwd)
        return NewSessionResponse(sessionId: session)
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound("session/list")
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RequestError.methodNotFound("session/resume")
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw closeSessionError
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        if let elicitation {
            _ = try await connection.createElicitation(elicitation)
        }
        for update in script {
            try await send(update)
        }
        startDeferredScript()
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {
        for update in cancelScript {
            // A notification has no answer that could carry a failure, and a
            // client that tore its connection down right after it cancelled is
            // a shape `cli-plan.md` §11 allows. Neither is a reason to trap.
            try? await send(update)
        }
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

    /// Creates one step of a deferred script.
    ///
    /// - Parameters:
    ///   - gate: The gate that must open before the updates go out.
    ///   - updates: The updates to send once the gate opens, in order.
    init(gate: UpdateGate, updates: [SessionUpdate]) {
        self.gate = gate
        self.updates = updates
    }
}
