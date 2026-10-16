import Observation
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

/// Records what the waiters did with the callers of one test. It is
/// observable, so a test waits for a step of the waiters with no poll.
@MainActor @Observable
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

// A caller that ends before it goes into the queue never goes in, so the end
// of its task is the failure event of a wait for its suspend. A test reads the
// value of a caller only after a resume that found it, so the read does not
// hang.

@MainActor @Test
func keyedWaitersResumeTheWaitersOfOneKeyInCallOrder() async throws {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let first = startWaiter("first", for: firstKey, on: waiters, log: log)
    let firstEnd = TaskEnd(of: first)
    try await waitUntil { log.suspended == ["first"] } orFailWhen: { firstEnd.hasEnded }
    let second = startWaiter("second", for: firstKey, on: waiters, log: log)
    let secondEnd = TaskEnd(of: second)
    try await waitUntil { log.suspended == ["first", "second"] } orFailWhen: { secondEnd.hasEnded }

    try #require(waiters.resumeFirst(of: firstKey, with: "one"))
    #expect(await first.value == "one")
    try #require(waiters.resumeFirst(of: firstKey, with: "two"))
    #expect(await second.value == "two")
    #expect(!waiters.resumeFirst(of: firstKey, with: "three"))
}

@MainActor @Test
func keyedWaitersResumeOnlyTheWaitersOfTheNamedKey() async throws {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let other = startWaiter("other", for: secondKey, on: waiters, log: log)
    let otherEnd = TaskEnd(of: other)
    try await waitUntil { log.suspended == ["other"] } orFailWhen: { otherEnd.hasEnded }

    #expect(!waiters.resumeFirst(of: firstKey, with: "one"))
    try #require(waiters.resumeFirst(of: secondKey, with: "two"))
    #expect(await other.value == "two")
}

@MainActor @Test
func aCancelledWaiterGetsTheCancelledValueAndLeavesTheQueue() async throws {
    let waiters = makeWaiters()
    let log = WaiterLog()

    let waiting = startWaiter("waiting", for: firstKey, on: waiters, log: log)
    let waitingEnd = TaskEnd(of: waiting)
    try await waitUntil { log.suspended == ["waiting"] } orFailWhen: { waitingEnd.hasEnded }
    waiting.cancel()

    // The cancel is the behavior under test. No other event tells that the
    // cancel does not resume the caller, so this read is a known limit of
    // rule T1.
    #expect(await waiting.value == cancelledValue)
    #expect(log.cancelled == ["waiting"])
    #expect(!waiters.resumeFirst(of: firstKey, with: "one"))
}

@MainActor @Test
func aWaiterWhoseTaskWasCancelledBeforeTheCallDoesNotWait() async throws {
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
    let waitingEnd = TaskEnd(of: waiting)

    // A caller that goes into the queue is the failure: it waits, and nothing
    // resumes it.
    try await waitUntil { waitingEnd.hasEnded } orFailWhen: { !log.suspended.isEmpty }
    #expect(await waiting.value == cancelledValue)
    #expect(log.suspended.isEmpty)
    #expect(!waiters.resumeFirst(of: firstKey, with: "one"))
}
