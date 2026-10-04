import Testing

@testable import FoundationModelsACPClient

// These tests cover `KeyedWaiters`, the shared core of `PendingRequestQueue`
// and `KeyedTurnQueue`: callers wait by key, each caller resumes exactly one
// time, and a cancelled caller leaves the queue with the cancelled value.

/// The value that a cancelled caller gets.
private let cancelledValue = "cancelled"

/// The key of the waiters that a test resumes.
private let firstKey = "first"

/// A second key, whose waiters a resume of `firstKey` must not touch.
private let secondKey = "second"

/// Records what the waiters did with the callers of one test.
@MainActor
private final class WaiterLog {
    /// The names of the callers that are in the queue, in the order they
    /// went in.
    var suspended: [String] = []

    /// The names of the callers whose cancel took them out of the queue.
    var cancelled: [String] = []
}

/// Makes the waiters that each test uses.
///
/// - Returns: Waiters keyed by `String`, with `cancelledValue` for a
///   cancelled caller.
@MainActor
private func makeWaiters() -> KeyedWaiters<String, String> {
    KeyedWaiters(cancelledValue: cancelledValue)
}

/// Starts one caller that waits on a key, and records its steps in a log.
///
/// - Parameters:
///   - name: The name of the caller in the log.
///   - key: The key the caller waits on.
///   - waiters: The waiters under test.
///   - log: The log of the test.
/// - Returns: The task of the caller. Its value is the value the caller got.
@MainActor
private func startWaiter(
    _ name: String,
    for key: String,
    on waiters: KeyedWaiters<String, String>,
    log: WaiterLog
) -> Task<String, Never> {
    Task { @MainActor in
        await waiters.wait(
            for: key,
            onSuspend: { log.suspended.append(name) },
            onCancel: { log.cancelled.append(name) }
        )
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func keyedWaitersResumeTheWaitersOfOneKeyInCallOrder() async throws {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let first = startWaiter("first", for: firstKey, on: waiters, log: log)
    try await waitUntil { log.suspended == ["first"] }
    let second = startWaiter("second", for: firstKey, on: waiters, log: log)
    try await waitUntil { log.suspended == ["first", "second"] }

    #expect(waiters.resumeFirst(of: firstKey, with: "one"))
    #expect(await first.value == "one")
    #expect(waiters.resumeFirst(of: firstKey, with: "two"))
    #expect(await second.value == "two")
    #expect(!waiters.resumeFirst(of: firstKey, with: "three"))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func keyedWaitersResumeOnlyTheWaitersOfTheNamedKey() async throws {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let other = startWaiter("other", for: secondKey, on: waiters, log: log)
    try await waitUntil { log.suspended == ["other"] }

    #expect(!waiters.resumeFirst(of: firstKey, with: "one"))
    #expect(waiters.resumeFirst(of: secondKey, with: "two"))
    #expect(await other.value == "two")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aCancelledWaiterGetsTheCancelledValueAndLeavesTheQueue() async throws {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let waiting = startWaiter("waiting", for: firstKey, on: waiters, log: log)
    try await waitUntil { log.suspended == ["waiting"] }
    waiting.cancel()

    #expect(await waiting.value == cancelledValue)
    #expect(log.cancelled == ["waiting"])
    #expect(!waiters.resumeFirst(of: firstKey, with: "one"))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aWaiterWhoseTaskWasCancelledBeforeTheCallDoesNotWait() async {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let waiting = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await waiters.wait(
            for: firstKey,
            onSuspend: { log.suspended.append("waiting") },
            onCancel: { log.cancelled.append("waiting") }
        )
    }

    #expect(await waiting.value == cancelledValue)
    #expect(log.suspended.isEmpty)
    #expect(!waiters.resumeFirst(of: firstKey, with: "one"))
}
