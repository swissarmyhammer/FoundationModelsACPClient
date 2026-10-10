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
