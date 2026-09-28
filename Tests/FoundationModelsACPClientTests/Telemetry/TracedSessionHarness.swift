import Foundation
import FoundationModelsACP

@testable import AcpClientCore
@testable import FoundationModelsACPClient

// The session harness of the telemetry tests. `ClientRequestSpanTests` and
// `ClientRequestMetricsTests` drive the real `AgentSession` and `TurnRunner`
// with it, over `InMemoryTransport.pair()`, with a `ScriptedStubAgent` on the
// far end.
//
// Both packages export a type called `TerminalOutput`, and this file imports
// both, so the terminal layer of the binary is named
// `AcpClientCore.TerminalOutput` in full.

/// The text of the prompt of each turn of the harness.
///
/// Rule 4 of the OpenTelemetry design: no span, log record or metric holds a
/// prompt. The capture of each turn forbids this text.
let tracedPromptText = "Tell me the secret word of the traced turn."

/// An ``AgentSession`` and a ``TurnRunner`` over one end of an in-memory pair,
/// with a ``ScriptedStubAgent`` on the other end.
@MainActor
struct TracedSessionHarness {
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
