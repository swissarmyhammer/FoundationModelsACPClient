import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared helpers for the transport tests. Each helper
// bounds a wait with a deadline, so a test failure shows as a failed
// expectation and never as a hang.
//
// The nested `IntegrationTests` package keeps a copy of its own, in its
// `Support/TransportTestSupport.swift`. The two copies stay separate on
// purpose: a test target cannot share source with a test target in an
// other package.

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

/// Waits until the condition is true.
///
/// The wait obeys task cancellation, so the test time limit stops a wait
/// that does not end.
///
/// - Parameter condition: The condition to wait for.
/// - Throws: `CancellationError` when the surrounding task gets cancelled.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    while !condition() {
        try Task.checkCancellation()
        await Task.yield()
    }
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
    await outcome(within: limit) {
        for await update in updates {
            if case .stateUpdate(.idle(_)) = update {
                return true
            }
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
