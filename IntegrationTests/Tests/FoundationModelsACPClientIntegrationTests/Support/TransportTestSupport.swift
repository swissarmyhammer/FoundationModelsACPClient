import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared helpers for the integration tests. Each helper
// bounds a wait with a deadline, so a test failure shows as a failed
// expectation and never as a hang.
//
// The unit target keeps a copy of its own in
// `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift`. The two
// copies stay separate on purpose: a test target cannot share source with a
// test target in another package, and the sibling package
// FoundationModelsMultitool makes the same choice. A package can use only the
// products of another package, so one shared source would need a test-support
// product that each user of the root package gets too.
//
// The helpers that both copies hold are the same, word for word:
// `TransportTestDeadline`, `eventually(within:_:)`, `outcome(within:of:)`,
// `waitForIdle(in:within:)` and `makeInitializeRequest()`. A change to one of
// them goes into both copies.
//
// `initializedConnection(for:over:)`, `promptTurnLandsReply(in:messageID:expectedText:)`,
// `idleStopReason(of:)`, `processExists(_:)` and
// `processGroupHasLiveMember(ledBy:)` are in this copy alone, because only the
// integration tests use them. The unit copy holds `waitUntil(_:)` alone.

/// The time limits the transport tests use.
enum TransportTestDeadline {
    /// The number of seconds in ``limit``.
    private static let limitSeconds = 10

    /// The number of milliseconds in ``pollInterval``.
    private static let pollIntervalMilliseconds = 20

    /// The longest time a test waits for a condition to become true.
    static let limit: Duration = .seconds(limitSeconds)

    /// The pause between two polls of a condition.
    static let pollInterval: Duration = .milliseconds(pollIntervalMilliseconds)
}

/// Polls `condition` until it is true or until the time limit ends.
///
/// - Parameters:
///   - limit: The longest time to wait.
///   - condition: The condition to poll.
/// - Returns: `true` when the condition became true before the limit ended.
func eventually(
    within limit: Duration = TransportTestDeadline.limit,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: TransportTestDeadline.pollInterval)
    }
    return await condition()
}

/// Runs `work` and waits for its answer, or gives up when `limit` ends first.
///
/// The wait cancels `work` when the limit ends. A wait on a stream that
/// never ends therefore stops at the limit, and the cancellation ends the
/// iteration of the stream.
///
/// - Parameters:
///   - limit: The longest time to wait.
///   - work: The work to run.
/// - Returns: The answer of `work`, or `nil` when the limit ended first.
func outcome<Answer: Sendable>(
    within limit: Duration = TransportTestDeadline.limit,
    of work: @escaping @Sendable () async -> Answer
) async -> Answer? {
    await withTaskGroup(of: Answer?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Waits for an idle `state_update` on the update tap of one session model.
///
/// - Parameters:
///   - updates: The update tap to read.
///   - limit: The longest time to wait.
/// - Returns: `true` when an idle update arrived before the limit ended.
func waitForIdle(
    in updates: AsyncStream<SessionUpdate>,
    within limit: Duration = TransportTestDeadline.limit
) async -> Bool {
    await outcome(within: limit) {
        for await case .stateUpdate(.idle(_)) in updates {
            return true
        }
        return false
    } ?? false
}

/// Makes the initialize request the transport tests send.
///
/// - Returns: The request, with this package's version and capabilities.
func makeInitializeRequest() -> InitializeRequest {
    InitializeRequest(
        info: Implementation(name: "test-client", version: "1.0.0"),
        protocolVersion: ACPClient.supportedProtocolVersion,
        capabilities: ACPClient.advertisedCapabilities
    )
}

/// Connects `model` over `transport` and completes the initialize
/// handshake through it, for the tests that do not assert on the handshake
/// itself.
///
/// - Parameters:
///   - model: The connection model to connect.
///   - transport: The transport to run over.
/// - Returns: The initialized connection.
@MainActor
func initializedConnection(
    for model: ConnectionModel,
    over transport: any ACPTransport
) async throws -> ClientSideConnection {
    let connection = await model.connect(over: transport)
    _ = try await model.initialize(makeInitializeRequest())
    return connection
}

/// Drives one prompt turn through a session model and tells whether the
/// agent's streamed reply landed in its transcript.
///
/// The tap is made before the prompt goes out, so it gives each update of
/// the turn. The model applies an update before the tap consumer reads it,
/// so the transcript holds the whole reply when the idle update arrives.
///
/// - Parameters:
///   - session: The model of the session to prompt.
///   - messageID: The message id the agent stamps on its reply chunk.
///   - expectedText: The reply text the transcript must hold at the end.
/// - Returns: `true` when the turn went idle and the reply landed.
@MainActor
func promptTurnLandsReply(
    in session: SessionModel,
    messageID: MessageId,
    expectedText: String
) async throws -> Bool {
    let updates = session.updateTap()
    _ = try await session.prompt([.text(TextContent(text: "Hello"))])
    guard await waitForIdle(in: updates) else { return false }
    return session.transcript.contains { entry in
        guard case .agentMessage(let message) = entry else { return false }
        return message.messageId == messageID && message.content == [.text(TextContent(text: expectedText))]
    }
}

/// Gives the stop reason of the last idle state a session model holds.
///
/// - Parameter session: The session model.
/// - Returns: The stop reason, or `nil` when the agent is not idle or named
///   no stop reason.
@MainActor
func idleStopReason(of session: SessionModel) -> StopReason? {
    guard case .idle(let idle) = session.agentState else { return nil }
    return idle.stopReason
}

/// Tells whether a process with `pid` exists.
///
/// A zombie process exists until a reap collects it, so this helper also
/// proves the reap: after a correct reap, the answer is `false`.
///
/// - Parameter pid: The process id to probe.
/// - Returns: `true` when a signal-0 probe reaches a process.
func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Tells whether any process of the group `leader` started is still alive.
///
/// `kill` addresses a whole process group through the negated group id, and a
/// signal-0 probe reaches the group when at least one member is alive.
/// `AgentProcess` spawns the agent as the leader of a group of its own, so the
/// agent's pid is the group id, and a child the agent left behind is a member
/// the pid probe of ``processExists(_:)`` cannot see. `cli-plan.md` §11 asks
/// that no process of that group outlives the run, and this is the probe that
/// reads the group rather than the one pid.
///
/// - Parameter leader: The pid of the agent, which led the group.
/// - Returns: `true` when a signal-0 probe reaches a member of the group.
func processGroupHasLiveMember(ledBy leader: pid_t) -> Bool {
    kill(-leader, 0) == 0
}
