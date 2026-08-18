import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared helpers for the transport tests. Each helper
// bounds a wait with a deadline, so a test failure shows as a failed
// expectation and never as a hang.

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

/// Waits for an idle `state_update` on one session-update stream.
///
/// - Parameters:
///   - updates: The stream to read.
///   - limit: The longest time to wait.
/// - Returns: `true` when an idle update arrived before the limit ended.
func waitForIdle(
    in updates: AsyncStream<SessionUpdate>,
    within limit: Duration = TransportTestDeadline.limit
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await update in updates {
                if case .stateUpdate(.idle(_)) = update {
                    return true
                }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return false
        }
        let sawIdle = await group.next() ?? false
        group.cancelAll()
        return sawIdle
    }
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

/// Connects `client` over `transport` and completes the initialize
/// handshake, for the tests that do not assert on the handshake itself.
///
/// - Parameters:
///   - client: The client to connect.
///   - transport: The transport to run over.
/// - Returns: The initialized connection.
@MainActor
func initializedConnection(
    for client: SwiftUIACPClient,
    over transport: any ACPTransport
) async throws -> ClientSideConnection {
    let connection = await client.connect(over: transport)
    _ = try await connection.initialize(makeInitializeRequest())
    return connection
}

/// Drives one prompt turn and waits until the agent's streamed reply landed
/// in the observable session state.
///
/// - Parameters:
///   - connection: The connection to drive.
///   - client: The client whose observable state receives the reply.
///   - sessionId: The session to prompt.
///   - messageID: The message id the agent stamps on its reply chunk.
///   - expectedText: The reply text the state must hold at the end.
/// - Returns: `true` when the turn went idle and the reply landed.
@MainActor
func promptTurnLandsReply(
    over connection: ClientSideConnection,
    client: SwiftUIACPClient,
    sessionId: SessionId,
    messageID: MessageId,
    expectedText: String
) async throws -> Bool {
    let updates = connection.updates(for: sessionId)
    _ = try await connection.prompt(
        PromptRequest(prompt: [.text(TextContent(text: "Hello"))], sessionId: sessionId)
    )
    guard await waitForIdle(in: updates) else { return false }
    let state = client.session(for: sessionId)
    return await eventually {
        state.flushPendingChunks()
        return state.messageContent(for: messageID) == [.text(TextContent(text: expectedText))]
    }
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
